@testable import ConceptStudio
import Foundation
import PrevisCore
import Testing

@Suite("Shots store boundary coverage")
@MainActor
struct ShotsStoreBoundaryTests {
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
        let deadline = ContinuousClock.now + .seconds(3)
        while !FileManager.default.fileExists(atPath: url.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(try ShotsDocumentFile.load(from: url).document == store.document)
        #expect(store.currentScene?.name == "Last")
    }

    private func sampleStore(saveURL: URL? = nil) throws -> ShotsStore {
        try ShotsStore(catalog: ContentCatalog.bundled(), document: ShotsSamples.twoPersonWalk(), saveURL: saveURL)
    }
}
