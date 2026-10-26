import ConceptCore
import Foundation
import PrevisCore

enum ShotsDocumentFile {
    struct Loaded {
        let document: ShotsDocument
        let readOnly: Bool
        let notice: String?
    }

    private struct Version: Decodable {
        let version: Int?
    }

    static func url(in project: URL) -> URL {
        project.appendingPathComponent(".conceptstudio", isDirectory: true)
            .appendingPathComponent("shots.json")
    }

    static func load(from url: URL) throws -> Loaded {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return Loaded(document: emptyDocument(), readOnly: false, notice: nil)
        }
        // File-access errors leave the original in place and reach the session's alert.
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        do {
            let version = try decoder.decode(Version.self, from: data).version ?? ShotsDocument.currentVersion
            if version > ShotsDocument.currentVersion {
                return Loaded(
                    document: emptyDocument(),
                    readOnly: true,
                    notice: "This project's Shots file needs a newer version of ConceptStudio. "
                        + "Update the app to edit it. The original file has been kept."
                )
            }
            return try Loaded(
                document: decoder.decode(ShotsDocument.self, from: data),
                readOnly: false,
                notice: nil
            )
        } catch {
            let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
            let backup = url.deletingLastPathComponent()
                .appendingPathComponent("shots.json.unreadable-\(timestamp)")
            // moveItem refuses to replace an existing backup. If preservation fails, load fails too;
            // no empty writable store is returned while an unpreserved original remains at the save URL.
            try FileManager.default.moveItem(at: url, to: backup)
            return Loaded(
                document: emptyDocument(),
                readOnly: false,
                notice: "The Shots file could not be read. It has been kept as \(backup.lastPathComponent). "
                    + "You can start new blocking or recover that file."
            )
        }
    }

    static func save(_ document: ShotsDocument, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try AtomicFile.write(encoder.encode(document), to: url)
    }

    private static func emptyDocument() -> ShotsDocument {
        ShotsDocument(version: ShotsDocument.currentVersion, scenes: [])
    }
}
