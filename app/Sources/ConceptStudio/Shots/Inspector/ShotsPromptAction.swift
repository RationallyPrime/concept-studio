import PrevisCore
import ShotsMedia

@MainActor enum ShotsPromptAction {
    /// Capture the target/revision before awaiting a model. A later scene edit makes the result stale naturally.
    static func write(
        store: ShotsStore,
        facts: (PrevisScene, ShotID, ContentCatalog) throws -> PromptFacts = ShotPromptCompiler.facts,
        writer: (PromptFacts) async throws -> ShotPrompt
    ) async throws {
        guard !store.isReadOnly else { throw ShotsEditingError.readOnly }
        guard let scene = store.currentScene, let shot = store.currentShot else {
            throw ShotsEditingError.missing("shot")
        }
        let input = try facts(scene, shot.id, store.catalog)
        let prompt = try await writer(input)
        try Task.checkCancellation()
        try store.perform(.setPrompt(shot.id, prompt))
    }
}
