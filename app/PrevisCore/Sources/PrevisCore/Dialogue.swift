import Foundation

/// An immutable recording copied into the project's scratch audio directory.
public struct ScratchRecording: Codable, Sendable, Equatable {
    public var fileName: String
    public var duration: Double
    public var peaks: [Double]

    public init(fileName: String, duration: Double, peaks: [Double] = []) {
        self.fileName = fileName
        self.duration = duration
        self.peaks = peaks
    }

    public var isValid: Bool {
        let parts = fileName.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].hasPrefix("scratch_"), ["wav", "m4a"].contains(parts[1]) else { return false }
        let id = parts[0].dropFirst("scratch_".count)
        return id.count == 12 && UInt64(id, radix: 16) != nil
            && duration.isFinite && duration > 0 && peaks.allSatisfy { (0 ... 1).contains($0) }
    }
}

public struct DialogueLine: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var speakerID: EntityID?
    public var startFrame: Int
    public var text: String
    public var recording: ScratchRecording?

    public init(
        id: String,
        speakerID: EntityID? = nil,
        startFrame: Int,
        text: String,
        recording: ScratchRecording? = nil
    ) {
        self.id = id
        self.speakerID = speakerID
        self.startFrame = startFrame
        self.text = text
        self.recording = recording
    }
}

public extension Shot {
    var audioClips: [(recording: ScratchRecording, startFrame: Int)] {
        let mix: [(ScratchRecording, Int)] = scratchAudio.map { [($0, 0)] } ?? []
        return mix + dialogue.compactMap { line in
            line.recording.map { ($0, line.startFrame) }
        }
    }
}
