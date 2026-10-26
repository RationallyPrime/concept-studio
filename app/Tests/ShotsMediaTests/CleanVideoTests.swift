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
        let folder = try scratchFolder()
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

/// The writer's failure and cancellation paths, with blank frames: no rendering, so these run everywhere.
@Suite("video writer")
@MainActor
struct VideoWriterTests {
    @Test(.timeLimit(.minutes(1))) func appendingToAStoppedWriterFailsInsteadOfWaiting() async throws {
        let folder = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let writer = try VideoWriter(
            url: folder.appendingPathComponent("stopped.mp4"), size: PixelSize(width: 64, height: 64), frameCount: 3
        )
        let buffers = try (0 ..< 2).map { _ in try writer.makeBuffer() }
        try await writer.append(buffers[0], frame: 0)
        // A stopped writer never becomes ready for more media again.
        writer.cancel()
        await #expect(throws: ShotsMediaError.self) { try await writer.append(buffers[1], frame: 1) }
    }

    @Test func cancellingWhileTheVideoFinishesRemovesIt() async throws {
        let folder = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("cancelled.mp4")
        let box = TaskBox()
        box.task = Task {
            try await VideoWriter.write(
                to: url, size: PixelSize(width: 64, height: 64), frameCount: 3,
                // Queued after the last frame, the cancel runs while the writer awaits finalization.
                progress: { index in if index == 2 { Task { box.task?.cancel() } } },
                draw: { _, _ in }
            )
        }
        let task = try #require(box.task)
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: url.path), "the cancelled video was left behind")
    }
}

@MainActor private final class TaskBox {
    var task: Task<Void, any Error>?
}

func scratchFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("shots-media-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
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
