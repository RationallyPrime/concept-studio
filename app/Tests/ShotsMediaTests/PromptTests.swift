import ConceptCore
import Foundation
import PrevisCore
@testable import ShotsMedia
import Testing

@Suite("H3 prompts")
struct PromptTests {
    @Test func aModelWrittenPromptKeepsTheExactFormat() async throws {
        let facts = try sampleFacts(small: true)
        let reply = """
        {"integrated_multimodal_description": "[Shot 1] The man walks toward the woman.",
         "overall_soundscape": "Footsteps on a wooden floor.", "non_diegetic_music": "None."}
        """
        let prompt = try await ShotPromptCompiler.write(
            facts,
            endpoint: ResolvedEndpoint(client: FixedSections(reply: reply))
        )
        // 22 frames: Picture 2 is the last frame, 21/24 s in.
        #expect(prompt.text == """
        How the reference pictures align with the target video — Picture 1 (from Shot 1) aligns with the 0.00-second \
        mark of the target video; Picture 2 (from Shot 1) aligns with the 0.88-second mark of the target video.

        integrated_multimodal_description: [Shot 1] The man walks toward the woman.

        overall_soundscape: Footsteps on a wooden floor.

        non_diegetic_music: None.
        """)
        #expect(prompt.writtenBy == "fake-model" && prompt.sceneRevision == facts.sceneRevision)
    }

    @Test func theSampleMovesAsAPushIn() throws {
        let full = try sampleFacts(small: false), small = try sampleFacts(small: true)
        #expect(full.cameraLegs.map(\.move) == [.push] && small.cameraLegs.map(\.move) == [.push])
        // The same 1.5 m push takes 5.1 s in the full sample and under a second in the small one.
        #expect(full.cameraLegs.first?.speed == .slow && small.cameraLegs.first?.speed == .fast)
    }

    @Test func aShotWithoutNotesStillHasAllThreeSections() throws {
        var scene = try #require(ShotsSamples.twoPersonWalk(small: true).scenes.first)
        scene.shots[0].notes = ShotNotes(description: "", sound: "", music: "")
        let facts = try ShotPromptCompiler.facts(
            scene: scene,
            shotID: scene.shots[0].id,
            catalog: ContentCatalog.bundled()
        )
        let prompt = ShotPromptCompiler.template(facts)
        #expect(prompt.sections.map(\.key) == [
            "integrated_multimodal_description",
            "overall_soundscape",
            "non_diegetic_music",
        ])
        #expect(prompt.sections.allSatisfy { !$0.text.isEmpty }, "\(prompt.sections)")
        #expect(prompt.sections.last?.text == "None.")
        // Catalog nouns arrive with their article ("a man"), and the template names each subject once.
        #expect(prompt.sections[0].text.contains("The man walks, then stands."), "\(prompt.sections[0].text)")
        #expect(!prompt.text.contains("The a ") && !prompt.text.contains(" an a "))
        #expect(prompt.text.hasPrefix("How the reference pictures align with the target video — Picture 1"))
    }
}

/// A model that always answers with the same JSON.
private struct FixedSections: ModelClient {
    let requestedModel = "fake-model"
    let reply: String

    func request(
        instructions: String,
        messages: [ChatMessage],
        output: OutputRequest,
        settings: RequestSettings,
        onPartialText: (@Sendable (String) async -> Void)?
    ) async throws -> ModelReply {
        ModelReply(text: reply, servedModel: nil)
    }
}

private func sampleFacts(small: Bool) throws -> PromptFacts {
    let scene = try #require(ShotsSamples.twoPersonWalk(small: small).scenes.first)
    let shot = try #require(scene.shots.first)
    return try ShotPromptCompiler.facts(scene: scene, shotID: shot.id, catalog: ContentCatalog.bundled())
}
