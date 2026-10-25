import ConceptCore
@testable import ConceptStudio
import Foundation
import Testing
import UniformTypeIdentifiers

@Suite("full-size media viewer")
@MainActor
struct MediaViewerTests {
    @Test func navigationKeepsOrderAndStopsAtEnds() throws {
        let first = MediaViewerItem.project("first.jpg")
        let second = MediaViewerItem.project("second.mp4")
        var selection = try #require(MediaViewerSelection(item: first, items: [first, second]))
        selection.move(-1)
        #expect(selection.item == first)
        selection.move(1)
        #expect(selection.item == second)
        selection.move(1)
        #expect(selection.index == 1)
        selection.move(-1)
        #expect(selection.item == first)
        #expect(MediaViewerSelection(item: first, items: []) == nil)
    }

    @Test func metadataReadsOriginalImageDimensionsAndFileSize() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let data = try MediaFixtures.encoded(MediaFixtures.image(width: 1024, height: 768), type: .png)
        let url = folder.appendingPathComponent("original.png")
        try data.write(to: url)
        let info = try await MediaViewerFileInfo.read(url)
        #expect(info.width == 1024)
        #expect(info.height == 768)
        #expect(info.bytes == data.count)
    }

    @Test func metadataReadsClipDimensions() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("clip.mp4")
        try await MediaFixtures.video(at: url, width: 80, height: 64)
        let info = try await MediaViewerFileInfo.read(url)
        #expect(info.width == 80)
        #expect(info.height == 64)
        #expect(info.bytes > 0)
    }

    @Test func importSourceSurvivesReopenAndOldMediaStateLoads() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let sourceFolder = folder.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        let source = sourceFolder.appendingPathComponent("source.png")
        try MediaFixtures.encoded(MediaFixtures.image(), type: .png).write(to: source)
        let target = folder.appendingPathComponent("project")
        var project = try StudioProject.create(at: target)
        try await project.importFiles([source])
        let id = try #require(project.images.first?.id)
        let reopened = try await StudioProject.open(at: target)
        #expect(reopened.mediaState.origins[id] == "Folder · source.png")
        let oldState = try JSONDecoder().decode(ProjectMediaState.self, from: Data("{}".utf8))
        #expect(oldState.origins.isEmpty)
    }

    @Test func excludedCaptionEditsWriteBesideExcludedFileAndReopen() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let suite = "MediaViewerTests." + UUID().uuidString
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        var project = try StudioProject.create(at: folder)
        let id = try project.importData(MediaFixtures.encoded(MediaFixtures.image(), type: .png), name: "sample.png")
        try project.setIncluded(id, false)
        let session = StudioSession(preferences: preferences)
        session.project = project
        session.saveCaption(id: id, text: "Caption edited while excluded.", final: false)
        await session.editTask?.value
        #expect(session.errorMessage == nil)
        #expect(session.project?.excludedImages.first?.caption == "Caption edited while excluded.")
        #expect(!FileManager.default
            .fileExists(atPath: project.imagesDirectory.appendingPathComponent("sample.txt").path))
        let reopened = try await StudioProject.open(at: folder)
        #expect(reopened.excludedImages.first?.caption == "Caption edited while excluded.")
    }

    private func temporaryDirectory() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaViewerTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}
