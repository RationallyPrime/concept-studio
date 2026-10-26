import Foundation
@testable import PrevisCore
import Testing

/// PR 67 round-1 findings r4377817829, r4377817859, r4377817868 and r4377817875, each reproduced before its repair.
struct A4ReviewTests {
    private let catalog: ContentCatalog
    private let scene: PrevisScene
    private let shotID: ShotID
    private let man: PrevisEntity
    private let woman: PrevisEntity
    private let chair: PrevisEntity

    init() throws {
        catalog = try ContentCatalog.bundled()
        scene = try #require(ShotsSamples.twoPersonWalk().scenes.first)
        shotID = try #require(scene.shots.first).id
        man = try #require(scene.entities.first { $0.name == "Man" })
        woman = try #require(scene.entities.first { $0.name == "Woman" })
        chair = try #require(scene.entities.first { $0.name == "Chair" })
    }

    private func evaluator(_ scene: PrevisScene) throws -> ShotEvaluator {
        try ShotEvaluator(scene: scene, shotID: shotID, catalog: catalog)
    }

    private func entity(_ id: EntityID, in frame: SceneFrame) throws -> EntityFrame {
        try #require(frame.entities.first { $0.id == id })
    }

    /// The scene with only `man` on a take of `marks`, nobody else moving.
    private func staged(_ marks: [ActorMark]) -> PrevisScene {
        var staged = scene
        staged.blocking[0].tracks = [Track(entityID: man.id, marks: marks)]
        return staged
    }

    // MARK: r4377817829: a generated motion keeps the sampled heading

    @Test func aMotionKeepsTheFacingTheActorHasWhereItStartsAndEnds() throws {
        func stand(_ id: String, _ time: Double) -> ActorMark {
            ActorMark(
                id: id, time: time, hold: 0, easeIn: 0, easeOut: 0,
                position: Vec3(0, 0, 0), gait: .stand, arriveHeading: 1.2
            )
        }
        // The man stands still and faces 1.2 rad by his authored marks; his placement faces -π/2.
        let track = Track(entityID: man.id, marks: [stand("a", 0), stand("b", 1)])
        let result = try Motions.apply("nod-yes", to: man, track: track, at: 1.5, catalog: catalog)
        let generated = result.marks.filter { $0.time >= 1.5 - 1e-9 }
        #expect(!generated.isEmpty && generated.allSatisfy { $0.arriveHeading == 1.2 })

        // Once the motion has finished he stays facing 1.2; before the repair he snapped back to his placement.
        let evaluator = try evaluator(staged(result.marks))
        let end = try #require(generated.last).time
        let after = try entity(man.id, in: evaluator.frame(at: end + 0.5)).heading
        #expect(abs(after - 1.2) < 1e-9, "facing after the motion: \(after)")
    }

    /// While a motion plays in place the actor keeps his facing. The evaluator used to read a stationary leg's facing
    /// from the placement; A5's authored-turn rule holds it (PR 67 r4377817829).
    @Test func whileAMotionPlaysTheFacingHolds() throws {
        func stand(_ id: String, _ time: Double) -> ActorMark {
            ActorMark(
                id: id, time: time, hold: 0, easeIn: 0, easeOut: 0,
                position: Vec3(0, 0, 0), gait: .stand, arriveHeading: 1.2
            )
        }
        let track = Track(entityID: man.id, marks: [stand("a", 0), stand("b", 1)])
        let result = try Motions.apply("nod-yes", to: man, track: track, at: 1.5, catalog: catalog)
        let evaluator = try evaluator(staged(result.marks))
        let during = try entity(man.id, in: evaluator.frame(at: 1.9)).heading
        #expect(abs(during - 1.2) < 1e-9, "facing during the motion: \(during)")
    }

    // MARK: r4377817859: negative vertical root displacement is kept

    @Test func aSquatLowersTheBodyBecauseItsNegativeRootMoveIsKept() throws {
        let squat = try #require(catalog.motion("squat-exercise"))
        let lowest = try #require(squat.keyframes.min { ($0.move?.up ?? 0) < ($1.move?.up ?? 0) })
        let drop = try #require(lowest.move?.up)
        #expect(drop < -0.3)

        let track = try Motions.apply("squat-exercise", to: man, track: nil, at: 0, catalog: catalog)
        let mark = try #require(track.marks.first { abs($0.time - lowest.t) < 1e-9 })
        #expect(abs(mark.position.y - drop) < 1e-12, "root mark y \(mark.position.y), wanted \(drop)")

        let body = try entity(man.id, in: evaluator(staged(track.marks)).frame(at: lowest.t))
        #expect(body.position.y < drop + 1e-9)
        // the knees and hips bend, so the lowered body rests on the ground instead of floating above it
        #expect(body.bounds.min.y < 0.1, "feet are \(body.bounds.min.y) m above the ground")
    }

    // MARK: r4377817868: a two-shot fits the subjects' combined vertical extent

    @Test func aTwoShotFitsSubjectsStandingAtDifferentElevations() throws {
        var raised = scene
        raised.blocking[0].tracks = []
        raised.shots[0].canvas = .portrait
        let low = try #require(raised.entities.firstIndex { $0.id == man.id })
        let high = try #require(raised.entities.firstIndex { $0.id == woman.id })
        raised.entities[low].placement.position = Vec3(-0.6, 0, 0)
        raised.entities[high].placement.position = Vec3(0.6, 10, 0)

        let mark = try Framing.cameraMark(
            .twoShot, scene: raised, shotID: shotID, subjects: [man.id, woman.id], atFrame: 0, catalog: catalog
        )
        raised.shots[0].camera.marks = [mark]
        let frame = try evaluator(raised).frame(0)
        let size = frame.canvas.pixelSize
        for (id, base) in [(man.id, 0.0), (woman.id, 10.0)] {
            for height in [0.1, 1.6] {
                let point = try Vec3(entity(id, in: frame).position.x, base + height, 0)
                let pixel = try #require(frame.camera.project(point, size: size), "\(id) behind the camera")
                #expect(
                    (0 ..< Double(size.width)).contains(pixel.x) && (0 ..< Double(size.height)).contains(pixel.y),
                    "\(id) at height \(height) projects to \(pixel)"
                )
            }
        }
    }

    // MARK: r4377817875: framing marks on a mounted camera are mount-local

    /// The shot with its camera mounted on the chair, which faces 0.8 rad, and a mark at (0, 1.6, 6) relative to it.
    private func mounted() -> PrevisScene {
        var mounted = scene
        let index = mounted.entities.firstIndex { $0.id == chair.id }!
        mounted.entities[index].placement.heading = 0.8
        mounted.shots[0].camera.rig = .carMount
        mounted.shots[0].camera.rigIntensity = 0
        mounted.shots[0].camera.mountID = chair.id
        return mounted
    }

    @Test func dutchOnAMountedCameraChangesOnlyTheRoll() throws {
        let mounted = mounted()
        let before = try evaluator(mounted).frame(0).camera
        let mark = try Framing.cameraMark(
            .dutch, scene: mounted, shotID: shotID, subjects: [man.id], atFrame: 0, catalog: catalog
        )
        var after = mounted
        after.shots[0].camera.marks = [mark]
        let camera = try evaluator(after).frame(0).camera
        #expect(
            (camera.position - before.position).length < 1e-9,
            "moved to \(camera.position) from \(before.position)"
        )
        #expect(abs(camera.pan - before.pan) < 1e-9 && abs(camera.tilt - before.tilt) < 1e-9)
        #expect(abs(camera.roll - 0.35) < 1e-12)
    }

    @Test func aFramingMarkOnAMountedCameraLandsWhereTheSameFramingLandsUnmounted() throws {
        let mounted = mounted()
        let live = try evaluator(mounted).frame(0).camera
        // the same camera, in world space, on an unmounted shot
        var plain = scene
        plain.shots[0].camera.marks = [
            CameraMark(
                id: "w", time: 0, hold: 0, easeIn: 0, easeOut: 0, position: live.position,
                pan: live.pan, tilt: live.tilt, roll: live.roll, focalLength: live.focalLength
            ),
        ]
        for kind in [Framing.Kind.low, .wide, .reverse] {
            let expected = try Framing.cameraMark(
                kind, scene: plain, shotID: shotID, subjects: [man.id], atFrame: 0, catalog: catalog
            )
            let mark = try Framing.cameraMark(
                kind, scene: mounted, shotID: shotID, subjects: [man.id], atFrame: 0, catalog: catalog
            )
            var installed = mounted
            installed.shots[0].camera.marks = [mark]
            let camera = try evaluator(installed).frame(0).camera
            #expect(
                (camera.position - expected.position).length < 1e-9,
                "\(kind): \(camera.position) vs \(expected.position)"
            )
            #expect(abs(camera.pan - expected.pan) < 1e-9 && abs(camera.tilt - expected.tilt) < 1e-9, "\(kind) aim")
        }
    }

    @Test func cameraMovesOnAMountedCameraAlsoLandWhereTheyLandUnmounted() throws {
        let mounted = mounted()
        let live = try evaluator(mounted).frame(0).camera
        var plain = scene
        plain.shots[0].camera.marks = [
            CameraMark(
                id: "w", time: 0, hold: 0, easeIn: 0, easeOut: 0, position: live.position,
                pan: live.pan, tilt: live.tilt, roll: live.roll, focalLength: live.focalLength
            ),
        ]
        let expected = try CameraMoves.marks(
            "slow-push-in",
            scene: plain,
            shotID: shotID,
            subjects: [man.id],
            catalog: catalog
        )
        let result = try CameraMoves.marks(
            "slow-push-in",
            scene: mounted,
            shotID: shotID,
            subjects: [man.id],
            catalog: catalog
        )
        var installed = mounted
        installed.shots[0].camera.marks = result.marks
        let evaluator = try evaluator(installed)
        for mark in expected.marks {
            let camera = evaluator.frame(at: mark.time).camera
            #expect(
                (camera.position - mark.position).length < 1e-6,
                "t=\(mark.time): \(camera.position) vs \(mark.position)"
            )
        }
    }
}
