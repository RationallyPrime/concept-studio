import Foundation
@testable import PrevisCore
import Testing

/// Blockout's own unit tests, ported. The reference is https://github.com/wassermanproductions/blockout at
/// 3f2d0564fd575f70fc28e9bfaa7e94b05e3955d9: `tests/unit/evaluate.test.ts`, `tracking.test.ts` and `round3.test.ts`
/// (the evaluator, aim lock, attachments, boarding and the 180° rule). They run against the DEFAULT evaluator, so they
/// show where the corrected evaluator still agrees with the behaviour Blockout's authors asserted. A deviation would be
/// a
/// finding, not something to hide.
struct ReferenceFixtureTests {
    private let catalog: ContentCatalog

    init() throws {
        catalog = try ContentCatalog.bundled()
    }

    // MARK: Builders mirroring Blockout's `schema.ts` helpers

    private func scene(duration: Double = 5) -> PrevisScene {
        var scene = PrevisScene.make(id: "s", name: "S", takeID: "t", shotID: "h", cameraMarkID: "c")
        scene.shots[0].frameCount = FrameGrid.snapUp(Int((duration * 24).rounded()) + 1)
        scene.shots[0].camera.marks = []
        scene.shots[0].camera.rigIntensity = 0
        return scene
    }

    private func entity(_ id: String, _ asset: String, _ at: Vec3, heading: Double = 0) -> PrevisEntity {
        PrevisEntity(id: id, assetID: asset, name: id, placement: Placement(position: at, heading: heading, scale: 1))
    }

    /// `createActorMark`: ease 0.25 each way unless stated.
    private func actorMark(
        _ id: String, _ at: Vec3, _ time: Double, gait: Gait = .walk, hold: Double = 0, ease: Double = 0.25,
        boards: EntityID? = nil
    ) -> ActorMark {
        ActorMark(
            id: id, time: time, hold: hold, easeIn: ease, easeOut: ease, position: at, gait: gait, boardID: boards
        )
    }

    /// `createCameraMark`: ease 0.3 each way unless stated.
    private func cameraMark(
        _ id: String, _ at: Vec3, _ time: Double, pan: Double, tilt: Double, focal: Double, ease: Double = 0.3
    ) -> CameraMark {
        CameraMark(
            id: id, time: time, hold: 0, easeIn: ease, easeOut: ease, position: at,
            pan: pan, tilt: tilt, roll: 0, focalLength: focal
        )
    }

    private func evaluator(_ scene: PrevisScene) throws -> ShotEvaluator {
        try ShotEvaluator(scene: scene, shotID: "h", catalog: catalog)
    }

    private func state(_ id: EntityID, _ evaluator: ShotEvaluator, at t: Double) throws -> EntityFrame {
        try #require(evaluator.frame(at: t).entities.first { $0.id == id })
    }

    /// evaluate.test.ts `fixture()`: a man walks (0,0,0) → (0,0,-10) over 0...5 s; the camera has two marks.
    private func walkFixture() -> PrevisScene {
        var scene = scene()
        scene.entities = [entity("man", "person.man", .zero)]
        scene.blocking[0].tracks = [
            Track(
                entityID: "man",
                marks: [
                    actorMark("m1", Vec3(0, 0, 0), 0, ease: 0), actorMark("m2", Vec3(0, 0, -10), 5, ease: 0),
                ]
            ),
        ]
        scene.shots[0].camera.marks = [
            cameraMark("c1", Vec3(5, 1.6, 0), 0, pan: 0, tilt: 0, focal: 35, ease: 0),
            cameraMark("c2", Vec3(5, 1.6, -10), 5, pan: .pi / 2, tilt: 0.1, focal: 85, ease: 0),
        ]
        scene.shots[0].camera.seed = 42
        return scene
    }

    // MARK: evaluate.test.ts

    @Test func placesTheActorAtMarksAtMarkTimes() throws {
        let evaluator = try evaluator(walkFixture())
        #expect(try abs(state("man", evaluator, at: 0).position.z) < 5e-4)
        #expect(try abs(state("man", evaluator, at: 5).position.z + 10) < 0.05)
    }

    @Test func travelsLinearlyWithNoEasing() throws {
        let mid = try state("man", evaluator(walkFixture()), at: 2.5)
        #expect(abs(mid.position.z + 5) < 0.05)
        #expect(abs(mid.speed - 2) < 0.05)
        #expect(abs(mid.heading) < 0.005, "walking -Z faces heading 0")
        #expect(mid.gait == .walk)
        #expect(abs(mid.distanceTravelled - 5) < 0.05)
    }

    @Test func isAPureFunctionOfTime() throws {
        let a = try evaluator(walkFixture()), b = try evaluator(walkFixture())
        _ = b.frame(at: 4.9)
        _ = b.frame(at: 0.3)
        #expect(a.frame(at: 2.2) == b.frame(at: 2.2))
    }

    @Test func interpolatesCameraLensAndOrientationBetweenMarks() throws {
        let evaluator = try evaluator(walkFixture())
        let start = evaluator.frame(at: 0).camera, mid = evaluator.frame(at: 2.5).camera
        let end = evaluator.frame(at: 5).camera
        #expect(abs(start.focalLength - 35) < 1e-4 && abs(end.focalLength - 85) < 1e-4)
        #expect(mid.focalLength > 35 && mid.focalLength < 85)
        #expect(abs(end.pan - .pi / 2) < 0.005)
        #expect(end.verticalFOV < start.verticalFOV, "vfov narrows as focal length grows")
    }

    @Test func holdsAtAMarkDuringItsHoldWindow() throws {
        var scene = walkFixture()
        scene.blocking[0].tracks[0].marks[0].hold = 2
        let atOne = try state("man", evaluator(scene), at: 1)
        #expect(abs(atOne.position.z) < 5e-4 && atOne.speed == 0)
    }

    @Test func appliesSeededRigNoiseDeterministically() throws {
        var scene = walkFixture()
        scene.shots[0].camera.rig = .handheld
        scene.shots[0].camera.rigIntensity = 1
        #expect(try evaluator(scene).frame(at: 1.7).camera == evaluator(scene).frame(at: 1.7).camera)
        var other = scene
        other.shots[0].camera.seed = 999
        #expect(try abs(evaluator(scene).frame(at: 1.7).camera.pan - evaluator(other).frame(at: 1.7).camera.pan) > 1e-8)
    }

    @Test func staticEntitiesStayPut() throws {
        var scene = walkFixture()
        scene.entities.append(entity("couch", "furniture.couch", Vec3(3, 0, -2)))
        let couch = try state("couch", evaluator(scene), at: 2.5)
        #expect(couch.position == Vec3(3, 0, -2) && couch.speed == 0)
    }

    @Test func warnsOnImplausibleSpeeds() throws {
        var scene = walkFixture()
        scene.blocking[0].tracks[0].marks[1].time = 1
        scene.shots[0].frameCount = 49
        let warnings = try evaluator(scene).warnings()
        // Blockout reports exactly one warning here, a too-fast walk. So do we, with the same verdict and suggestion.
        let speed = warnings.filter { $0.message.contains("faster") }
        #expect(speed.count == 1 && speed[0].message.contains("10.0 m/s") && speed[0].message.contains("jog"))
        // The other two are Shots additions the contract asks for (trained range, marks past the end), not deviations:
        // Blockout's fixture leaves its camera marks at 5 s in a 2 s shot, and a 2 s shot is outside the trained range.
        let text = warnings.map(\.message).joined(separator: "\n")
        #expect(
            warnings.count == 3 && text.contains("49 frames") && text.contains("camera mark is at 5.00 s"),
            "\(text)"
        )
    }

    @Test func aCarMountedCameraFollowsTheVehicle() throws {
        var scene = scene()
        scene.entities = [entity("car", "vehicle.suv", .zero)]
        scene.blocking[0].tracks = [
            Track(entityID: "car", marks: [actorMark("a", .zero, 0), actorMark("b", Vec3(0, 0, -20), 5)]),
        ]
        scene.shots[0].camera.rig = .carMount
        scene.shots[0].camera.mountID = "car"
        scene.shots[0].camera.marks = [cameraMark("c", Vec3(0, 1.5, 2), 0, pan: 0, tilt: 0, focal: 35)]
        let evaluator = try evaluator(scene)
        #expect(evaluator.frame(at: 5).camera.position.z < evaluator.frame(at: 0).camera.position.z - 15)
    }

    @Test func pathsExposePolylinesForCameraAndActors() throws {
        let paths = try evaluator(walkFixture()).paths()
        #expect(paths.contains { $0.subject == .camera })
        #expect(paths.filter { $0.subject != .camera }.count > 0)
    }

    // MARK: tracking.test.ts

    private func trackingFixture() -> PrevisScene {
        var scene = scene(duration: 4)
        scene.entities = [entity("runner", "person.man", Vec3(-6, 0, -4))]
        scene.blocking[0].tracks = [
            Track(
                entityID: "runner",
                marks: [
                    actorMark("r1", Vec3(-6, 0, -4), 0, gait: .run, ease: 0),
                    actorMark("r2", Vec3(6, 0, -4), 4, gait: .run, ease: 0),
                ]
            ),
        ]
        // deliberately aimed the wrong way by its mark
        scene.shots[0].camera.marks = [cameraMark("c", Vec3(0, 1.6, 4), 0, pan: .pi, tilt: 0.5, focal: 35)]
        return scene
    }

    @Test func aimLockFollowsTheSubjectAcrossTheFrame() throws {
        var scene = trackingFixture()
        scene.shots[0].camera.trackIDs = ["runner"]
        let evaluator = try evaluator(scene)
        func look(_ t: Double) throws -> (pan: Double, expected: Double, tilt: Double) {
            let frame = evaluator.frame(at: t)
            let runner = try #require(frame.entities.first { $0.id == "runner" })
            let expected = headingOf(
                dx: runner.position.x - frame.camera.position.x,
                dz: runner.position.z - frame.camera.position.z
            )
            return (frame.camera.pan, expected, frame.camera.tilt)
        }
        let early = try look(0.2), late = try look(3.8)
        #expect(abs(early.pan - early.expected) < 5e-5 && abs(late.pan - late.expected) < 5e-5)
        #expect(abs(late.pan - early.pan) > 0.5)
        #expect(early.tilt < 0.1, "the camera tilts down to the chest, never the mark's 0.5 up")
    }

    @Test func withoutTrackingTheMarkAimIsRespected() throws {
        let camera = try evaluator(trackingFixture()).frame(at: 2).camera
        #expect(abs(camera.pan - .pi) < 1e-5 && abs(camera.tilt - 0.5) < 1e-5)
    }

    @Test func trackingFollowsAnAirborneSubjectInTiltToo() throws {
        var scene = trackingFixture()
        scene.shots[0].camera.trackIDs = ["runner"]
        scene.blocking[0].tracks[0].marks[1].position.y = 12
        let evaluator = try evaluator(scene)
        #expect(evaluator.frame(at: 3.9).camera.tilt > evaluator.frame(at: 0.2).camera.tilt + 0.3)
    }

    // MARK: round3.test.ts: attachments, boarding, alighting, the 180° rule

    private func movingVehicle() -> PrevisScene {
        var scene = scene(duration: 4)
        scene.entities = [entity("car", "vehicle.suv", .zero)]
        scene.blocking[0].tracks = [
            Track(
                entityID: "car",
                marks: [actorMark("a", .zero, 0, ease: 0), actorMark("b", Vec3(0, 0, -8), 4, ease: 0)]
            ),
        ]
        return scene
    }

    private func attach(
        _ entity: PrevisEntity,
        to parent: EntityID,
        _ x: Double,
        _ y: Double,
        _ z: Double
    ) -> PrevisEntity {
        var attached = entity
        attached.attachment = EntityAttachment(parentID: parent, offset: Vec3(x, y, z), rotation: .identity)
        return attached
    }

    @Test func aRiderFollowsAMovingVehicleAtItsLocalOffset() throws {
        var scene = movingVehicle()
        scene.entities.append(attach(entity("rider", "person.man", Vec3(0.5, 0.8, 0)), to: "car", 0.5, 0.8, 0))
        let evaluator = try evaluator(scene)
        let car = try state("car", evaluator, at: 2), rider = try state("rider", evaluator, at: 2)
        #expect(abs(rider.position.z - car.position.z) < 5e-4 && abs(rider.position.x - car.position.x - 0.5) < 5e-4)
        #expect(abs(rider.position.y - 0.8) < 5e-4 && abs(rider.heading - car.heading) < 1e-5)
        #expect(abs(rider.speed - car.speed) < 5e-4, "riding: animation params follow the parent")
    }

    @Test func localOffsetsRotateWithTheParentHeading() throws {
        var scene = scene()
        scene.entities = [
            entity("car", "vehicle.suv", .zero, heading: .pi / 2),
            attach(entity("rider", "person.man", .zero), to: "car", 1, 0, 0),
        ]
        let rider = try state("rider", evaluator(scene), at: 0)
        #expect(abs(rider.position.x) < 5e-5 && abs(rider.position.z + 1) < 5e-5)
        #expect(abs(rider.heading - .pi / 2) < 1e-5)
    }

    @Test func chainsSettleARiderOnACartMarriedToATruck() throws {
        var scene = movingVehicle()
        scene.entities.append(attach(entity("cart", "prim.cube", Vec3(0, 0, 1)), to: "car", 0, 0, 1))
        scene.entities.append(attach(entity("rider", "person.man", Vec3(0, 1, 1)), to: "cart", 0, 1, 0))
        let evaluator = try evaluator(scene)
        let car = try state("car", evaluator, at: 2), rider = try state("rider", evaluator, at: 2)
        #expect(abs(rider.position.z - car.position.z - 1) < 0.005 && abs(rider.position.y - 1) < 5e-4)
    }

    @Test func anAttachedEntityWithItsOwnMarksIgnoresTheMarriage() throws {
        var scene = movingVehicle()
        scene.entities.append(attach(entity("walker", "person.man", Vec3(5, 0, 5)), to: "car", 0, 0, 0))
        scene.blocking[0].tracks.append(
            Track(entityID: "walker", marks: [actorMark("w1", Vec3(5, 0, 5), 0), actorMark("w2", Vec3(5, 0, 1), 4)])
        )
        #expect(try abs(state("walker", evaluator(scene), at: 2).position.x - 5) < 0.005)
    }

    @Test func boardingAnActorWalksToTheBusThenRidesIt() throws {
        var scene = scene(duration: 10)
        scene.entities = [entity("bus", "vehicle.bus", Vec3(5, 0, 0)), entity("man", "person.man", Vec3(0, 0, 2))]
        scene.blocking[0].tracks = [
            Track(
                entityID: "bus",
                marks: [actorMark("b1", Vec3(5, 0, 0), 0, hold: 4), actorMark("b2", Vec3(5, 0, -20), 10)]
            ),
            Track(
                entityID: "man",
                marks: [actorMark("m1", Vec3(0, 0, 2), 0), actorMark("m2", Vec3(4.3, 0, 0.5), 3, boards: "bus")]
            ),
        ]
        let evaluator = try evaluator(scene)
        #expect(try state("man", evaluator, at: 1.5).position.x < 4)
        let bus = try state("bus", evaluator, at: 8), man = try state("man", evaluator, at: 8)
        #expect(bus.position.z < -5)
        #expect(abs(man.position.z - bus.position.z - 0.5) < 0.05 && abs(man.position.x - bus.position.x + 0.7) < 0.05)
        #expect(abs(man.speed - bus.speed) < 5e-4)
    }

    @Test func alightingAMarriedRiderFollowsTheVehicleUntilHisOwnMarksBegin() throws {
        var scene = scene(duration: 10)
        scene.entities = [
            entity("plane", "vehicle.plane", Vec3(0, 0, 20)),
            attach(entity("pax", "person.man", Vec3(1, 0, 20)), to: "plane", 1, 0, 0),
        ]
        scene.blocking[0].tracks = [
            Track(
                entityID: "plane",
                marks: [actorMark("p1", Vec3(0, 0, 20), 0), actorMark("p2", Vec3(0, 0, 0), 5, hold: 5)]
            ),
            Track(entityID: "pax", marks: [actorMark("w1", Vec3(1, 0, 0), 6), actorMark("w2", Vec3(8, 0, -3), 9)]),
        ]
        let evaluator = try evaluator(scene)
        let plane = try state("plane", evaluator, at: 2.5), pax = try state("pax", evaluator, at: 2.5)
        #expect(abs(pax.position.z - plane.position.z) < 0.05)
        #expect(try state("pax", evaluator, at: 8).position.x > 3)
    }

    @Test func flagsCameraMarksOnOppositeSidesOfTheAxisOfAction() throws {
        var scene = scene()
        scene.entities = [entity("a", "person.man", Vec3(-2, 0, 0)), entity("b", "person.woman", Vec3(2, 0, 0))]
        scene.shots[0].camera.marks = [
            cameraMark("c1", Vec3(0, 1.6, 4), 0, pan: 0, tilt: 0, focal: 35),
            cameraMark("c2", Vec3(0, 1.6, -4), 3, pan: .pi, tilt: 0, focal: 35),
        ]
        let crossings = try evaluator(scene).warnings().filter { $0.message.contains("crosses the line") }
        #expect(crossings.count == 1 && crossings[0].message.contains("marks 1 and 2"), "\(crossings.map(\.message))")
    }

    @Test func noLineWarningWhenCoverageStaysOnOneSide() throws {
        var scene = scene()
        scene.entities = [entity("a", "person.man", Vec3(-2, 0, 0)), entity("b", "person.woman", Vec3(2, 0, 0))]
        scene.shots[0].camera.marks = [
            cameraMark("c1", Vec3(-1, 1.6, 4), 0, pan: 0, tilt: 0, focal: 35),
            cameraMark("c2", Vec3(3, 1.6, 2), 3, pan: 0.4, tilt: 0, focal: 35),
        ]
        #expect(try evaluator(scene).warnings().filter { $0.message.contains("crosses the line") }.isEmpty)
    }

    // MARK: audit-fixes.test.ts, camera.test.ts

    @Test func aHoldOverlappingTheNextMarkLeavesARealTravelWindow() throws {
        var scene = scene()
        scene.entities = [entity("man", "person.man", .zero)]
        var first = actorMark("m1", .zero, 0)
        first.hold = 10 // extends past the next mark's arrival at t = 3
        scene.blocking[0].tracks = [Track(entityID: "man", marks: [first, actorMark("m2", Vec3(0, 0, -6), 3)])]
        let evaluator = try evaluator(scene)
        #expect(try state("man", evaluator, at: 2.99).position.z < -4, "travelling just before arrival, not snapping")
        #expect(try abs(state("man", evaluator, at: 3).position.z + 6) < 0.05)
    }

    @Test func jointsHoldAtAMarkAndBlendAcrossALeg() throws {
        var scene = scene()
        scene.entities = [entity("man", "person.man", .zero)]
        var first = actorMark("m1", .zero, 0, ease: 0), second = actorMark("m2", Vec3(0, 0, -4), 4, ease: 0)
        first.joints = [.shoulderLX: -1]
        second.joints = [.shoulderLX: 0, .elbowR: 1]
        scene.blocking[0].tracks = [Track(entityID: "man", marks: [first, second])]
        let evaluator = try evaluator(scene)
        let start = try state("man", evaluator, at: 0)
        #expect(abs(start.joints[.shoulderLX, default: .nan] + 1) < 1e-5)
        let mid = try state("man", evaluator, at: 2)
        #expect(abs(mid.joints[.shoulderLX, default: .nan] + 0.5) < 0.05)
        #expect(abs(mid.joints[.elbowR, default: .nan] - 0.5) < 0.05)
        let end = try state("man", evaluator, at: 4.5)
        #expect(abs(end.joints[.shoulderLX, default: .nan]) < 1e-5)
        #expect(abs(end.joints[.elbowR, default: .nan] - 1) < 1e-5)
    }

    @Test func autoFramingNeedsLessDistanceForCloserSizesAndMoreForLongerLenses() throws {
        func distance(_ kind: Framing.Kind, lens: Double) throws -> Double {
            var scene = scene()
            scene.entities = [entity("man", "person.man", .zero)]
            scene.shots[0].canvas = ShotCanvas(width: 1152, height: 640)
            scene.shots[0].camera.marks = [cameraMark("c", Vec3(0, 1.6, 6), 0, pan: 0, tilt: 0, focal: lens)]
            let mark = try Framing.cameraMark(
                kind, scene: scene, shotID: "h", subjects: ["man"], atFrame: 0, catalog: catalog
            )
            return hypot(mark.position.x, mark.position.z)
        }
        let wide = try distance(.wide, lens: 35)
        let medium = try distance(.medium, lens: 35)
        let close = try distance(.closeUp, lens: 35)
        #expect(wide > medium && medium > close && close > 0, "wide \(wide), medium \(medium), close-up \(close)")
        #expect(try distance(.medium, lens: 85) > medium)
    }
}
