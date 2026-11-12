import AppKit
import ConceptCore
import PrevisCore

extension ShotsStore {
    func referenceURL(_ reference: ShotReference) -> URL? {
        guard reference.isValid else { return nil }
        return saveURL?.deletingLastPathComponent()
            .appendingPathComponent("shots-references", isDirectory: true)
            .appendingPathComponent(reference.fileName)
    }

    func importReference(from source: URL, shotID: ShotID) throws {
        guard !isReadOnly else { throw ShotsEditingError.readOnly }
        let reference = ShotReference(fileName: newID("reference"), opacity: 0.5)
        guard let destination = referenceURL(reference) else { throw ShotsEditingError.missing("project folder") }
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: source, options: .mappedIfSafe)
        guard NSImage(data: data)?.isValid == true else { throw CocoaError(.fileReadCorruptFile) }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try AtomicFile.write(data, to: destination)
        // Retain replaced images for undo.
        try perform(.setReference(shotID, reference))
    }
}
