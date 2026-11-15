@testable import ConceptStudio
import Foundation
import Testing

/// Where a scene's shot packages go: the project's Shots folder, or a folder chosen for that scene.
@Suite("Shots export folders")
struct ShotsExportFolderTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShotsExportFolderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The temporary directory is reached through a symbolic link, so one folder has two spellings.
    private func same(_ path: String?, _ url: URL) -> Bool {
        path.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } == url.resolvingSymlinksInPath().path
    }

    @Test func aSceneExportsIntoItsChosenFolderAndTheOthersStayInTheProject() throws {
        let preferences = IsolatedDefaults()
        defer { preferences.remove() }
        let project = try folder(), other = try folder(), production = try folder()
        defer { for url in [project, other, production] {
            try? FileManager.default.removeItem(at: url)
        } }
        let folders = ShotsExportFolders(preferences: preferences.defaults)

        try folders.choose(production, forScene: "scene_a", inProject: project)
        // A second store over the same preferences reads the choice, as the app does after a relaunch.
        let later = ShotsExportFolders(preferences: preferences.defaults)
        let chosen = try later.open(forScene: "scene_a", inProject: project)
        defer { chosen.close() }
        #expect(same(chosen.url.path, production))
        #expect(chosen.chosen)
        #expect(same(later.chosenPath(forScene: "scene_a", inProject: project), production))

        let sibling = try later.open(forScene: "scene_b", inProject: project)
        #expect(sibling.url == project.appendingPathComponent("Shots", isDirectory: true))
        #expect(!sibling.chosen)
        #expect(try !later.open(forScene: "scene_a", inProject: other).chosen)

        later.clear(forScene: "scene_a", inProject: project)
        #expect(try later.open(forScene: "scene_a", inProject: project).url == sibling.url)
    }

    @Test func aChosenFolderThatIsGoneIsAnErrorAndNeverAQuietReturnToTheProject() throws {
        let preferences = IsolatedDefaults()
        defer { preferences.remove() }
        let project = try folder(), production = try folder()
        defer { try? FileManager.default.removeItem(at: project) }
        let folders = ShotsExportFolders(preferences: preferences.defaults)
        try folders.choose(production, forScene: "scene_a", inProject: project)
        try FileManager.default.removeItem(at: production)

        #expect { try folders.open(forScene: "scene_a", inProject: project) } throws: { error in
            error.localizedDescription.contains("can't be opened")
                && error.localizedDescription.contains("choose the folder again")
        }
        // The choice stays, so the Export controls still show which folder is missing.
        #expect(same(folders.chosenPath(forScene: "scene_a", inProject: project), production))
    }
}
