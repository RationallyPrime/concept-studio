import Foundation
@testable import PrevisCore
import Testing

/// CONTRACTS section 10: `ShotEvaluator.init` under 5 ms and `frame` under 2 ms with 10 entities (release build,
/// Apple silicon). Runs only with `SHOTS_TIMING=1`; CI does not run it, and a number from another machine or a
/// debug build is not the budget. Lane B records the Mac measurement:
/// `SHOTS_TIMING=1 swift test -c release --package-path PrevisCore --filter Timing`.
@Suite("Timing")
struct TimingTests {
    private static let enabled = ProcessInfo.processInfo.environment["SHOTS_TIMING"] == "1"

    /// The two-person walk grown to exactly ten entities, the added people walking a track of their own.
    private func tenEntityScene() throws -> PrevisScene {
        var scene = try #require(ShotsSamples.twoPersonWalk().scenes.first)
        let people = scene.entities
        let tracks = scene.blocking[0].tracks
        for index in 0 ..< (10 - people.count) {
            var entity = people[index % people.count]
            entity.id = "extra_\(index)"
            entity.name = "Extra \(index)"
            entity.placement.position.x += Double(index + 1) * 0.7
            scene.entities.append(entity)
            if var track = tracks.first(where: { $0.entityID == people[index % people.count].id }) {
                track.entityID = entity.id
                track.marks = track.marks.map { mark in
                    var copy = mark
                    copy.id = "\(entity.id)_\(mark.id)"
                    copy.position.x += Double(index + 1) * 0.7
                    return copy
                }
                scene.blocking[0].tracks.append(track)
            }
        }
        #expect(scene.entities.count == 10)
        return scene
    }

    private func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    @Test(.enabled(if: enabled)) func initUnderFiveMillisecondsAndFrameUnderTwoWithTenEntities() throws {
        let scene = try tenEntityScene()
        let catalog = try ContentCatalog.bundled()
        let shotID = try #require(scene.shots.first).id
        let clock = ContinuousClock()

        _ = try ShotEvaluator(scene: scene, shotID: shotID, catalog: catalog) // warm up
        var inits: [Double] = []
        for _ in 0 ..< 21 {
            let elapsed = try clock.measure { _ = try ShotEvaluator(scene: scene, shotID: shotID, catalog: catalog) }
            inits.append(milliseconds(elapsed))
        }
        let initMedian = inits.sorted()[inits.count / 2]

        let evaluator = try ShotEvaluator(scene: scene, shotID: shotID, catalog: catalog)
        var sink = 0
        let passes = 3
        let total = clock.measure {
            for _ in 0 ..< passes {
                for index in 0 ..< evaluator.frameCount {
                    sink &+= evaluator.frame(index).entities.count
                }
            }
        }
        let framesEvaluated = passes * evaluator.frameCount
        let perFrame = milliseconds(total) / Double(framesEvaluated)
        print(
            "TIMING init median \(initMedian) ms (budget 5), "
                + "frame mean \(perFrame) ms over \(framesEvaluated) (budget 2), sink \(sink)"
        )
        #expect(initMedian < 5, "ShotEvaluator.init median \(initMedian) ms")
        #expect(perFrame < 2, "frame mean \(perFrame) ms")
    }
}
