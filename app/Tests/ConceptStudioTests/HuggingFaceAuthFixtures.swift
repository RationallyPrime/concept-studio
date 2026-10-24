import ConceptCore
@testable import ConceptStudio
import Foundation
import Synchronization
import Testing

final class HuggingFaceTestSecrets: SecretStore {
    private struct State {
        var values: [String: String]
        var reads: [String] = []
        var writes: [String] = []
        var rejectedAccounts: Set<String> = []
    }

    private let state: Mutex<State>
    init(_ values: [String: String] = [:]) {
        state = Mutex(State(values: values))
    }

    var values: [String: String] {
        state.withLock { $0.values }
    }

    var reads: [String] {
        state.withLock { $0.reads }
    }

    var writes: [String] {
        state.withLock { $0.writes }
    }

    func rejectWrites(to account: String) {
        state.withLock { $0.rejectedAccounts.insert(account) }
    }

    func read(_ account: String) -> String? {
        state.withLock { $0.reads.append(account); return $0.values[account] }
    }

    func save(_ value: String, account: String) throws {
        try state.withLock {
            $0.writes.append(account)
            if $0.rejectedAccounts.contains(account) { throw StudioError.message("Test Keychain write refused.") }
            $0.values[account] = value.isEmpty ? nil : value
        }
    }
}

actor HuggingFaceAuthFixture: ChatGPTCallback, HTTPTransport {
    let redirect = URL(string: "http://127.0.0.1:14555/auth/callback")!
    private(set) var requests: [URLRequest] = []
    private(set) var browserURLs: [URL] = []
    private(set) var callbackCancelled = false
    private(set) var cancelledRequests = 0
    private var responseURL: URL?
    private var callbackWaiter: CheckedContinuation<URL, any Error>?
    private var holdCallback = false
    private var holdToken = false
    private var tokenWaiter: CheckedContinuation<Void, Never>?
    private var tokenObservers: [CheckedContinuation<Void, Never>] = []
    private var browserObservers: [CheckedContinuation<Void, Never>] = []
    private var cancellationObservers: [CheckedContinuation<Void, Never>] = []
    private var tokenStatus = 200
    private var tokenError = "invalid_grant"
    private var scope = HuggingFaceAuthorization.scopes.joined(separator: " ")
    private var rotateRefresh = true
    private var expiresIn: Double? = 3600
    private var deny = false
    private var badState = false
    private var profileStatus = 200

    func configure(
        holdCallback: Bool = false, holdToken: Bool = false, tokenStatus: Int = 200,
        tokenError: String = "invalid_grant", scope: String? = nil, rotateRefresh: Bool = true,
        expiresIn: Double? = 3600, deny: Bool = false, badState: Bool = false, profileStatus: Int = 200
    ) {
        self.holdCallback = holdCallback; self.holdToken = holdToken
        self.tokenStatus = tokenStatus; self.tokenError = tokenError
        self.scope = scope ?? HuggingFaceAuthorization.scopes.joined(separator: " ")
        self.rotateRefresh = rotateRefresh; self.expiresIn = expiresIn
        self.deny = deny; self.badState = badState; self.profileStatus = profileStatus
    }

    func start() -> URL {
        redirect
    }

    func open(_ url: URL) {
        browserURLs.append(url)
        for observer in browserObservers {
            observer.resume()
        }
        browserObservers = []
        guard !holdCallback else { return }
        let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "state" }?.value
        var parts = URLComponents(url: redirect, resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "state", value: badState ? "wrong" : state)]
        parts.queryItems?.append(URLQueryItem(
            name: deny ? "error" : "code",
            value: deny ? "access_denied" : "synthetic-code"
        ))
        responseURL = parts.url
    }

    func wait() async throws -> URL {
        try await withTaskCancellationHandler {
            if let responseURL { return responseURL }
            return try await withCheckedThrowingContinuation { callbackWaiter = $0 }
        } onCancel: { Task { await self.cancel() } }
    }

    func cancel() {
        callbackCancelled = true
        callbackWaiter?.resume(throwing: CancellationError()); callbackWaiter = nil
    }

    func waitForTokenRequest() async {
        if requests.contains(where: { $0.url?.path() == "/oauth/token" }) { return }
        await withCheckedContinuation { tokenObservers.append($0) }
    }

    func waitForBrowser() async {
        if !browserURLs.isEmpty { return }
        await withCheckedContinuation { browserObservers.append($0) }
    }

    func waitForRequestCancellation() async {
        if cancelledRequests > 0 { return }
        await withCheckedContinuation { cancellationObservers.append($0) }
    }

    private func recordCancellation() {
        cancelledRequests += 1
        for observer in cancellationObservers {
            observer.resume()
        }
        cancellationObservers = []
    }

    func releaseToken() {
        tokenWaiter?.resume(); tokenWaiter = nil
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        switch request.url?.path() {
        case "/oauth/token":
            for observer in tokenObservers {
                observer.resume()
            }
            tokenObservers = []
            if holdToken {
                // Deliberately allow a late reply after cancellation to test the credential generation guard.
                await withTaskCancellationHandler {
                    await withCheckedContinuation { tokenWaiter = $0 }
                } onCancel: { Task { await self.recordCancellation() } }
            }
            if tokenStatus != 200 { return try response(["error": tokenError], status: tokenStatus) }
            var body: [String: Any] = ["access_token": "fresh-access", "token_type": "Bearer", "scope": scope]
            if rotateRefresh { body["refresh_token"] = "fresh-refresh" }
            if let expiresIn { body["expires_in"] = expiresIn }
            return try response(body)
        case "/oauth/userinfo":
            return try response([
                "sub": "fixture-subject", "preferred_username": "fixture-user", "name": "Fixture User",
            ], status: profileStatus)
        case "/api/whoami-v2":
            return try response(
                ["id": "manual-subject", "name": "manual-user", "fullname": "Manual User"],
                status: profileStatus
            )
        default: throw URLError(.unsupportedURL)
        }
    }

    private func response(_ body: [String: Any], status: Int = 200) throws -> HTTPResponse {
        try HTTPResponse(status: status, body: JSONSerialization.data(withJSONObject: body))
    }
}

let huggingFaceTestNow = Date(timeIntervalSince1970: 1_800_000_000)

func huggingFaceSavedRecord(expired: Bool = false, refreshToken: String? = "old-refresh") throws -> String {
    let profile = try HuggingFaceProfile(data: Data(
        #"{"sub":"fixture-subject","preferred_username":"fixture-user","name":"Fixture User"}"#.utf8
    ), oauth: true)
    let record = HuggingFaceOAuthRecord(
        clientID: "fixture-public-client", profile: profile,
        tokens: HuggingFaceTokens(
            accessToken: "old-access", refreshToken: refreshToken,
            expiresAt: huggingFaceTestNow.addingTimeInterval(expired ? -10 : 3600),
            scopes: Set(HuggingFaceAuthorization.scopes)
        )
    )
    return try #require(String(bytes: JSONEncoder().encode(record), encoding: .utf8))
}

func huggingFaceTestSession(
    _ secrets: HuggingFaceTestSecrets,
    _ fixture: HuggingFaceAuthFixture
) -> HuggingFaceSession {
    HuggingFaceSession(
        secrets: secrets, transport: fixture, clientID: "fixture-public-client", callbackFactory: { fixture },
        openBrowser: { await fixture.open($0) }, now: { huggingFaceTestNow }
    )
}

@MainActor
func huggingFaceTestConnection(
    _ secrets: HuggingFaceTestSecrets,
    _ fixture: HuggingFaceAuthFixture
) -> HuggingFaceConnection {
    HuggingFaceConnection(
        secrets: secrets, clientID: "fixture-public-client", transport: fixture, callbackFactory: { fixture },
        openBrowser: { await fixture.open($0) }, now: { huggingFaceTestNow }
    )
}
