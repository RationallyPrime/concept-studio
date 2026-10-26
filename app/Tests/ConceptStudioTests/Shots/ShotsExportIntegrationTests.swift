import ConceptCore
@testable import ConceptStudio
import Foundation
import PrevisCore
import ShotsMedia
import Testing

@Suite("Shots saved-project export integration")
@MainActor
struct ShotsExportIntegrationTests {
    @Test(.enabled(if: ShotFrameRenderer.isAvailable))
    func editedProjectReopensAndExportsAValidTwentyTwoFramePackage() async throws {
        let defaults = IsolatedDefaults()
        defer { defaults.remove() }
        let directory = temporaryTestDirectory("Shots-IT3")
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try StudioProject.create(at: directory)
        let session = makeTestSession(preferences: defaults.defaults)
        session.openProject(url: directory)
        await session.task?.value
        let store = try #require(session.shots)
        let notes = try store.importBlockoutProject(ShotsSamples.blockoutProjectJSON())
        let shotID = try #require(store.currentShotID)
        try store.perform(.renameShot(shotID, name: "IT3 saved shot"))
        try store.perform(.setFrameCount(shotID, 22))
        try store.perform(.setCanvas(shotID, ShotCanvas(width: 320, height: 576)))
        try store.perform(.setGuideFrames(shotID, [11]))
        let expected = store.document
        let expectedNotes = try BlockoutImport.document(
            fromProjectJSON: ShotsSamples.blockoutProjectJSON(), catalog: store.catalog
        ).notes
        #expect(notes == expectedNotes)

        #expect(await session.releaseProject())
        session.openProject(url: directory)
        await session.task?.value
        let reopened = try #require(session.shots)
        #expect(reopened.document == expected)
        let snapshot = try reopened.exportSnapshot()
        let destination = directory.appendingPathComponent("Shots", isDirectory: true)
        let exporter = try ShotExporter(catalog: reopened.catalog)
        var progress: [ExportProgress] = []
        let package = try await exporter.export(
            scene: snapshot.scene, shotID: snapshot.shotID, options: .standard,
            to: FolderDestination(parent: destination)
        ) { progress.append($0) }

        #expect(package.url.path.hasPrefix(destination.path + "/"))
        #expect(package.manifest.frameCount == 22)
        #expect(package.manifest.canvas == ShotCanvas(width: 320, height: 576))
        #expect(package.manifest.shot.id == shotID)
        #expect(package.manifest.shot.sceneRevision == snapshot.scene.revision)
        #expect(!progress.isEmpty)
        #expect(progress.last?.fractionCompleted == 1)
        let problems = await PackageValidator.problems(at: package.url)
        #expect(problems.isEmpty, "Invalid exported package: \(problems)")
        #expect(await session.releaseProject())
    }
}
