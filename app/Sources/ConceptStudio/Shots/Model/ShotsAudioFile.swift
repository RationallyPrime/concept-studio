import ConceptCore
import Foundation
import PrevisCore
import ShotsMedia

extension ShotsStore {
    var audioDirectory: URL? {
        saveURL?.deletingLastPathComponent().appendingPathComponent("shots-audio", isDirectory: true)
    }

    func importScratchAudio(from source: URL, shotID: ShotID, lineID: String?) async throws {
        guard !isReadOnly else { throw ShotsEditingError.readOnly }
        guard let audioDirectory else { throw ShotsEditingError.missing("project folder") }
        let type = source.pathExtension.lowercased()
        guard ["wav", "m4a"].contains(type) else { throw CocoaError(.fileReadUnsupportedScheme) }
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let waveform = try await ScratchAudio.waveform(at: source)
        guard let shot = document.scenes.lazy.compactMap({ $0.shots.first { $0.id == shotID } }).first else {
            throw ShotsEditingError.missing("shot")
        }
        let recording = ScratchRecording(
            fileName: "\(newID("scratch")).\(type)", duration: waveform.duration, peaks: waveform.peaks
        )
        var command = ShotsCommand.setScratchAudio(shotID, recording)
        if let lineID {
            var lines = shot.dialogue
            guard let index = lines.firstIndex(where: { $0.id == lineID }) else {
                throw ShotsEditingError.missing("dialogue line")
            }
            lines[index].recording = recording
            command = .setDialogue(shotID, lines)
        }
        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        try AtomicFile.write(
            Data(contentsOf: source, options: .mappedIfSafe),
            to: audioDirectory.appendingPathComponent(recording.fileName)
        )
        try perform(command)
    }
}
