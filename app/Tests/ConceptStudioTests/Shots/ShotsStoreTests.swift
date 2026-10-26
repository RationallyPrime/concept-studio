@testable import ConceptStudio
import Foundation
import Observation
import PrevisCore
import Synchronization
import Testing

@Suite("Shots editing and persistence")
@MainActor
struct ShotsStoreTests {
    @Test func previewCommitUndoAndRedoKeepTheDocumentBoundary() throws {
        let document = ShotsSamples.twoPersonWalk()
        let originalRevision = try #require(document.scenes.first?.revision)
        let store = try sampleStore(document)
        let original = try #require(store.currentScene?.entities.first)
        var moved = original.placement
        moved.position.x += 2
        store.playhead = 61
        #expect(store.frame?.index == 61)
        store.preview = .setPlacement(original.id, moved)
        #expect(store.currentScene?.entities.first?.placement == moved)
        #expect(store.document == document)
        #expect(!store.canUndo)
        let invalidated = Mutex(false)
        withObservationTracking { _ = store.canUndo } onChange: { invalidated.withLock { $0 = true } }

        try store.perform(.setPlacement(original.id, moved))

        #expect(invalidated.withLock { $0 })
        #expect(store.preview == nil)
        #expect(store.document.scenes.first?.revision == originalRevision + 1)
        let committed = store.document
        store.undo()
        #expect(store.document == document)
        store.redo()
        #expect(store.document == committed)
    }

    @Test func editedDocumentSurvivesFlushAndReopenWithoutTouchingTrainingFiles() throws {
        let directory = temporaryTestDirectory("Shots-store")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let job = directory.appendingPathComponent("job.yaml")
        let sentinel = Data("training file is independent".utf8)
        try sentinel.write(to: job)
        let url = ShotsDocumentFile.url(in: directory)
        let store = try sampleStore(ShotsDocument(version: ShotsDocument.currentVersion, scenes: []), saveURL: url)
        try store.perform(.addScene(
            id: "scene_new",
            name: "Practice",
            takeID: "take_new",
            shotID: "shot_new",
            cameraMarkID: "camera_initial"
        ))
        var actor = ShotsSamples.twoPersonWalk().scenes[0].entities[0]
        actor.id = "actor_one"
        try store.perform(.addEntity("scene_new", actor))
        actor.id = "actor_two"
        try store.perform(.addEntity("scene_new", actor))
        for index in 0 ..< 3 {
            let mark = ActorMark(
                id: "mark_\(index)",
                time: Double(index),
                hold: 0,
                easeIn: 0,
                easeOut: 0,
                position: .zero,
                gait: .walk
            )
            try store.perform(.addActorMark("shot_new", "actor_one", mark))
        }
        var camera = try #require(store.currentShot?.camera.marks.first)
        camera.id = "camera_later"
        camera.time = 2
        try store.perform(.addCameraMark("shot_new", camera))
        store.undo()
        store.undo()
        store.redo()
        let expected = store.document

        try store.flush()
        let reopened = try ShotsDocumentFile.load(from: url)

        #expect(reopened.document == expected)
        #expect(try Data(contentsOf: job) == sentinel)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("images").path))
    }

    @Test func sliderCoalescingIsExplicitAndRegularCommandsStaySeparate() throws {
        let document = ShotsSamples.twoPersonWalk()
        let coalesced = try sampleStore(document)
        let regular = try sampleStore(document)
        let actor = try #require(coalesced.currentScene?.entities.first)
        for index in 1 ... 10 {
            var moved = actor.placement
            moved.position.x += Double(index)
            try coalesced.perform(.setPlacement(actor.id, moved), coalescing: true)
            try regular.perform(.setPlacement(actor.id, moved))
        }
        coalesced.undo()
        regular.undo()
        #expect(coalesced.document == document)
        #expect(!coalesced.canUndo)
        #expect(regular.currentScene?.entities.first?.placement.position.x == actor.placement.position.x + 9)
        #expect(regular.canUndo)
    }

    @Test func futureVersionRefusesEditsAndNeverWrites() throws {
        let directory = temporaryTestDirectory("Shots-readonly")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = ShotsDocumentFile.url(in: directory)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data("{\"version\":\(ShotsDocument.currentVersion + 1)}".utf8)
        try bytes.write(to: url)
        let loaded = try ShotsDocumentFile.load(from: url)
        let store = try ShotsStore(
            catalog: ContentCatalog.bundled(),
            document: loaded.document,
            saveURL: url,
            readOnly: loaded.readOnly
        )
        var error: String?
        store.onError = { error = $0 }

        store.run(.deleteScene("anything"))
        try store.flush()

        #expect(error?.contains("newer version") == true)
        #expect(!store.canUndo)
        #expect(try Data(contentsOf: url) == bytes)
    }

    @Test func writingAPromptDoesNotImmediatelyMakeItStale() throws {
        let store = try sampleStore(ShotsSamples.twoPersonWalk())
        let shot = try #require(store.currentShot)
        let revision = try #require(store.currentScene?.revision)
        let prompt = ShotPrompt(sections: [], text: "A shot.", sceneRevision: revision, writtenBy: "template")
        try store.perform(.setPrompt(shot.id, prompt))
        #expect(store.currentScene?.revision == revision)
        #expect(store.currentShot?.prompt?.sceneRevision == revision)
        var notes = shot.notes
        notes.description = "The blocking has changed."
        try store.perform(.setNotes(shot.id, notes))
        #expect(store.currentScene?.revision == revision + 1)
        #expect(store.currentShot?.prompt?.sceneRevision == revision)
    }

    private func sampleStore(_ document: ShotsDocument, saveURL: URL? = nil) throws -> ShotsStore {
        try ShotsStore(catalog: ContentCatalog.bundled(), document: document, saveURL: saveURL)
    }
}
