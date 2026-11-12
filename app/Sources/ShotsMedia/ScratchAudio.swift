import AVFoundation
import PrevisCore

/// Reads a scratch recording once when it is imported. The peak samples follow source time, not playback time.
public enum ScratchAudio {
    public static func waveform(at url: URL) async throws -> (duration: Double, peaks: [Double]) {
        try await Task.detached(priority: .userInitiated) {
            let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
            let format = file.processingFormat
            guard file.length > 0, format.sampleRate > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)
            else { throw ShotsMediaError("The scratch recording has no readable audio.") }
            var peaks = [Double](repeating: 0, count: 96)
            while file.framePosition < file.length {
                let start = file.framePosition
                try file.read(into: buffer)
                guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { break }
                for frame in 0 ..< Int(buffer.frameLength) {
                    let fraction = Double(start + Int64(frame)) / Double(file.length)
                    let bin = min(Int(fraction * Double(peaks.count)), peaks.count - 1)
                    for channel in 0 ..< Int(format.channelCount) {
                        let amplitude = Double(abs(channels[channel][frame]))
                        if amplitude.isFinite { peaks[bin] = max(peaks[bin], min(amplitude, 1)) }
                    }
                }
            }
            return (Double(file.length) / format.sampleRate, peaks)
        }.value
    }
}

/// A fresh playback clock is used each time the timeline starts a shot or crosses a cut.
@MainActor public final class ScratchPlayback {
    private var players: [AVAudioPlayer] = []

    public init() {}

    public func stop() {
        players.forEach { $0.stop() }
        players.removeAll()
    }

    public func play(shot: Shot, at frame: Int, endFrame: Int, in directory: URL?) throws {
        stop()
        guard !shot.audioClips.isEmpty else { return }
        guard let directory else { throw ShotsMediaError("Open the project folder to play its scratch recordings.") }
        var scheduled: [(player: AVAudioPlayer, delay: Double)] = []
        for clip in shot.audioClips where clip.startFrame < endFrame {
            guard clip.recording.isValid else { throw ShotsMediaError("A scratch recording reference is invalid.") }
            let offset = FrameGrid.time(ofFrame: frame - clip.startFrame)
            guard offset < clip.recording.duration else { continue }
            let url = directory.appendingPathComponent(clip.recording.fileName)
            let player = try AVAudioPlayer(contentsOf: url)
            player.currentTime = max(0, offset)
            player.prepareToPlay()
            scheduled.append((player, max(0, -offset)))
        }
        if let first = scheduled.first?.player {
            let now = first.deviceCurrentTime + 0.01
            for item in scheduled {
                item.player.play(atTime: now + item.delay)
            }
        }
        players = scheduled.map(\.player)
    }
}

@MainActor enum ScratchAudioMix {
    /// Insert each recording on its own track so overlapping lines mix instead of pushing the next clip later.
    static func write(
        shots: [(shot: Shot, startFrame: Int, endFrame: Int)],
        sourceDirectory: URL?,
        to url: URL
    ) async throws -> Bool {
        guard let (composition, audioTracks) = try await composition(shots: shots, sourceDirectory: sourceDirectory)
        else {
            return false
        }
        try await export(composition, audioTracks: audioTracks, preset: AVAssetExportPresetAppleM4A, to: url, as: .m4a)
        return true
    }

    private static func composition(
        shots: [(shot: Shot, startFrame: Int, endFrame: Int)], sourceDirectory: URL?
    ) async throws -> (AVMutableComposition, [AVMutableCompositionTrack])? {
        let clips = shots.flatMap { edit in
            edit.shot.audioClips.compactMap { clip -> (ScratchRecording, Int, Int)? in
                guard clip.startFrame >= 0, clip.startFrame < edit.endFrame - edit.startFrame else { return nil }
                return (clip.recording, edit.startFrame + clip.startFrame, edit.endFrame)
            }
        }
        guard !clips.isEmpty else { return nil }
        guard let sourceDirectory else { throw ShotsMediaError("Open the project folder to export its scratch audio.") }
        let composition = AVMutableComposition()
        var audioTracks: [AVMutableCompositionTrack] = []
        for (recording, start, end) in clips {
            guard recording.isValid else { throw ShotsMediaError("A scratch recording reference is invalid.") }
            let asset = AVURLAsset(url: sourceDirectory.appendingPathComponent(recording.fileName))
            guard let source = try await asset.loadTracks(withMediaType: .audio).first,
                  let track = composition.addMutableTrack(
                      withMediaType: .audio,
                      preferredTrackID: kCMPersistentTrackID_Invalid
                  )
            else { throw ShotsMediaError("Scratch recording \(recording.fileName) has no audio track.") }
            audioTracks.append(track)
            let range = try await source.load(.timeRange)
            let length = CMTime(value: CMTimeValue(end - start), timescale: CMTimeScale(FrameGrid.fps))
            try track.insertTimeRange(
                CMTimeRange(start: range.start, duration: min(range.duration, length)),
                of: source, at: CMTime(value: CMTimeValue(start), timescale: CMTimeScale(FrameGrid.fps))
            )
        }
        return (composition, audioTracks)
    }

    static func attach(
        shots: [(shot: Shot, startFrame: Int, endFrame: Int)],
        sourceDirectory: URL?, to videoURL: URL, output: URL
    ) async throws -> Bool {
        guard let (composition, audioTracks) = try await composition(shots: shots, sourceDirectory: sourceDirectory)
        else {
            return false
        }
        let video = AVURLAsset(url: videoURL)
        guard let source = try await video.loadTracks(withMediaType: .video).first,
              let track = composition.addMutableTrack(
                  withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
              ) else { throw ShotsMediaError("The animatic video could not be read.") }
        try await track.insertTimeRange(source.load(.timeRange), of: source, at: .zero)
        try await export(
            composition,
            audioTracks: audioTracks,
            preset: AVAssetExportPresetHighestQuality,
            to: output,
            as: .mp4
        )
        return true
    }

    private static func export(
        _ composition: AVComposition, audioTracks: [AVMutableCompositionTrack], preset: String, to url: URL,
        as type: AVFileType
    ) async throws {
        guard let session = AVAssetExportSession(asset: composition, presetName: preset) else {
            throw ShotsMediaError("Shots couldn't prepare the scratch audio export.")
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = audioTracks.map {
            let parameters = AVMutableAudioMixInputParameters(track: $0)
            parameters.setVolume(1, at: .zero)
            return parameters
        }
        session.audioMix = mix
        try await session.export(to: url, as: type)
    }
}
