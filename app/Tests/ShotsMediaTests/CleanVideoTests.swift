import AVFoundation
import Foundation
import PrevisCore
@testable import ShotsMedia
import Testing

@Suite("clean reference video", .enabled(if: renderingEnabled))
@MainActor
struct CleanVideoTests {
    /// Every render and export test uses the small sample (CONTRACTS section 9); the full sample is checked by the
    /// app's `--shots-self-test`, which runs this same report over the full-size video.
    @Test func theSmallSampleEncodesFrameExact() async throws {
        let scene = try #require(ShotsSamples.twoPersonWalk(small: true).scenes.first)
        let shot = try #require(scene.shots.first)
        let evaluator = try ShotEvaluator(scene: scene, shotID: shot.id, catalog: ContentCatalog.bundled())
        let folder = try Self.scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("clean.mp4")
        let renderer = try ShotFrameRenderer()
        let look = PrevisLook(scene: scene)
        try await renderer.writeCleanVideo(of: evaluator, look: look, to: url)

        let report = try await ShotsSelfTest.report(on: url, frameCount: 22, size: shot.canvas.pixelSize)
        #expect(report.ok, "\(report.problems)")
        #expect(report.frames == 22)
        #expect(report.width == 320 && report.height == 576)
        #expect(report.presentationTimes?.map(\.time) == ["0/24", "11/24", "21/24"])
        #expect(report.codec == "avc1")
        #expect(report.bt709 == true)

        // The middle frame decodes to what the renderer draws, give or take compression.
        let decoded = try await Pixels(Self.decodedFrame(url, at: 11))
        let rendered = try await Pixels(renderer.image(of: evaluator.frame(11), look: look))
        #expect(decoded.meanDifference(from: rendered) < 6)
    }

    private static func scratchFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("shots-media-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Frame `index` of `url`, decoded to BGRA with no colour management: a plain YCbCr-to-RGB conversion.
    private static func decodedFrame(_ url: URL, at index: Int) async throws -> CGImage {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try #require(tracks.first)
        let time = CMTime(value: CMTimeValue(index), timescale: 24)
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: time, duration: CMTime(value: 1, timescale: 24))
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        reader.add(output)
        try #require(reader.startReading())
        while let sample = output.copyNextSampleBuffer() {
            if CMSampleBufferGetPresentationTimeStamp(sample) == time,
               let buffer = CMSampleBufferGetImageBuffer(sample) {
                return try ShotFrameRenderer.image(from: buffer)
            }
        }
        throw ShotsMediaError("Frame \(index) of \(url.lastPathComponent) didn't decode.")
    }
}

extension Pixels {
    /// Mean absolute difference per colour channel, in 0–255 levels.
    func meanDifference(from other: Pixels) -> Double {
        var total = 0
        for y in 0 ..< height {
            for x in 0 ..< width {
                let (r, g, b) = rgb(x, y), (r2, g2, b2) = other.rgb(x, y)
                total += abs(r - r2) + abs(g - g2) + abs(b - b2)
            }
        }
        return Double(total) / Double(width * height * 3)
    }
}
