import AVFoundation
import PrevisCore
@testable import ShotsMedia
import Testing

@MainActor
struct DialogueTests {
    @Test(.enabled(if: ShotFrameRenderer.isAvailable && ProcessInfo.processInfo
            .environment["SHOTS_SKIP_RENDER"] == nil))
    func timedDialogueSurvivesThePromptAndBothExports() async throws {
        let catalog = try ContentCatalog.bundled()
        var scene = try #require(ShotsSamples.twoPersonWalk(small: true).scenes.first)
        var shot = try #require(scene.shots.first)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dialogue-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = "  Wait—don’t move.  "
        let second = "Understood.\nI’ll stay."
        shot.dialogue = try await [
            DialogueLine(
                id: "second",
                startFrame: 6,
                text: second,
                recording: tone("000000000002", in: directory)
            ),
            DialogueLine(
                id: "first", speakerID: scene.entities.first?.id,
                startFrame: 1, text: first, recording: tone("000000000001", in: directory)
            ),
        ]
        shot.editFrameCount = 12
        shot.notes.music = ""
        scene.shots = [shot]
        let package = try await ShotExporter(catalog: catalog).export(
            scene: scene, shotID: shot.id, options: .init(passes: [.layout]),
            to: FolderDestination(parent: directory), audioDirectory: directory, progress: { _ in }
        )
        let prompt = try String(contentsOf: package.url.appendingPathComponent("prompt.txt"), encoding: .utf8)
        let before = try #require(prompt.range(of: "“\(first)”"))
        let after = try #require(prompt.range(of: "“\(second)”"))
        #expect(before.lowerBound < after.lowerBound)
        #expect(prompt.contains("non_diegetic_music: N/A"))
        #expect(package.manifest.files.contains { $0.role == .scratchAudio && $0.path == "audio/scratch.m4a" })
        try await expectClipTiming(package.url.appendingPathComponent("audio/scratch.m4a"))

        let animatic = try await AnimaticExporter(catalog: catalog).export(
            scene: scene, burnIn: false, to: directory, audioDirectory: directory, progress: { _ in }
        )
        let video = animatic.appendingPathComponent("animatic.mp4")
        let facts = try await VideoInspector.facts(video)
        #expect(facts.presentationTimes == (0 ..< 12).map { CMTime(value: Int64($0), timescale: 24) })
        let asset = AVURLAsset(url: video)
        let audio = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let range = try await audio.load(.timeRange)
        #expect(range.end.seconds > 0.3, "Audio range: \(range.start.seconds)–\(range.end.seconds)")
        try await expectClipTiming(video)
    }

    private func tone(_ id: String, in directory: URL) async throws -> ScratchRecording {
        let name = "scratch_\(id).wav"
        let url = directory.appendingPathComponent(name)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4000))
        let samples = try #require(buffer.floatChannelData?[0])
        buffer.frameLength = 4000
        for index in 0 ..< 4000 {
            samples[index] = 0.5 * sin(Float(index) * 0.12)
        }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        let waveform = try await ScratchAudio.waveform(at: url)
        #expect(waveform.peaks.max() ?? 0 > 0.45)
        return ScratchRecording(fileName: name, duration: waveform.duration, peaks: waveform.peaks)
    }

    private func expectClipTiming(_ url: URL) async throws {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 2048))
        let rate = file.processingFormat.sampleRate
        for (time, audible) in [(0.01, false), (0.07, true), (0.16, false), (0.28, true), (0.31, true)] {
            file.framePosition = AVAudioFramePosition(time * rate)
            try file.read(into: buffer, frameCount: 512)
            let samples = try #require(buffer.floatChannelData?[0])
            let peak = UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength)).map { abs($0) }.max() ?? 0
            #expect(audible ? peak > 0.2 : peak < 0.03, "Unexpected level \(peak) at \(time)")
        }
    }
}
