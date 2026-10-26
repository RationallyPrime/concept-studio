import ConceptCore
@testable import ConceptStudio
import Foundation
import PrevisCore
import Testing

@Suite("Shots store boundary coverage")
@MainActor
struct ShotsStoreBoundaryTests {
    @Test func sessionReopensTheEditedDocumentAfterUndoAndRedo() async throws {
        let defaults = IsolatedDefaults()
        defer { defaults.remove() }
        let directory = temporaryTestDirectory("Shots-command-session")
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try StudioProject.create(at: directory)
        let session = makeTestSession(preferences: defaults.defaults)
        session.openProject(url: directory)
        await session.task?.value
        let store = try #require(session.shots)
        try store.perform(.addScene(
            id: "scene_commands", name: "Practice", takeID: "take_commands",
            shotID: "shot_commands", cameraMarkID: "camera_initial"
        ))
        var actor = ShotsSamples.twoPersonWalk().scenes[0].entities[0]
        actor.id = "actor_first"
        try store.perform(.addEntity("scene_commands", actor))
        actor.id = "actor_second"
        try store.perform(.addEntity("scene_commands", actor))
        for index in 0 ..< 3 {
            let mark = ActorMark(
                id: "actor_mark_\(index)", time: Double(index), hold: 0, easeIn: 0,
                easeOut: 0, position: .zero, gait: .walk
            )
            try store.perform(.addActorMark("shot_commands", "actor_first", mark))
        }
        var camera = try #require(store.currentShot?.camera.marks.first)
        camera.id = "camera_later"
        camera.time = 2
        try store.perform(.addCameraMark("shot_commands", camera))
        store.undo()
        store.undo()
        store.redo()
        let expected = store.document
        #expect(await session.releaseProject())
        #expect(session.shots == nil)
        session.openProject(url: directory)
        await session.task?.value
        #expect(session.shots?.document == expected)
        #expect(await session.releaseProject())
    }

    @Test func historyKeepsOnlyTheLastTwoHundredSteps() throws {
        let store = try sampleStore()
        let id = try #require(store.currentSceneID)
        for index in 1 ... 205 {
            try store.perform(.renameScene(id, name: "Scene \(index)"))
        }
        for _ in 0 ..< 200 {
            store.undo()
        }
        #expect(store.currentScene?.name == "Scene 5")
        #expect(!store.canUndo)
        #expect(store.canRedo)
        for _ in 0 ..< 200 {
            store.redo()
        }
        #expect(store.currentScene?.name == "Scene 205")
        #expect(!store.canRedo)
    }

    @Test func invalidPreviewAndRunDoNotMutateCommittedStateOrHistory() throws {
        let store = try sampleStore()
        let original = store.document
        store.playhead = 61
        store.preview = .renameScene("missing_scene", name: "Preview")
        #expect(store.problems.contains { $0.severity == .error })
        #expect(store.document == original)
        #expect(store.frame?.index == 61)
        #expect(!store.canUndo)
        var message: String?
        store.onError = { message = $0 }
        store.run(.renameScene("missing_scene", name: "Commit"))
        #expect(message?.contains("scene") == true)
        #expect(store.document == original)
        #expect(!store.canUndo)
    }

    @Test func debouncedSaveWritesTheLatestCommittedEdit() async throws {
        let directory = temporaryTestDirectory("Shots-debounce")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = ShotsDocumentFile.url(in: directory)
        let store = try sampleStore(saveURL: url)
        let id = try #require(store.currentSceneID)
        try store.perform(.renameScene(id, name: "First"))
        try store.perform(.renameScene(id, name: "Last"))
        // Other main-actor tests can delay both this test and the save task.
        // Bound polling opportunities rather than expiring before the saver can resume.
        for _ in 0 ..< 60 {
            if FileManager.default.fileExists(atPath: url.path) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(FileManager.default.fileExists(atPath: url.path))
        #expect(try ShotsDocumentFile.load(from: url).document == store.document)
        #expect(store.currentScene?.name == "Last")
    }

    private func sampleStore(saveURL: URL? = nil) throws -> ShotsStore {
        try ShotsStore(catalog: ContentCatalog.bundled(), document: ShotsSamples.twoPersonWalk(), saveURL: saveURL)
    }
}
