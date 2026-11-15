import Foundation
import PrevisCore

/// Where each scene's shot packages go. A scene exports into the project's own `Shots` folder until the user
/// chooses another folder for it, such as the scene's folder in a production tree. That choice is made once in an
/// open panel and kept as a security-scoped bookmark, so the sandboxed app can write there again after a relaunch.
/// It lives in preferences, not in the Shots file: a bookmark only works on the Mac that made it.
struct ShotsExportFolders {
    static let key = "ConceptStudio.shotsExportFolders"

    struct Entry: Codable, Equatable {
        var project: String
        var scene: SceneID
        var path: String
        var bookmark: Data
    }

    /// A folder to write into, open until `close()`.
    struct OpenFolder {
        let url: URL
        /// Whether the user chose this folder for the scene; false for the project's own `Shots` folder.
        let chosen: Bool
        fileprivate let scoped: Bool

        func close() {
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
    }

    let preferences: UserDefaults

    var entries: [Entry] {
        guard let data = preferences.data(forKey: Self.key) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    /// The folder the user chose for this scene, as a path to show; nil while it exports into the project.
    func chosenPath(forScene scene: SceneID, inProject project: URL) -> String? {
        entry(scene, project)?.path
    }

    func choose(_ folder: URL, forScene scene: SceneID, inProject project: URL) throws {
        let bookmark = try folder.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let entry = Entry(project: Self.name(of: project), scene: scene, path: folder.path, bookmark: bookmark)
        write(entries.filter { !Self.matches($0, scene, project) } + [entry])
    }

    /// Back to the project's own `Shots` folder.
    func clear(forScene scene: SceneID, inProject project: URL) {
        write(entries.filter { !Self.matches($0, scene, project) })
    }

    /// Opens the folder this scene exports into. A chosen folder that can't be reached is an error, never a quiet
    /// return to the project's folder: the user would look for the package in the wrong place.
    func open(forScene scene: SceneID, inProject project: URL) throws -> OpenFolder {
        guard let entry = entry(scene, project) else {
            return OpenFolder(url: Self.projectFolder(in: project), chosen: false, scoped: false)
        }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: entry.bookmark, options: .withSecurityScope, relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else { throw Self.unreachable(entry.path) }
        let scoped = url.startAccessingSecurityScopedResource()
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), isFolder.boolValue else {
            if scoped { url.stopAccessingSecurityScopedResource() }
            throw Self.unreachable(entry.path)
        }
        // A folder that was moved or renamed is followed, and shown under its new path.
        if stale || url.path != entry.path { try? choose(url, forScene: scene, inProject: project) }
        return OpenFolder(url: url, chosen: true, scoped: scoped)
    }

    static func projectFolder(in project: URL) -> URL {
        project.appendingPathComponent("Shots", isDirectory: true)
    }

    private func entry(_ scene: SceneID, _ project: URL) -> Entry? {
        entries.first { Self.matches($0, scene, project) }
    }

    private static func matches(_ entry: Entry, _ scene: SceneID, _ project: URL) -> Bool {
        entry.scene == scene && entry.project == name(of: project)
    }

    private static func name(of project: URL) -> String {
        project.standardizedFileURL.path
    }

    private static func unreachable(_ path: String) -> StudioError {
        .message(
            "The export folder chosen for this scene can't be opened: "
                + "\((path as NSString).abbreviatingWithTildeInPath). It may have been moved or deleted. "
                + "Under Export, choose the folder again or go back to the project's Shots folder."
        )
    }

    private func write(_ entries: [Entry]) {
        if let data = try? JSONEncoder().encode(entries) { preferences.set(data, forKey: Self.key) }
    }
}
