import AVFoundation
import ConceptCore
@testable import ConceptStudio
import Foundation
import ImageIO
import Testing

@Suite("ChatGPT native clip sheets")
struct ChatGPTClipSheetTests {
    @Test(arguments: [(4.0, 9), (12.0, 9), (24.0, 9), (24.01, 16), (48.0, 16)])
    func defaultSamplingFollowsClipLength(duration: Double, count: Int) {
        #expect(ChatGPTClipSheet.defaultFrameCount(duration: duration) == count)
    }

    @Test(arguments: [9, 16])
    func sheetsPreserveChronologyAndOriginalClip(count: Int) async throws {
        let directory = temporaryTestDirectory("clip-sheet")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let clip = directory.appendingPathComponent("source.mp4")
        try await MediaFixtures.video(at: clip, width: 96, height: 64)
        let bytes = try Data(contentsOf: clip)
        let sheet = try await ChatGPTClipSheet.prepare(
            data: bytes, mediaType: "video/mp4", frameCount: count, temporaryDirectory: directory
        )
        let expected = try await MediaEditor.frames(url: clip, count: count).map(\.seconds)
        #expect(sheet.frameTimes == expected)
        #expect(sheet.frameTimes == sheet.frameTimes.sorted())
        #expect(sheet.frameTimes.first == 0)
        #expect(try #require(sheet.frameTimes.last) < sheet.duration)
        #expect(!sheet.hasAudio)
        let image = try decoded(sheet.jpeg)
        let side = (count == 9 ? 3 : 4) * 768
        #expect(image.width == side && image.height == side)
        let first = try pixel(image, x: 384, y: 400)
        let last = try pixel(image, x: side - 384, y: side - 368)
        #expect(first[0] > 180 && first[2] < 80)
        #expect(last[2] > 180 && last[0] < 80)
        guard case let .text(evidence) = sheet.content.first else { Issue.record("Missing evidence text"); return }
        #expect(evidence.contains("ONE video training target"))
        #expect(evidence.contains("\(count):"))
        #expect(evidence.contains("no audio track (confirmed from the file)"))
        #expect(sheet.content.last == .image(data: sheet.jpeg, mediaType: "image/jpeg"))
        #expect(try Data(contentsOf: clip) == bytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["source.mp4"])
    }

    @Test func rotatedVideoWithAudioKeepsOrientationAndDoesNotClaimToHear() async throws {
        let directory = temporaryTestDirectory("clip-audio")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let clip = try await audiovisualPortrait(in: directory)
        let sheet = try await ChatGPTClipSheet.prepare(data: Data(contentsOf: clip), mediaType: "video/quicktime")
        #expect(sheet.hasAudio)
        let image = try decoded(sheet.jpeg)
        // A rotated 2:1 source fits as a portrait: the left part of its tile remains a dark gutter.
        let margin = try pixel(image, x: 100, y: 400)
        #expect(margin.allSatisfy { (20 ... 60).contains($0) })
        guard case let .text(evidence) = sheet.content.first else { Issue.record("Missing evidence text"); return }
        #expect(evidence.contains("audio track, but it was not transmitted or inspected"))
        #expect(!evidence.contains("confirmed from the file"))
        #expect(!evidence.contains("Both H3 audio fields can be N/A"))
    }

    @Test func repeatedDecodedFramesKeepTheirActualTimes() async throws {
        let directory = temporaryTestDirectory("short-clip")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let clip = directory.appendingPathComponent("source.mp4")
        try await MediaFixtures.video(at: clip, times: [0, 0.04])
        let sheet = try await ChatGPTClipSheet.prepare(
            data: Data(contentsOf: clip), mediaType: "video/mp4", frameCount: 16, temporaryDirectory: directory
        )
        #expect(sheet.frameTimes.count == 16)
        #expect(Set(sheet.frameTimes).count < 16)
        #expect(sheet.frameTimes == sheet.frameTimes.sorted())
    }

    @Test func unreadableAndCancelledClipsLeaveNoStagedFiles() async throws {
        let directory = temporaryTestDirectory("clip-cleanup")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        await #expect(throws: (any Error).self) {
            try await ChatGPTClipSheet.prepare(
                data: Data([1, 2, 3]), mediaType: "video/mp4", temporaryDirectory: directory
            )
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ChatGPTClipSheet.prepare(
                data: Data([1, 2, 3]), mediaType: "video/mp4", temporaryDirectory: directory
            )
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    private func decoded(_ data: Data) throws -> CGImage {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> [Int] {
        let crop = try #require(image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)))
        let context = try #require(CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        return (0 ..< 3).map { Int(bytes[$0]) }
    }

    private func audiovisualPortrait(in directory: URL) async throws -> URL {
        let video = directory.appendingPathComponent("pixels.mp4")
        try await MediaFixtures.video(at: video, width: 128, height: 64)
        let audio = directory.appendingPathComponent("tone.wav")
        try writeTone(to: audio)
        let videoAsset = AVURLAsset(url: video), audioAsset = AVURLAsset(url: audio)
        let videoTrack = try #require(try await videoAsset.loadTracks(withMediaType: .video).first)
        let audioTrack = try #require(try await audioAsset.loadTracks(withMediaType: .audio).first)
        let duration = try await videoTrack.load(.timeRange).duration
        let composition = AVMutableComposition()
        let picture = try #require(composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ))
        let sound = try #require(composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ))
        try picture.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: videoTrack, at: .zero)
        picture.preferredTransform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 64, ty: 0)
        try sound.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: audioTrack, at: .zero)
        let output = directory.appendingPathComponent("portrait.mov")
        let export = try #require(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
        try await export.export(to: output, as: .mov)
        return output
    }

    private func writeTone(to audio: URL) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96000))
        buffer.frameLength = buffer.frameCapacity
        let channel = try #require(buffer.floatChannelData?.pointee)
        for index in 0 ..< Int(buffer.frameLength) {
            channel[index] = Float(sin(Double(index) * 2 * .pi * 440 / 48000) * 0.05)
        }
        let file = try AVAudioFile(forWriting: audio, settings: format.settings)
        try file.write(from: buffer)
    }
}
