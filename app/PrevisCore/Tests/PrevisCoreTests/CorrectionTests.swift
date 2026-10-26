import Foundation
@testable import PrevisCore
import Testing

/// A5's corrections to Blockout's evaluator (defects 1, 2 and 6), each shown against Blockout's own behaviour.
struct CorrectionTests {
    private let catalog: ContentCatalog
    private let scene: PrevisScene
    private let shotID: ShotID
    private let man: PrevisEntity

    init() throws {
        catalog = try ContentCatalog.bundled()
        scene = try #require(ShotsSamples.twoPersonWalk().scenes.first)
        shotID = try #require(scene.shots.first).id
        man = try #require(scene.entities.first { $0.name == "Man" })
    }

    private func evaluator(_ scene: PrevisScene, _ corrections: Corrections) throws -> ShotEvaluator {
        try ShotEvaluator(scene: scene, shotID: shotID, catalog: catalog, aspect: nil, corrections: corrections)
    }

    private func staged(_ marks: [ActorMark], heading: Double = 0) -> PrevisScene {
        var staged = scene
        staged.blocking[0].tracks = [Track(entityID: man.id, marks: marks)]
        staged.entities[staged.entities.firstIndex { $0.id == man.id }!].placement.heading = heading
        return staged
    }

    private func mark(
        _ id: String, _ time: Double, _ position: Vec3, hold: Double = 0, heading: Double? = nil
    ) -> ActorMark {
        ActorMark(
            id: id, time: time, hold: hold, easeIn: 0, easeOut: 0,
            position: position, gait: .walk, arriveHeading: heading
        )
    }

    private func headings(_ evaluator: ShotEvaluator, from start: Double, to end: Double, steps: Int = 40) throws
        -> [Double] {
        try (0 ... steps).map { step in
            let t = start + (end - start) * Double(step) / Double(steps)
            return try #require(evaluator.frame(at: t).entities.first { $0.id == man.id }).heading
        }
    }

    /// The signed shortest angle from `a` to `b`.
    private func turn(_ a: Double, _ b: Double) -> Double {
        var d = (b - a).truncatingRemainder(dividingBy: 2 * .pi)
        if d > .pi { d -= 2 * .pi }
        if d < -.pi { d += 2 * .pi }
        return d
    }

    @Test func thePublicInitialiserAppliesTheCorrections() throws {
        let sample = try ShotEvaluator(scene: scene, shotID: shotID, catalog: catalog)
        #expect(sample.corrections == .all)
        let end = try #require(sample.frame(sample.frameCount - 1).entities.first { $0.id == man.id }).heading
        #expect(abs(turn(end, .pi)) < 1e-9, "the default evaluator turns the man to the camera: \(end)")
    }

    // MARK: Authored turns

    @Test func theSamplesFinalTurnToTheCameraNowHappensAndBlockoutNeverShowedIt() throws {
        let sample = try evaluator(scene, .all)
        let before = try #require(sample.frame(at: 3.4).entities.first { $0.id == man.id }).heading
        let end = try #require(sample.frame(sample.frameCount - 1).entities.first { $0.id == man.id }).heading
        #expect(abs(before + .pi / 2) < 0.2, "still walking toward the woman at t = 3.4: \(before)")
        #expect(abs(turn(end, .pi)) < 1e-9, "faces the camera at the last frame: \(end)")

        let blockout = try evaluator(scene, [])
        let snapped = try #require(blockout.frame(blockout.frameCount - 1).entities.first { $0.id == man.id }).heading
        #expect(abs(turn(snapped, .pi)) > 1, "Blockout keeps facing the woman: \(snapped)")
    }

    @Test func aTurnAtAMarkWithNoHoldBlendsMonotonicallyOverTheWholeLeg() throws {
        // The man walks right, then stands and turns to face the camera at a mark 2 s later, with no hold.
        let marks = [
            mark("a", 0, Vec3(0, 0, 0)), mark("b", 2, Vec3(3, 0, 0)), mark("c", 4, Vec3(3, 0, 0), heading: .pi),
        ]
        let evaluator = try evaluator(staged(marks), .all)
        let during = try headings(evaluator, from: 2, to: 4)
        let steps = zip(during, during.dropFirst()).map { turn($0, $1) }
        let direction = steps.first { abs($0) > 1e-9 }
        #expect(direction != nil && steps.allSatisfy { $0 * (direction ?? 1) >= -1e-12 }, "monotonic: \(steps)")
        #expect(steps.allSatisfy { abs($0) < 0.2 }, "no snap: the largest step is \(steps.map(abs).max() ?? 0)")
        #expect(abs(turn(during.first ?? 0, -.pi / 2)) < 0.05 && abs(turn(during.last ?? 0, .pi)) < 1e-9)
    }

    @Test func aTurnAtAMarkWithAHoldBlendsOverThatHold() throws {
        let marks = [
            mark("a", 0, Vec3(0, 0, 0)), mark("b", 2, Vec3(3, 0, 0), hold: 1, heading: .pi),
            mark("c", 5, Vec3(3, 0, 3)),
        ]
        let evaluator = try evaluator(staged(marks), .all)
        // walking: the travel heading, no early turn
        let walking = try headings(evaluator, from: 0.5, to: 1.9)
        #expect(walking.allSatisfy { abs(turn($0, -.pi / 2)) < 1e-6 })
        // arrived, holding: turns monotonically to π by the time it leaves
        let holding = try headings(evaluator, from: 2, to: 3)
        let steps = zip(holding, holding.dropFirst()).map { turn($0, $1) }
        #expect(steps.allSatisfy { $0 * (steps.first ?? 1) >= -1e-12 } && abs(turn(holding.last ?? 0, .pi)) < 1e-6)
        #expect(abs(turn(holding.first ?? 0, -.pi / 2)) < 1e-6, "starts from the arrival heading")
    }

    /// LANE-A-CORE says an authored turn blends "over the hold before its mark". This implementation turns the actor
    /// during
    /// the hold AT the mark, after arriving (reading 1). Pending the plan maintainer's disposition (PR 67 comment
    /// 6418243985) this pins reading 1 with an example whose intervals do not overlap, so monotonic motion alone cannot
    /// stand in for the timing. The man faces +x (placement −π/2); A waits 1 s, then he walks 3 m to B, arriving at t =
    /// 3
    /// with a 1 s hold and an authored facing of π; the next mark C is at t = 6.
    ///
    ///     time        0.5      2.5      3.5      (heading in radians, π ≡ −π)
    ///     reading 1   −π/2     −π/2     −3π/4    turn during B's hold, [3, 4]            (implemented)
    ///     reading 2   −π/2     −3π/4    π        turn during the hold before B, [2, 3]   (not implemented)
    ///     reading 3   −3π/4    −π/2     π        turn during A's hold, [0, 1]            (not implemented)
    @Test func theTurnTimingExampleDiscriminatesTheReadingsOfTheHoldBeforeItsMark() throws {
        let a = ActorMark(
            id: "a", time: 0, hold: 1, easeIn: 0, easeOut: 0, position: .zero, gait: .walk
        )
        let marks = [
            a, mark("b", 3, Vec3(3, 0, 0), hold: 1, heading: .pi),
            mark("c", 6, Vec3(3, 0, 3)),
        ]
        let evaluator = try evaluator(staged(marks, heading: -.pi / 2), .all)
        func heading(_ t: Double) throws -> Double {
            try #require(evaluator.frame(at: t).entities.first { $0.id == man.id }).heading
        }
        #expect(try abs(turn(heading(0.5), -.pi / 2)) < 1e-9, "readings 1 and 2 agree before the walk")
        #expect(try abs(turn(heading(2.5), -.pi / 2)) < 1e-9, "reading 1: still walking toward B at 2.5 s")
        #expect(try abs(turn(heading(3.5), -3 * .pi / 4)) < 1e-9, "reading 1: halfway through B's hold at 3.5 s")
        #expect(try abs(turn(heading(4), .pi)) < 1e-9, "and facing π when the hold ends")
    }

    // MARK: Vertical moves

    @Test func aVerticalRiseKeepsItsHeadingWhereBlockoutFacesMinusZ() throws {
        let marks = [mark("a", 0, Vec3(0, 0, 0)), mark("b", 2, Vec3(0, 3, 0))]
        let staged = staged(marks, heading: 0.7)
        let corrected = try headings(evaluator(staged, .all), from: 0.2, to: 1.8)
        #expect(corrected.allSatisfy { abs($0 - 0.7) < 1e-9 }, "\(corrected)")
        let blockout = try headings(evaluator(staged, []), from: 0.2, to: 1.8)
        #expect(blockout.allSatisfy { abs($0) < 1e-9 }, "Blockout faces -Z while rising: \(blockout)")
    }

    @Test func aRiseAfterAWalkKeepsTheWalksHeading() throws {
        let marks = [mark("a", 0, Vec3(0, 0, 0)), mark("b", 2, Vec3(3, 0, 0)), mark("c", 4, Vec3(3, 2, 0))]
        let rising = try headings(evaluator(staged(marks), .all), from: 2.2, to: 3.8)
        #expect(rising.allSatisfy { abs(turn($0, -.pi / 2)) < 1e-9 }, "\(rising)")
    }

    // MARK: One easing

    @Test func cameraOrientationAndLensUseTheSameEasingAsPosition() throws {
        var eased = scene
        eased.shots[0].camera.marks[0].pan = 0
        eased.shots[0].camera.marks[1].pan = 1
        eased.shots[0].camera.marks[0].easeOut = 0.3
        eased.shots[0].camera.marks[1].easeIn = 0.3
        let duration = eased.shots[0].duration
        let t = duration * 0.25
        let progress = easedProgress(t / duration, easeOut: 0.3, easeIn: 0.3)

        let corrected = try evaluator(eased, .singleEasing).frame(at: t).camera
        let blockout = try evaluator(eased, []).frame(at: t).camera
        #expect(
            abs(corrected.pan - progress) < 1e-12,
            "pan follows the position easing: \(corrected.pan) vs \(progress)"
        )
        #expect(abs(blockout.pan - smoothstep(progress)) < 1e-12)
        #expect(abs(corrected.pan - blockout.pan) > 0.01)
        // the position uses that easing in both
        let position = (1 - progress) * 6 + progress * 4.5
        #expect(abs(corrected.position.z - position) < 1e-9 && abs(blockout.position.z - position) < 1e-9)
    }
}
