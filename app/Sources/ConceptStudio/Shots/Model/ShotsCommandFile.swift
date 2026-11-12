import Foundation
import PrevisCore

@MainActor
enum ShotsCommandFile {
    static let usage = """
    Usage: ConceptStudio --shots-commands <project folder> <commands.json>
    Applies one JSON array of Shots commands to the project in a single edit.
    Use shots-export --document <project folder>/.conceptstudio/shots.json --shot <id> --out <folder> to render.
    """

    static func run(_ arguments: [String]) -> Int32 {
        if arguments == ["--help"] {
            print(usage)
            return 0
        }
        guard arguments.count == 2, !arguments.contains(where: { $0.hasPrefix("--") }) else {
            FileHandle.standardError.write(Data((usage + "\n").utf8))
            return 2
        }
        do {
            let project = URL(fileURLWithPath: arguments[0], isDirectory: true)
            let commands = URL(fileURLWithPath: arguments[1])
            let destination = try apply(commands, to: project, catalog: ContentCatalog.bundled())
            print(destination.path)
            return 0
        } catch {
            FileHandle.standardError.write(Data("shots-commands: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    @discardableResult
    static func apply(_ commandFile: URL, to project: URL, catalog: ContentCatalog) throws -> URL {
        let decoder = JSONDecoder()
        let commands = try decoder.decode([ShotsCommand].self, from: Data(contentsOf: commandFile))
        let destination = ShotsDocumentFile.url(in: project)
        let document: ShotsDocument
        if FileManager.default.fileExists(atPath: destination.path) {
            document = try decoder.decode(ShotsDocument.self, from: Data(contentsOf: destination))
            guard document.version == ShotsDocument.currentVersion else {
                throw ShotsEditingError.readOnly
            }
        } else {
            document = ShotsDocument(version: ShotsDocument.currentVersion, scenes: [])
        }
        let store = ShotsStore(catalog: catalog, document: document, saveURL: nil)
        try store.perform(commands)
        if !FileManager.default.fileExists(atPath: project.appendingPathComponent("job.yaml").path) {
            _ = try StudioProject.create(at: project)
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try ShotsDocumentFile.save(store.document, to: destination)
        return destination
    }
}
