import ConceptCore
@testable import ConceptStudio
import Foundation
import Testing

@Suite("Shots workspace navigation")
@MainActor
struct ShotsWorkspaceTests {
    @Test func openingAnEmptyProjectCreatesAStoreAndFlushesBeforeRelease() async throws {
        let defaults = IsolatedDefaults()
        defer { defaults.remove() }
        let directory = temporaryTestDirectory("Shots-session")
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try StudioProject.create(at: directory)
        let session = makeTestSession(preferences: defaults.defaults)
        session.openProject(url: directory)
        await session.task?.value
        let store = try #require(session.shots)
        #expect(store.document.scenes.isEmpty)
        let step = session.step
        session.workspace = .shots
        session.workspace = .training
        #expect(session.step == step)
        try store.perform(.addScene(
            id: "scene_session",
            name: "Practice",
            takeID: "take_session",
            shotID: "shot_session",
            cameraMarkID: "camera_session"
        ))
        store.playhead = 61
        #expect(store.frame?.index == 61)
        let expected = store.document

        #expect(await session.releaseProject())
        #expect(session.shots == nil)
        #expect(session.project == nil)
        session.openProject(url: directory)
        await session.task?.value
        #expect(session.shots?.document == expected)
        #expect(await session.releaseProject())
    }

    @Test func failedShotsSaveKeepsTheProjectAndEditsOpen() async throws {
        let defaults = IsolatedDefaults()
        defer { defaults.remove() }
        let directory = temporaryTestDirectory("Shots-failed-save")
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try StudioProject.create(at: directory)
        let session = makeTestSession(preferences: defaults.defaults)
        session.openProject(url: directory)
        await session.task?.value
        let store = try #require(session.shots)
        try store.perform(.addScene(
            id: "scene_retained",
            name: "Practice",
            takeID: "take_retained",
            shotID: "shot_retained",
            cameraMarkID: "camera_retained"
        ))
        let url = ShotsDocumentFile.url(in: directory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        #expect(await session.releaseProject() == false)
        #expect(session.shots === store)
        #expect(session.project?.directory == directory)
        #expect(session.errorMessage != nil)
        #expect(store.canUndo)

        try FileManager.default.removeItem(at: url)
        #expect(await session.releaseProject())
        #expect(try ShotsDocumentFile.load(from: url).document == store.document)
    }

    @Test(arguments: [StudioStep.images, .concepts, .pods])
    func switchingWorkspacesPreservesConceptFreeProject(step: StudioStep) throws {
        let defaults = IsolatedDefaults()
        defer { defaults.remove() }
        let directory = temporaryTestDirectory("Shots-workspace")
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = makeTestSession(preferences: defaults.defaults)
        session.project = try StudioProject.create(at: directory)
        session.step = step
        let jobURL = directory.appendingPathComponent("job.yaml")
        let originalJob = try Data(contentsOf: jobURL)

        #expect(session.project?.job.concepts.isEmpty == true)
        #expect(session.workspace == .training)
        session.workspace = .shots
        #expect(session.step == step)
        session.workspace = .training
        #expect(session.step == step)
        #expect(try Data(contentsOf: jobURL) == originalJob)
    }
}
