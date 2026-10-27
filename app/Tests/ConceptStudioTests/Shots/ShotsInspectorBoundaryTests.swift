import ConceptCore
@testable import ConceptStudio
import Foundation
import PrevisCore
import ShotsMedia
import Testing

@Suite("Shots inspector editing boundaries")
@MainActor
struct ShotsInspectorBoundaryTests {
    @Test func eachInspectorCommandIsOneUndoStep() throws {
        let catalog = try ContentCatalog.bundled()
        let document = ShotsSamples.twoPersonWalk()
        let scene = try #require(document.scenes.first)
        let shot = try #require(scene.shots.first)
        let entity = try #require(scene.entities.first)
        var actorMark = try #require(scene.blocking.first?.tracks.first?.marks.first)
        var cameraMark = try #require(shot.camera.marks.first)
        actorMark.hold = 0.25
        cameraMark.focalLength = 42
        let commands: [ShotsCommand] = [
            .setNotes(shot.id, ShotNotes(description: "At a station", sound: "Footsteps", music: "None")),
            .setGuideFrames(shot.id, [1, 61]),
            .renameEntity(entity.id, name: "First actor"),
            .setLabel(entity.id, EntityLabel(text: "Lead", color: RGB(hex: "e5484d"))),
            .setPlacement(entity.id, Placement(position: Vec3(1, 0, 2), heading: 0.4, scale: 1.2)),
            .attach(child: entity.id, parent: scene.entities.last?.id, shot: shot.id, atFrame: 0),
            .applyActionPath(shot.id, entity.id, pathID: "walk-forward", atFrame: 0, duration: 2, speed: nil),
            .setCameraRig(shot.id, sensor: .fullFrame, rig: .handheld, intensity: 0.3),
            .setTracking(shot.id, [entity.id]), .setMount(shot.id, entity.id),
            .applyFraming(shot.id, .medium, subjects: [entity.id], atFrame: 0),
            .applyCameraMove(shot.id, moveID: "slow-push-in", subjects: [entity.id]),
            .updateActorMark(shot.id, entity.id, actorMark),
            .applyMotion(shot.id, entity.id, motionID: "wave", atFrame: 0),
            .overlayMotion(shot.id, entity.id, motionID: "wave"),
            .updateCameraMark(shot.id, cameraMark),
        ]
        for command in commands {
            let store = ShotsStore(catalog: catalog, document: document, saveURL: nil)
            try store.perform(command)
            #expect(store.canUndo)
            #expect(store.document.scenes[0].revision == scene.revision + 1)
            store.undo()
            #expect(store.document == document)
            #expect(!store.canUndo)
        }
    }

    @Test func sliderPreviewCommitsOnceAndEscapeLatchesUntilRelease() throws {
        let store = try makeStore()
        let shot = try #require(store.currentShot)
        let before = store.document
        var gesture = ShotsInspectorGesture()
        gesture.cancel() // Escape while idle must not suppress the next real drag.
        for intensity in [0.2, 0.4, 0.6] {
            store.preview = gesture.update(.setCameraRig(
                shot.id,
                sensor: .super35,
                rig: .handheld,
                intensity: intensity
            ))
        }
        #expect(store.document == before)
        #expect(!store.canUndo)
        let finished = gesture.finish()
        let command = try #require(finished)
        store.preview = nil
        try store.perform(command, coalescing: true)
        #expect(store.currentShot?.camera.rigIntensity == 0.6)
        store.undo()
        #expect(store.document == before)
        #expect(!store.canUndo)
        store.preview = gesture.update(.setCameraRig(shot.id, sensor: .super35, rig: .handheld, intensity: 0.8))
        gesture.cancel()
        store.preview = nil
        let cancelledUpdate = gesture.update(.setCameraRig(shot.id, sensor: .super35, rig: .handheld, intensity: 0.9))
        #expect(cancelledUpdate == nil)
        let cancelledFinish = gesture.finish()
        #expect(cancelledFinish == nil)
        #expect(store.document == before)
        #expect(!store.canUndo)
        let nextGesture = gesture.update(command)
        #expect(nextGesture != nil)
    }

    @Test func promptCapturesRevisionAndIsOneUndoStep() async throws {
        let store = try makeStore()
        let before = store.document
        let revision = try #require(store.currentScene?.revision)
        let client = InspectorPromptClient()
        try await ShotsPromptAction.write(store: store) { facts in
            try await ShotPromptCompiler.write(facts, endpoint: ResolvedEndpoint(client: client))
        }
        let prompt = try #require(store.currentShot?.prompt)
        let received = try #require(await client.receivedFacts)
        #expect(await client.requestCount == 1)
        #expect(received.sceneRevision == revision && received.frameCount == 124)
        #expect(received.cameraLegs.map(\.move) == [.push])
        #expect(prompt.sceneRevision == revision && prompt.writtenBy == "inspector-fake")
        #expect(prompt.text == """
        How the reference pictures align with the target video — Picture 1 (from Shot 1) aligns with the 0.00-second \
        mark of the target video; Picture 2 (from Shot 1) aligns with the 5.12-second mark of the target video.

        integrated_multimodal_description: [Shot 1] The man walks toward the woman.

        overall_soundscape: Footsteps.

        non_diegetic_music: N/A
        """)
        #expect(store.currentScene?.revision == revision)
        store.undo()
        #expect(store.document == before)
        #expect(!store.canUndo)
    }

    @Test func promptCompletionAfterAnEditStaysStaleAndCancellationNeverWrites() async throws {
        let store = try makeStore()
        let shot = try #require(store.currentShot)
        let revision = try #require(store.currentScene?.revision)
        try await ShotsPromptAction.write(store: store, writer: { facts in
            try store.perform(.setNotes(shot.id, ShotNotes(description: "Changed while writing", sound: "", music: "")))
            return ShotPrompt(text: "From old blocking", sceneRevision: facts.sceneRevision, writtenBy: "fake endpoint")
        })
        #expect(store.currentShot?.prompt?.sceneRevision == revision)
        #expect(store.currentScene?.revision == revision + 1)
        let before = store.document
        await #expect(throws: CancellationError.self) {
            try await ShotsPromptAction.write(store: store, writer: { _ in throw CancellationError() })
        }
        #expect(store.document == before)
    }

    private func makeStore() throws -> ShotsStore {
        try ShotsStore(catalog: ContentCatalog.bundled(), document: ShotsSamples.twoPersonWalk(), saveURL: nil)
    }
}

/// Exercises the real StructuredStage/ResolvedEndpoint seam without contacting a provider.
private actor InspectorPromptClient: ModelClient {
    nonisolated let requestedModel = "inspector-fake"
    private(set) var receivedFacts: PromptFacts?
    private(set) var requestCount = 0

    func request(
        instructions: String,
        messages: [ChatMessage],
        output: OutputRequest,
        settings: RequestSettings,
        onPartialText: (@Sendable (String) async -> Void)?
    ) async throws -> ModelReply {
        requestCount += 1
        let text = messages.last?.content.compactMap { content -> String? in
            if case let .text(text) = content { return text }
            return nil
        }.joined(separator: "\n") ?? ""
        let start = try #require(text.range(of: "Its facts:\n\n")?.upperBound)
        receivedFacts = try JSONDecoder().decode(PromptFacts.self, from: Data(text[start...].utf8))
        return ModelReply(text: """
        {"integrated_multimodal_description":"[Shot 1] The man walks toward the woman.",
        "overall_soundscape":"Footsteps.","non_diegetic_music":"N/A"}
        """, servedModel: nil)
    }
}
