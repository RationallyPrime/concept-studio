import Foundation

extension StudioProject {
    /// A hand-edited trigger can leave the sole reference under its former UTF-8 hex name.
    /// Recover only the unambiguous one-concept, one-reference case; every write uses the canonical name.
    func recoverSingleConceptReference() throws {
        guard job.concepts.count == 1, let concept = job.concepts.first,
              concept.targetConcept.requiresLocator else { return }
        let canonical = referenceURL(for: concept.trigger)
        let manager = FileManager.default
        guard !manager.fileExists(atPath: canonical.path),
              let contents = try? manager.contentsOfDirectory(
                  at: canonical.deletingLastPathComponent(), includingPropertiesForKeys: [.isRegularFileKey],
                  options: [.skipsHiddenFiles]
              ) else { return }
        let images = contents.filter { $0.pathExtension.lowercased() == "png" }
        guard images.count == 1, let orphan = images.first,
              try orphan.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { return }
        let name = Array(orphan.deletingPathExtension().lastPathComponent)
        guard !name.isEmpty, name.count.isMultiple(of: 2) else { return }
        let bytes = stride(from: 0, to: name.count, by: 2).compactMap {
            UInt8(String(name[$0 ... $0 + 1]), radix: 16)
        }
        guard bytes.count == name.count / 2, String(bytes: bytes, encoding: .utf8) != nil else { return }
        try manager.moveItem(at: orphan, to: canonical)
    }
}
