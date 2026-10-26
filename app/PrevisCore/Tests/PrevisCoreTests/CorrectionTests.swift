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

    /// The plan maintainer's rule (PR 67 comment 6424533971): an authored turn finishes on arrival, blending over the
    /// leg
    /// that arrives at the mark from the facing at departure, with that leg's easing. The mark's own hold then keeps
    /// the
    /// facing it arrived with, as Blockout does. Legs into marks without an authored facing keep facing along travel.
    ///
    /// One spot, placement heading 0, every ease 0 so progress is linear. P: t = 1 s, hold 2, facing 0. M: t = 5 s,
    /// hold 3,
    /// facing π/2. N: t = 10 s, hold 0, facing 0. P→M departs at 3 and arrives at 5; M→N departs at 8 and arrives at
    /// 10.
    ///
    ///     t (s)                      2   3   4       5       6.5     8       9       10
    ///     intended (implemented)     0   0   0.7854  1.5708  1.5708  1.5708  0.7854  0
    ///     turn after arrival         0   0   0       0       0.7854  1.5708  0.7854  0     not accepted
    ///     turn in previous hold      0.7854 1.5708 1.5708 1.5708 0.7854 0   0   0      not accepted
    ///     Blockout (legacy)          0   0   0       0       1.5708  0       0       0     snaps just after arrival
    @Test func theMaintainersTableForTheTurnIntoAMarkHoldsEverywhere() throws {
        func stand(_ id: String, _ time: Double, hold: Double, _ heading: Double) -> ActorMark {
            ActorMark(
                id: id, time: time, hold: hold, easeIn: 0, easeOut: 0,
                position: .zero, gait: .stand, arriveHeading: heading
            )
        }
        let marks = [
            stand("p", 1, hold: 2, 0), stand("m", 5, hold: 3, .pi / 2), stand("n", 10, hold: 0, 0),
        ]
        var scene = staged(marks, heading: 0)
        scene.shots[0].frameCount = 244 // 10.125 s, so the table's times up to 10 s are inside the shot
        let corrected = try evaluator(scene, .all), legacy = try evaluator(scene, [])
        func heading(_ evaluator: ShotEvaluator, _ t: Double) throws -> Double {
            try #require(evaluator.frame(at: t).entities.first { $0.id == man.id }).heading
        }
        let intended: [(Double, Double)] = [
            (2, 0), (3, 0), (4, .pi / 4), (5, .pi / 2), (6.5, .pi / 2), (8, .pi / 2), (9, .pi / 4), (10, 0),
        ]
        for (t, expected) in intended {
            let got = try heading(corrected, t)
            #expect(abs(turn(got, expected)) < 1e-9, "t = \(t): \(got) vs \(expected)")
        }
        // Blockout's column: it shows the arrived facing only while standing at the mark (6.5 s) and falls back to the
        // placement on every leg, snapping just after arrival. So the default evaluator matches it in every hold and
        // differs only on the legs that arrive at an authored facing.
        let blockout: [(Double, Double)] = [(2, 0), (3, 0), (4, 0), (5, 0), (6.5, .pi / 2), (8, 0), (9, 0), (10, 0)]
        for (t, expected) in blockout {
            let got = try heading(legacy, t)
            #expect(abs(turn(got, expected)) < 1e-9, "Blockout at t = \(t): \(got) vs \(expected)")
        }
        for t in [2.0, 6.5] {
            #expect(
                try abs(turn(heading(corrected, t), heading(legacy, t))) < 1e-9,
                "a hold at t = \(t) matches Blockout"
            )
        }
    }

    @Test func aTravellingLegIntoAnAuthoredFacingTurnsFromTheDepartureFacingNotTheTravelDirection() throws {
        // A defender is pushed back along +x while keeping the facing it had; the arriving mark authors the same
        // facing.
        let marks = [
            mark("a", 0, Vec3(0, 0, 0), heading: .pi), mark("b", 4, Vec3(6, 0, 0), heading: .pi),
        ]
        let evaluator = try evaluator(staged(marks), .all)
        for t in [0.5, 1.5, 2.5, 3.5] {
            let got = try #require(evaluator.frame(at: t).entities.first { $0.id == man.id }).heading
            #expect(abs(turn(got, .pi)) < 1e-9, "facing the attacker while pushed back at \(t): \(got)")
        }
        // without an authored facing the same leg faces along travel, as in Blockout
        let plain = try self.evaluator(staged([mark("a", 0, Vec3(0, 0, 0)), mark("b", 4, Vec3(6, 0, 0))]), .all)
        let travelling = try #require(plain.frame(at: 2).entities.first { $0.id == man.id }).heading
        #expect(abs(turn(travelling, -.pi / 2)) < 1e-9)
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
