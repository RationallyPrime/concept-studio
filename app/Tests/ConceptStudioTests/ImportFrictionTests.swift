import ConceptCore
@testable import ConceptStudio
import Foundation
import Testing

@Suite("Project import friction")
@MainActor
struct ImportFrictionTests {
    @Test func nestedFolderImportsAllMediaAndTheirOwnCaptions() async throws {
        let directory = temporaryTestDirectory("recursive-import")
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("input")
        let nested = input.appendingPathComponent("people/portraits")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let bytes = try MediaEditor.png(MediaFixtures.image())
        try bytes.write(to: input.appendingPathComponent("same.png"))
        try bytes.write(to: nested.appendingPathComponent("same.png"))
        try Data("top-level caption".utf8).write(to: input.appendingPathComponent("same.txt"))
        try Data("nested caption".utf8).write(to: nested.appendingPathComponent("same.txt"))
        let files = try MediaEditor.importableFiles(in: input)
        #expect(files.count == 2)
        var project = try StudioProject.create(at: directory.appendingPathComponent("project"))
        try await project.importFiles(files)
        #expect(Set(project.images.map(\.id)) == ["same.png", "same-2.png"])
        #expect(Set(project.images.map(\.caption)) == ["top-level caption", "nested caption"])
    }

    @Test func newProjectRefusesExistingNonprojectBeforeClosingCurrentProject() async throws {
        let directory = temporaryTestDirectory("new-project-collision")
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = StudioSession(preferences: isolatedDefaults(), secrets: MemorySecretStore())
        let original = try StudioProject.create(at: directory.appendingPathComponent("original"))
        session.project = original
        let target = directory.appendingPathComponent("occupied")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("keep me".utf8).write(to: target.appendingPathComponent("notes.txt"))
        session.createProject(at: target)
        await session.task?.value
        #expect(session.project?.directory == original.directory)
        #expect(session.errorMessage?.contains("already exists") == true)
        #expect(!FileManager.default.fileExists(atPath: target.appendingPathComponent("images").path))
    }

    @Test func newProjectOpensExistingProjectAndRemembersParent() async throws {
        let directory = temporaryTestDirectory("new-existing-project")
        defer { try? FileManager.default.removeItem(at: directory) }
        let preferences = isolatedDefaults()
        let session = StudioSession(preferences: preferences, secrets: MemorySecretStore())
        var project = try StudioProject.create(at: directory.appendingPathComponent("named project"))
        _ = try project.importData(MediaEditor.png(MediaFixtures.image()), name: "kept.png")
        session.createProject(at: project.directory)
        await session.task?.value
        session.stopImageAnalysis()
        #expect(session.project?.images.map(\.id) == ["kept.png"])
        #expect(preferences.string(forKey: ProjectAccess.lastParentKey) == directory.path)
    }

    @Test func exactDuplicatesAreGroupedAndHighestResolutionIsKeptByDefault() async throws {
        let directory = temporaryTestDirectory("duplicate-bytes")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = try MediaEditor.png(MediaFixtures.image(width: 640, height: 512))
        let first = directory.appendingPathComponent("a.png")
        let second = directory.appendingPathComponent("b.png")
        try bytes.write(to: first)
        try bytes.write(to: second)
        let analyses = try await VisionInspector().analyze([first, second])
        #expect(analyses["b.png"]?.duplicateOf == "a.png")
        #expect(analyses["b.png"]?.warnings.contains { $0.contains("Exact duplicate") } == true)
        let groups = DuplicateCuration.groups(
            images: [ProjectImage(url: first), ProjectImage(url: second)],
            analyses: analyses
        )
        #expect(groups.count == 1)
        #expect(DuplicateCuration.recommendedExclusions(groups: groups, analyses: analyses) == ["b.png"])
        var larger = analyses
        larger["b.png"]?.width = 1280
        larger["b.png"]?.height = 1024
        #expect(DuplicateCuration.recommendedExclusions(groups: groups, analyses: larger) == ["a.png"])
    }

    private func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "ImportFrictionTests.\(UUID())")!
    }
}
