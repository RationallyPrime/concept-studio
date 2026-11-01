import Foundation
import PrevisCore
@testable import ShotsMedia
import Testing

/// CONTRACTS section 10, Lane B's budgets (release build, Apple silicon): `ShotFrameRenderer.image` under 40 ms at
/// 640 × 1152, and a standard export of 124 frames with 2 actors under 30 s. Runs only with `SHOTS_TIMING=1`; CI
/// never sets it, and a number from a debug build is not the budget. Lane B records the Mac measurement:
/// `SHOTS_TIMING=1 swift test -c release --filter Timing` in `app/`.
@Suite("Timing", .enabled(if: renderingEnabled && ProcessInfo.processInfo.environment["SHOTS_TIMING"] == "1"))
@MainActor
struct TimingTests {
    /// The full two-person walk: 124 frames at 640 × 1152, two actors.
    private func fullSample() throws -> (scene: PrevisScene, shot: Shot) {
        let scene = try #require(ShotsSamples.twoPersonWalk().scenes.first)
        let shot = try #require(scene.shots.first)
        #expect(shot.frameCount == 124 && shot.canvas.pixelSize == PixelSize(width: 640, height: 1152))
        return (scene, shot)
    }

    private func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    @Test func aFrameImageUnderFortyMilliseconds() async throws {
        let (scene, shot) = try fullSample()
        let evaluator = try ShotEvaluator(scene: scene, shotID: shot.id, catalog: ContentCatalog.bundled())
        let renderer = try ShotFrameRenderer(), look = PrevisLook(scene: scene), clock = ContinuousClock()
        _ = try await renderer.image(of: evaluator.frame(0), look: look) // warm up
        var times: [Double] = []
        for index in stride(from: 0, to: evaluator.frameCount, by: 6) {
            let frame = evaluator.frame(index)
            let start = clock.now
            let image = try await renderer.image(of: frame, look: look)
            times.append(milliseconds(clock.now - start))
            #expect(image.width == 640 && image.height == 1152)
        }
        let median = times.sorted()[times.count / 2]
        print("TIMING image median \(median) ms over \(times.count) frames (budget 40), max \(times.max() ?? 0) ms")
        #expect(median < 40, "ShotFrameRenderer.image median \(median) ms")
    }

    @Test func aStandardExportOfTheFullSampleUnderThirtySeconds() async throws {
        let (scene, shot) = try fullSample()
        let parent = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: parent) }
        let exporter = try ShotExporter(catalog: ContentCatalog.bundled()), clock = ContinuousClock()
        var steps: [(step: String, at: ContinuousClock.Instant)] = []
        let start = clock.now
        let exported = try await exporter.export(
            scene: scene, shotID: shot.id, options: .standard, to: FolderDestination(parent: parent)
        ) { progress in
            if steps.last?.step != progress.step { steps.append((progress.step, clock.now)) }
        }
        let end = clock.now, seconds = milliseconds(end - start) / 1000
        #expect(exported.manifest.files.count { $0.role == .matte && $0.path.hasSuffix(".mp4") } == 2)
        let spans = zip(steps, steps.dropFirst().map(\.at) + [end])
            .map { "\($0.step) \(milliseconds($1 - $0.at) / 1000) s" }
        print("TIMING export \(seconds) s for 124 frames, 2 actors (budget 30): \(spans.joined(separator: "; "))")
        #expect(seconds < 30, "standard export \(seconds) s")
    }
}
