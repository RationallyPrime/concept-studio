import ConceptCore
import Foundation

enum HuggingFaceCredentialSource: Equatable, Sendable {
    case none, manual, oauth
}

struct HuggingFaceStatus: Equatable, Sendable {
    let source: HuggingFaceCredentialSource
    let profile: HuggingFaceProfile?
    let needsSignIn: Bool
    let expiresAt: Date?

    static let disconnected = HuggingFaceStatus(source: .none, profile: nil, needsSignIn: false, expiresAt: nil)
    var isConnected: Bool {
        source != .none && !needsSignIn
    }

    var usesOAuth: Bool {
        source == .oauth
    }

    var username: String? {
        profile?.username
    }
}

private struct HuggingFaceTokenFailure: Error {
    let status: Int
    let code: String?
}

enum HuggingFaceStoredCredential {
    case oauth(String), manual(String?)

    static func read(from secrets: any SecretStore) throws -> Self {
        if let record = try secrets.read(HuggingFaceSession.oauthAccount) { return .oauth(record) }
        return try .manual(secrets.read(HuggingFaceSession.manualAccount).flatMap { $0.isEmpty ? nil : $0 })
    }
}

/// The only writer for Hugging Face credentials. An OAuth record always takes precedence,
/// including when its tokens have expired or been revoked; it never falls back to a pasted token.
actor HuggingFaceSession {
    static let oauthAccount = "huggingface.oauth"
    static let manualAccount = "huggingface"

    private let secrets: any SecretStore
    private let transport: any HTTPTransport
    private let clientID: String
    private let callbackFactory: @Sendable () -> any ChatGPTCallback
    private let openBrowser: @Sendable (URL) async throws -> Void
    private let now: @Sendable () -> Date
    private var loaded = false
    private var oauth: HuggingFaceOAuthRecord?
    private var manualToken: String?
    private var manualProfile: HuggingFaceProfile?
    private var blocked = false
    private var generation = 0
    private var callback: (generation: Int, value: any ChatGPTCallback)?
    private var refreshing: (id: UUID, task: Task<String, any Error>)?

    init(
        secrets: any SecretStore, transport: any HTTPTransport, clientID: String,
        callbackFactory: @escaping @Sendable () -> any ChatGPTCallback,
        openBrowser: @escaping @Sendable (URL) async throws -> Void,
        now: @escaping @Sendable () -> Date
    ) {
        self.secrets = secrets; self.transport = transport; self.clientID = clientID
        self.callbackFactory = callbackFactory; self.openBrowser = openBrowser; self.now = now
    }

    func load() throws -> HuggingFaceStatus {
        try loadSaved()
        return cachedStatus()
    }

    func cachedStatus() -> HuggingFaceStatus {
        if let oauth {
            let expiredWithoutRefresh = oauth.tokens.map {
                $0.refreshToken == nil && ($0.expiresAt.map { $0 <= now() } ?? false)
            } ?? true
            return HuggingFaceStatus(
                source: .oauth, profile: oauth.profile,
                needsSignIn: blocked || expiredWithoutRefresh, expiresAt: oauth.tokens?.expiresAt
            )
        }
        guard manualToken?.isEmpty == false else { return .disconnected }
        return HuggingFaceStatus(source: .manual, profile: manualProfile, needsSignIn: blocked, expiresAt: nil)
    }

    func signIn() async throws {
        try loadSaved()
        let version = await cancelPending()
        try check(version)
        let listener = callbackFactory()
        callback = (version, listener)
        do {
            let redirect = try await listener.start()
            let attempt = try HuggingFaceAuthorization(redirectURI: redirect, clientID: clientID)
            try check(version)
            try await openBrowser(attempt.browserURL)
            let response = try await listener.wait()
            await listener.cancel()
            try check(version)
            let tokens = try await exchange(attempt.exchangeRequest(callback: response)).tokens(now: now())
            let profile = try await profile(token: tokens.accessToken, oauth: true)
            try check(version)
            try persist(HuggingFaceOAuthRecord(clientID: clientID, profile: profile, tokens: tokens))
            blocked = false
            if callback?.generation == version { callback = nil }
        } catch {
            await listener.cancel()
            if callback?.generation == version { callback = nil }
            throw error
        }
    }

    func saveManualToken(_ value: String) async throws {
        let token = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { try await signOut(); return }
        try loadSaved()
        let version = await cancelPending()
        try check(version)
        let identity = try await profile(token: token, oauth: false)
        try check(version)
        try secrets.save(token, account: Self.manualAccount)
        // Failure here deliberately leaves OAuth selected, even though the replacement token was saved.
        try secrets.save("", account: Self.oauthAccount)
        manualToken = token; manualProfile = identity; oauth = nil; blocked = false
    }

    func signOut() async throws {
        // Block new access before awaiting cancellation of any earlier operation.
        blocked = true
        let version = await cancelPending()
        try check(version)
        // Manual first: a failed OAuth removal must never reveal a stale manual fallback.
        try secrets.save("", account: Self.manualAccount)
        manualToken = nil; manualProfile = nil
        try secrets.save("", account: Self.oauthAccount)
        oauth = nil; loaded = true; blocked = false
    }

    func optionalAccessToken() async throws -> String? {
        try Task.checkCancellation()
        try loadSaved()
        guard !blocked else { throw signInRequired() }
        guard let oauth else { return manualToken }
        guard let tokens = oauth.tokens else { throw signInRequired() }
        if tokens.expiresAt == nil || tokens.expiresAt! > now().addingTimeInterval(60) {
            return tokens.accessToken
        }
        guard tokens.refreshToken != nil else {
            if tokens.expiresAt! > now() { return tokens.accessToken }
            throw signInRequired()
        }
        let version = generation
        let pending: (id: UUID, task: Task<String, any Error>)
        if let refreshing { pending = refreshing } else {
            pending = (UUID(), Task { try await self.refresh(oauth, version: version) })
            refreshing = pending
        }
        do {
            // One cancelled consumer must not cancel a rotating refresh shared by other requests.
            let token = try await pending.task.value
            if refreshing?.id == pending.id { refreshing = nil }
            try check(version)
            guard !blocked else { throw signInRequired() }
            return token
        } catch {
            if refreshing?.id == pending.id { refreshing = nil }
            throw error
        }
    }

    func cancelAndWait() async {
        _ = await cancelPending()
    }

    private func cancelPending() async -> Int {
        generation += 1
        let version = generation
        let pending = refreshing
        let listener = callback
        refreshing = nil; callback = nil
        pending?.task.cancel()
        await listener?.value.cancel()
        if let pending { _ = await pending.task.result }
        return version
    }

    private func refresh(_ record: HuggingFaceOAuthRecord, version: Int) async throws -> String {
        guard let previous = record.tokens, let refreshToken = previous.refreshToken else { throw signInRequired() }
        do {
            let response = try await exchange(HuggingFaceAuthorization.tokenRequest([
                "grant_type": "refresh_token", "client_id": record.clientID, "refresh_token": refreshToken,
            ]))
            let tokens = try response.tokens(previous: previous, now: now())
            try check(version)
            var updated = record
            updated.tokens = tokens
            do { try persist(updated) } catch { blocked = true; throw error }
            return tokens.accessToken
        } catch let error as HuggingFaceTokenFailure {
            try check(version)
            if error.code == "invalid_grant" || error.code == "invalid_token" {
                var updated = record
                updated.tokens = nil
                do { try persist(updated) } catch { blocked = true; throw error }
                throw signInRequired()
            }
            throw HuggingFaceAuthError(
                "Hugging Face could not renew this sign-in (HTTP \(error.status)). Try again."
            )
        }
    }

    private func exchange(_ request: URLRequest) async throws -> HuggingFaceTokenResponse {
        let response = try await transport.send(request)
        try Task.checkCancellation()
        guard response.status == 200 else {
            let body = try? JSONValue(parsing: response.body).objectValue
            throw HuggingFaceTokenFailure(status: response.status, code: body?["error"]?.stringValue)
        }
        guard let value = try? JSONDecoder().decode(HuggingFaceTokenResponse.self, from: response.body) else {
            throw HuggingFaceAuthError("Hugging Face returned unreadable credentials. Sign in again.")
        }
        return value
    }

    private func profile(token: String, oauth: Bool) async throws -> HuggingFaceProfile {
        let url = oauth ? HuggingFaceAuthorization.userInfoURL
            : URL(string: "https://huggingface.co/api/whoami-v2")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let response = try await transport.send(request)
        try Task.checkCancellation()
        guard response.status == 200 else {
            throw HuggingFaceAuthError(response.status == 401 || response.status == 403
                ? "Hugging Face did not accept this authorization. Sign in again or replace the Advanced token."
                : "Hugging Face could not load your account (HTTP \(response.status)). Try again.")
        }
        return try HuggingFaceProfile(data: response.body, oauth: oauth)
    }

    private func loadSaved() throws {
        try Task.checkCancellation()
        guard !loaded else { return }
        switch try HuggingFaceStoredCredential.read(from: secrets) {
        case let .oauth(saved):
            guard let record = try? JSONDecoder().decode(HuggingFaceOAuthRecord.self, from: Data(saved.utf8)) else {
                throw HuggingFaceAuthError(
                    "Your saved Hugging Face sign-in could not be read. Sign out, then sign in again."
                )
            }
            oauth = record
        case let .manual(token):
            manualToken = token
        }
        loaded = true
    }

    private func persist(_ record: HuggingFaceOAuthRecord) throws {
        let data = try JSONEncoder().encode(record)
        guard let encoded = String(bytes: data, encoding: .utf8) else {
            throw HuggingFaceAuthError("Hugging Face credentials could not be saved.")
        }
        try secrets.save(encoded, account: Self.oauthAccount)
        oauth = record; loaded = true
    }

    private func check(_ version: Int) throws {
        try Task.checkCancellation()
        guard generation == version else { throw CancellationError() }
    }

    private func signInRequired() -> HuggingFaceAuthError {
        HuggingFaceAuthError("Sign in with Hugging Face again to continue. Your selected account has not changed.")
    }
}
