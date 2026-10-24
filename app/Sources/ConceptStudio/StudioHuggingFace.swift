import ConceptCore
import Foundation

extension StudioSession {
    func hubClient() -> HubClient {
        let connection = huggingFace
        return HubClient(tokenProvider: { try await connection.optionalAccessToken() })
    }

    func loadHuggingFace() async {
        guard !demoMode else { return }
        await huggingFace.load()
        if !demoMode, !Task.isCancelled { preparePublishing() }
    }

    func connectHuggingFace() async {
        guard !demoMode, !busy else { return }
        let connected = await huggingFace.signIn()
        guard !demoMode, !Task.isCancelled else { return }
        providerCredentialsDidChange()
        if connected { await fillDefaultTrainingOutput() }
    }

    func disconnectHuggingFace() async {
        guard !demoMode, !busy else { return }
        await huggingFace.signOut()
        if !demoMode, !Task.isCancelled { providerCredentialsDidChange() }
    }

    func saveHuggingFaceToken(_ token: String) async -> Bool {
        guard !demoMode, !busy else { return false }
        let saved = await huggingFace.saveManualToken(token)
        guard !demoMode, !Task.isCancelled else { return false }
        providerCredentialsDidChange()
        if saved { await fillDefaultTrainingOutput() }
        return saved
    }
}
