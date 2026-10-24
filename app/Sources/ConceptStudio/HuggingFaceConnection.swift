import AppKit
import ConceptCore
import Foundation
import Observation

@MainActor @Observable
final class HuggingFaceConnection {
    private(set) var status = HuggingFaceStatus.disconnected
    private(set) var isBusy = false
    var message = ""
    var errorMessage: String?
    var isConnected: Bool {
        status.isConnected
    }

    var usesOAuth: Bool {
        status.usesOAuth
    }

    var username: String? {
        status.username
    }

    @ObservationIgnored private let session: HuggingFaceSession
    @ObservationIgnored private let secrets: any SecretStore
    @ObservationIgnored private var operationTask: Task<Bool, Never>?
    @ObservationIgnored private var operationID = UUID()

    init(
        secrets: any SecretStore = KeychainStore(),
        clientID: String = HuggingFaceAuthorization.clientID,
        transport: any HTTPTransport = OpenRouterAuthorizationTransport(),
        callbackFactory: @escaping @Sendable () -> any ChatGPTCallback = {
            ChatGPTLoopbackCallback(providerName: "Hugging Face")
        },
        openBrowser: @escaping @Sendable (URL) async throws -> Void = { url in
            try await MainActor.run {
                guard NSWorkspace.shared.open(url) else {
                    throw HuggingFaceAuthError("Your browser could not open Hugging Face. Sign in again.")
                }
            }
        },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.secrets = secrets
        session = HuggingFaceSession(
            secrets: secrets, transport: transport, clientID: clientID, callbackFactory: callbackFactory,
            openBrowser: openBrowser, now: now
        )
    }

    /// Synchronous startup configuration uses the stored selection, never a cached UI flag.
    /// The OAuth provider is lazy; malformed or expired OAuth must not expose a manual fallback.
    func storedTokenConfiguration() throws -> (
        manualToken: String, oauthToken: (@Sendable () async throws -> String)?
    ) {
        switch try HuggingFaceStoredCredential.read(from: secrets) {
        case .oauth:
            ("", { try await self.accessToken() })
        case let .manual(token):
            (token ?? "", nil)
        }
    }

    /// Explicit local loading keeps initialization and the offline demo free of Keychain/network work.
    func load() async {
        _ = await run { self.status = try await self.session.load() }
    }

    @discardableResult
    func signIn() async -> Bool {
        await run {
            self.message = "Approve ConceptStudio in your browser to connect Hugging Face."
            try await self.session.signIn()
            self.message = "Connected to Hugging Face for publishing and gated models."
        }
    }

    @discardableResult
    func signOut() async -> Bool {
        await cancelAndWait()
        return await run {
            try await self.session.signOut()
            self.message = "Hugging Face credentials removed from this Mac. "
                + "Manage the app's access in Hugging Face Connected Applications."
        }
    }

    @discardableResult
    func saveManualToken(_ token: String) async -> Bool {
        await cancelAndWait()
        return await run {
            try await self.session.saveManualToken(token)
            self.message = token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Hugging Face credentials removed from this Mac."
                : "Hugging Face token checked and saved. This is now the selected Hugging Face credential."
        }
    }

    func accessToken() async throws -> String {
        guard let token = try await optionalAccessToken() else {
            throw HuggingFaceAuthError("Sign in with Hugging Face before publishing or downloading gated models.")
        }
        return token
    }

    /// nil means genuinely disconnected. An OAuth account needing renewal always throws.
    func optionalAccessToken() async throws -> String? {
        do {
            let token = try await session.optionalAccessToken()
            status = await session.cachedStatus()
            return token
        } catch {
            status = await session.cachedStatus()
            if !Task.isCancelled { errorMessage = Self.describe(error) }
            throw error
        }
    }

    func cancel() {
        operationTask?.cancel()
    }

    func cancelAndWait() async {
        let pending = operationTask
        pending?.cancel()
        await session.cancelAndWait()
        _ = await pending?.value
    }

    private func run(_ operation: @escaping @MainActor () async throws -> Void) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true; errorMessage = nil
        let id = UUID()
        operationID = id
        let work = Task { @MainActor in
            defer { self.isBusy = false }
            do {
                try Task.checkCancellation()
                try await operation()
                try Task.checkCancellation()
                self.status = await self.session.cachedStatus()
                return true
            } catch {
                self.status = await self.session.cachedStatus()
                if error is CancellationError || Task.isCancelled {
                    self.message = "Hugging Face account action cancelled."
                } else { self.errorMessage = Self.describe(error) }
                return false
            }
        }
        operationTask = work
        let result = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
        if operationID == id { operationTask = nil }
        return result
    }

    private static func describe(_ error: any Error) -> String {
        (error as? HuggingFaceAuthError)?.message ?? (error as? StudioError)?.localizedDescription
            ?? (error as? ChatGPTAuthError)?.message
            ?? "Hugging Face could not connect. Check your internet connection and try again."
    }
}
