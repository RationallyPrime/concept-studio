import AVFoundation
import PrevisCore
@testable import ShotsMedia
import Testing

@MainActor
struct AnimaticTests {
    @Test(.enabled(if: ShotFrameRenderer.isAvailable && ProcessInfo.processInfo
            .environment["SHOTS_SKIP_RENDER"] == nil))
    func threeShotCutsUseTheirExactFrameBoundaries() async throws {
        let catalog = try ContentCatalog.bundled()
        var scene = try #require(ShotsSamples.twoPersonWalk(small: true).scenes.first)
        let source = try #require(scene.shots.first)
        let lengths = [3, 2, 4]
        scene.shots = lengths.enumerated().map { index, length in
            var shot = source
            shot.id = "shot-\(index)"
            shot.name = "Shot \(index + 1)"
            shot.editFrameCount = length
            shot.camera.marks = Array(shot.camera.marks.prefix(1))
            shot.camera.marks[0].position.x += Double(index) * 3
            if index == 2 { shot.canvas = ShotCanvas(width: 384, height: 256) }
            return shot
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("animatic-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try await AnimaticExporter(catalog: catalog).export(
            scene: scene, burnIn: true, to: directory, progress: { _ in }
        )
        let video = url.appendingPathComponent("animatic.mp4")
        let actual = try await VideoInspector.facts(video)
        let list = try JSONDecoder().decode(
            SceneCutList.self, from: Data(contentsOf: url.appendingPathComponent("cut-list.json"))
        )
        #expect(list.cuts == [
            SceneCut(shotID: "shot-0", startFrame: 0, endFrame: 3),
            SceneCut(shotID: "shot-1", startFrame: 3, endFrame: 5),
            SceneCut(shotID: "shot-2", startFrame: 5, endFrame: 9),
        ])
        #expect(actual.frameCount == 9)
        #expect(actual.presentationTimes == (0 ..< 9).map { CMTime(value: CMTimeValue($0), timescale: 24) })
        #expect(list.cut(at: 3)?.shotID == "shot-1")
        #expect(list.cut(at: 5)?.shotID == "shot-2")
        #expect(list.cut(at: 9) == nil)
        #expect(actual.width == source.canvas.width && actual.height == source.canvas.height)
    }
}
