import Foundation
import PrevisCore
@testable import ShotsMedia
import Testing

@Suite("camera legs")
struct CameraLegTests {
    @Test func aMoveSqueezedOutByALongHoldStillReads() throws {
        // The first mark's hold runs past the second mark, so the evaluator leaves 0.1 s before it to push 0.3 m:
        // fast, though spread over its whole half-second piece it would read as medium.
        let legs = try cameraLegs(
            frames: 39,
            marks: [mark(0, at: Vec3(0, 1.6, 6), hold: 2), mark(1, at: Vec3(0, 1.6, 5.7))]
        )
        #expect(legs.map(\.move) == [.static, .push, .static])
        #expect(legs.dropFirst().first?.speed == .fast)
    }

    /// A snap is brief but large, so it is named; a brief small move would not be. Here 2 m in two frames.
    @Test func aSnapBetweenTwoCloseMarksIsKept() throws {
        let marks = [
            mark(0, at: Vec3(0, 1.6, 6)), mark(21.0 / 24, at: Vec3(0, 1.6, 6)), mark(23.0 / 24, at: Vec3(0, 1.6, 4)),
        ]
        let legs = try cameraLegs(frames: 39, marks: marks)
        #expect(legs.map(\.move) == [.static, .push, .static], "\(legs)")
        let snap = try #require(legs.dropFirst().first)
        #expect(snap.toFrame - snap.fromFrame < CameraLegs.minimumHoldFrames && snap.speed == .fast)
    }

    /// Closing from 6 m to 2 m on a man who walks away at 1.4 m/s: a push relative to him, made while following
    /// him.
    @Test func aPushOnAWalkerAlsoFollowsHim() throws {
        let legs = try cameraLegs(
            frames: 73, marks: [mark(0, at: Vec3(0, 1.6, 6)), mark(3, at: Vec3(0, 1.6, -2.2))],
            subject: ("person.man", [(0, Vec3.zero), (3, Vec3(0, 0, -4.2))]), aimed: true
        )
        #expect(legs.map(\.move) == [.push] && legs.first?.also == [.track], "\(legs)")
    }

    /// The shortest shot, five frames, with a small move in it, still reads as one leg covering it.
    @Test func theShortestShotKeepsALeg() throws {
        let legs = try cameraLegs(
            frames: 5, marks: [mark(0, at: Vec3(0, 1.6, 6)), mark(2.0 / 24, at: Vec3(0, 1.6, 5.8))]
        )
        #expect(legs.count == 1 && legs.first?.fromFrame == 0 && legs.last?.toFrame == 4, "\(legs)")
    }

    /// A few centimetres of drift while a man walks across is still a pan, not an arc round him.
    @Test func driftWhileAWalkerCrossesIsStillAPan() throws {
        let legs = try cameraLegs(
            frames: 73, marks: [mark(0, at: Vec3(0, 1.6, 6)), mark(3, at: Vec3(0, 1.6, 5.9))],
            subject: ("person.man", [(0, Vec3(-3, 0, 0)), (3, Vec3(3, 0, 0))]), aimed: true
        )
        #expect(legs.map(\.move) == [.panRight], "\(legs)")
    }

    /// Even 30 cm of drift, enough to name on its own, is little beside the man's 6 m walk: still a pan.
    @Test func aDriftSmallBesideTheWalkIsStillAPan() throws {
        let legs = try cameraLegs(
            frames: 73, marks: [mark(0, at: Vec3(0, 1.6, 6)), mark(3, at: Vec3(0, 1.6, 5.7))],
            subject: ("person.man", [(0, Vec3(-3, 0, 0)), (3, Vec3(3, 0, 0))]), aimed: true
        )
        #expect(legs.map(\.move) == [.panRight], "\(legs)")
    }

    /// A free camera that pans 90° while drifting 20 cm forward pans, and one that tilts 40° tilts.
    @Test func aPanOrTiltOutweighsAShortDrift() throws {
        let start = mark(0, at: Vec3(0, 1.6, 6))
        let panned = try cameraLegs(frames: 73, marks: [start, mark(3, at: Vec3(0, 1.6, 5.8), pan: .pi / 2)])
        let tilted = try cameraLegs(
            frames: 73, marks: [start, mark(3, at: Vec3(0, 1.6, 5.8), tilt: 40 * .pi / 180)]
        )
        #expect(panned.map(\.move) == [.panLeft] && tilted.map(\.move) == [.tiltUp], "\(panned) \(tilted)")
    }

    /// A push keyed with a mark every quarter second, 12.5 cm apart, is still a push: the travel adds up.
    @Test(arguments: [(13, 0.25, 1.5), (7, 0.5, 0.75)])
    func aPushKeyedWithCloseMarksIsAPush(marks count: Int, every step: Double, metres: Double) throws {
        let marks = (0 ..< count).map { index in
            mark(Double(index) * step, at: Vec3(0, 1.6, 6 - metres * Double(index) / Double(count - 1)))
        }
        #expect(try cameraLegs(frames: 73, marks: marks).map(\.move) == [.push])
    }

    /// A camera 10 m up, aimed at a man walking past below, pans with him: looking steeply down is still a pan when
    /// the aim makes it.
    @Test func aHighAimedCameraPansWithAWalker() throws {
        let legs = try cameraLegs(
            frames: 73, marks: [mark(0, at: Vec3(0, 10, 0))],
            subject: ("person.man", [(0, Vec3(-5, 0, -5)), (3, Vec3(5, 0, -5))]), aimed: true
        )
        #expect(legs.map(\.move) == [.panRight], "\(legs)")
    }

    /// A free camera tilted up 60° that pans a quarter turn pans: the point straight above is out of its view.
    @Test func aSteepPanIsStillAPan() throws {
        let tilt = 60 * Double.pi / 180
        let legs = try cameraLegs(
            frames: 73,
            marks: [mark(0, at: Vec3(0, 1.6, 6), tilt: tilt), mark(3, at: Vec3(0, 1.6, 6), pan: .pi / 2, tilt: tilt)]
        )
        #expect(legs.map(\.move) == [.panLeft], "\(legs)")
    }

    /// A 30° pan with 40 cm of forward drift pans, either way, with or without a centimetre of sideways drift; a
    /// 40° tilt tilts, with a 2° pan or with a sideways move that pans like an orbit.
    @Test func aPanOrTiltWithDriftIsNoOrbitOrPush() throws {
        func reading(to end: Vec3, pan: Double = 0, tilt: Double = 0) throws -> [CameraMove] {
            try cameraLegs(frames: 73, marks: [mark(0, at: Vec3(0, 1.6, 6)), mark(3, at: end, pan: pan, tilt: tilt)])
                .map(\.move)
        }
        #expect(try reading(to: Vec3(0, 1.6, 5.6), pan: -.pi / 6) == [.panRight])
        #expect(try reading(to: Vec3(0, 1.6, 5.6), pan: .pi / 6) == [.panLeft])
        #expect(try reading(to: Vec3(0.01, 1.6, 5.6), pan: .pi / 6) == [.panLeft])
        #expect(try reading(to: Vec3(0, 1.6, 5.8), pan: -2 * .pi / 180, tilt: 40 * .pi / 180) == [.tiltUp])
        // Mostly forward, 40 cm on and 20 cm aside, a 20° pan is a pan: a forward move doesn't circle anything.
        #expect(try reading(to: Vec3(0.2, 1.6, 5.6), pan: 0.35) == [.panLeft])
        // Even shaped like circling something, a 40° tilt over 30 cm is a tilt.
        #expect(try reading(to: Vec3(0.3, 1.6, 6), pan: 0.3, tilt: 40 * .pi / 180) == [.tiltUp])
    }

    /// Each stretch between marks is weighed on its own: a 1 m push, then a quarter-turn pan with 10 cm of drift.
    @Test func aPushThenAPanReadsAsBoth() throws {
        let legs = try cameraLegs(frames: 73, marks: [
            mark(0, at: Vec3(0, 1.6, 6)), mark(2, at: Vec3(0, 1.6, 5)), mark(3, at: Vec3(0, 1.6, 4.9), pan: .pi / 2),
        ])
        #expect(legs.map(\.move) == [.push, .panLeft], "\(legs)")
    }

    /// A pan left and back again, drifting 20 cm, is two pans: the turns don't cancel into nothing.
    @Test func aPanOutAndBackIsTwoPans() throws {
        let legs = try cameraLegs(frames: 73, marks: [
            mark(0, at: Vec3(0, 1.6, 6)), mark(1.5, at: Vec3(0, 1.6, 5.9), pan: .pi / 2), mark(
                3,
                at: Vec3(0, 1.6, 5.8)
            ),
        ])
        #expect(legs.map(\.move) == [.panLeft, .panRight], "\(legs)")
    }

    /// A 3 cm drift, a 1 m push in a second, and another drift: the drifts are holds, and the push keeps its pace.
    @Test func driftsAroundAPushAreHolds() throws {
        let legs = try cameraLegs(frames: 73, marks: [
            mark(0, at: Vec3(0, 1.6, 6)), mark(1, at: Vec3(0, 1.6, 5.97)), mark(2, at: Vec3(0, 1.6, 4.97)),
            mark(3, at: Vec3(0, 1.6, 4.94)),
        ])
        #expect(legs.map(\.move) == [.static, .push, .static], "\(legs)")
        #expect(legs.dropFirst().first?.speed == .medium)
    }

    /// Looking straight down, a camera that rises 30 cm while spinning half a turn cranes up with the spin riding on
    /// it.
    @Test func aSpinRidesOnACrane() throws {
        let tilt = -Double.pi / 2 + 0.001
        let legs = try cameraLegs(
            frames: 73,
            marks: [mark(0, at: Vec3(0, 10, 0), tilt: tilt), mark(3, at: Vec3(0, 10.3, 0), pan: .pi, tilt: tilt)]
        )
        #expect(legs.map(\.move) == [.craneUp] && legs.first?.also == [.rollCounterclockwise], "\(legs)")
    }

    /// A free camera that pans 90° or zooms 35 to 85 mm while drifting 10 cm pans or zooms; it doesn't hold.
    @Test func driftDoesNotHideAPanOrAZoom() throws {
        let start = mark(0, at: Vec3(0, 1.6, 6))
        let panned = try cameraLegs(frames: 73, marks: [start, mark(3, at: Vec3(0.1, 1.6, 6), pan: -.pi / 2)])
        let zoomed = try cameraLegs(frames: 73, marks: [start, mark(3, at: Vec3(0.1, 1.6, 6), focalLength: 85)])
        #expect(panned.map(\.move) == [.panRight] && zoomed.map(\.move) == [.zoomIn], "\(panned) \(zoomed)")
    }

    /// Trucking 6 m with a 6° pan is a truck: circling something within 30 m would turn far more.
    @Test func aTruckWithASlightPanIsATruck() throws {
        let legs = try cameraLegs(
            frames: 73, marks: [mark(0, at: Vec3(0, 1.6, 6)), mark(3, at: Vec3(6, 1.6, 6), pan: 6 * .pi / 180)]
        )
        #expect(legs.map(\.move) == [.truckRight], "\(legs)")
    }

    /// A man walks 8 m up to a camera that drifts 5 cm: the camera hasn't pushed in, he has come to it.
    @Test func aManWalkingUpToADriftingCameraIsNoPush() throws {
        let legs = try cameraLegs(
            frames: 73, marks: [mark(0, at: Vec3(0, 1.6, 6)), mark(3, at: Vec3(0, 1.6, 5.95))],
            subject: ("person.man", [(0, Vec3(0, 0, -8)), (3, Vec3.zero)]), aimed: true
        )
        #expect(legs.map(\.move) == [.static], "\(legs)")
    }

    /// Trucking 1 m past a man standing 20 m off turns too little to be an orbit and isn't following anyone.
    @Test func aSmallTruckPastAStandingManIsATruck() throws {
        let legs = try cameraLegs(
            frames: 73, marks: [mark(0, at: Vec3(0, 1.6, 20)), mark(3, at: Vec3(1, 1.6, 20))],
            subject: ("person.man", [(0, Vec3.zero)]), aimed: true
        )
        #expect(legs.map(\.move) == [.truckRight], "\(legs)")
    }

    @Test func anAimLockedCameraPansWithAWalker() throws {
        // One camera mark, aimed at a man who crosses from the camera's left to its right.
        let legs = try cameraLegs(
            frames: 73, marks: [mark(0, at: Vec3(0, 1.6, 6))],
            subject: ("person.man", [(0, Vec3(-3, 0, 0)), (3, Vec3(3, 0, 0))]), aimed: true
        )
        #expect(legs.map(\.move) == [.panRight])
    }

    @Test func aPushLaidDownAsManyMarksIsOneLeg() throws {
        let marks = (0 ... 4).map { mark(Double($0) * 0.75, at: Vec3(0, 1.6, 6 - Double($0))) }
        #expect(try cameraLegs(frames: 73, marks: marks).map(\.move) == [.push])
    }

    /// Blockout's "Orbit 90° Left": a quarter circle counter-clockwise, seen from above, round a subject at the
    /// origin, from 6 m in front of it (+Z) to 6 m to its side (+X); and the same the other way round.
    @Test(arguments: [true, false])
    func orbitsAreNamedAsBlockoutNamesThem(aimed: Bool) throws {
        func around(_ step: Int, _ sweep: Double) -> CameraMark {
            let azimuth = Double.pi + sweep * Double(step) / 6
            let position = Vec3(-sin(azimuth) * 6, 1.6, -cos(azimuth) * 6)
            return mark(Double(step) * 0.5, at: position, pan: atan2(position.x, position.z))
        }
        let subject = ("person.man", [(0.0, Vec3.zero)])
        let left = try cameraLegs(
            frames: 73,
            marks: (0 ... 6).map { around($0, .pi / 2) },
            subject: subject,
            aimed: aimed
        )
        let right = try cameraLegs(
            frames: 73,
            marks: (0 ... 6).map { around($0, -.pi / 2) },
            subject: subject,
            aimed: aimed
        )
        #expect(left.map(\.move) == [.orbitLeft] && right.map(\.move) == [.orbitRight], "\(left) \(right)")
    }

    /// Without aim lock, a quarter circle only 1.5 m out, panned at the centre, is still an orbit.
    @Test func aCloseFreeOrbitIsAnOrbit() throws {
        let marks = (0 ... 6).map { step in
            let azimuth = Double.pi + Double.pi / 2 * Double(step) / 6
            let position = Vec3(-sin(azimuth) * 1.5, 1.6, -cos(azimuth) * 1.5)
            return mark(Double(step) * 0.5, at: position, pan: atan2(position.x, position.z))
        }
        #expect(try cameraLegs(frames: 73, marks: marks).map(\.move) == [.orbitLeft])
    }

    @Test func aCarMountedCameraTracksItsCar() throws {
        // The camera rides 4 m behind a sedan that drives 20 m.
        var scene = try shotScene(
            frames: 73, marks: [mark(0, at: Vec3(0, 1.5, 4))],
            subject: ("vehicle.sedan", [(0, Vec3.zero), (3, Vec3(0, 0, -20))])
        )
        scene.shots[0].camera.rig = .carMount
        scene.shots[0].camera.mountID = "ent_subject"
        #expect(try facts(scene).cameraLegs.map(\.move) == [.track])
    }

    /// Blockout's "Follow Behind" stays 4 m behind its subject, glued to its heading. Here the man walks a quarter
    /// turn, and the camera, aimed at him, keeps behind him all the way: a track, not an arc round him.
    @Test func aCameraKeptBehindATurningWalkerTracksHim() throws {
        let legs = try legsAroundTurningWalker { _, man, heading in
            Vec3(man.x + 4 * sin(heading), 1.6, man.z + 4 * cos(heading))
        }
        #expect(legs.map(\.move) == [.track], "\(legs)")
    }

    /// The same walker with the camera kept 4 m to his south in the world, not turning with him: still a track.
    @Test func aCameraKeptAtAWorldOffsetFromATurningWalkerTracksHim() throws {
        let legs = try legsAroundTurningWalker { _, man, _ in Vec3(man.x, 1.6, man.z + 4) }
        #expect(legs.map(\.move) == [.track], "\(legs)")
    }

    /// Blockout's "Slow Push-In" closes in along the camera's first bearing in the world, from 6 m to 2 m. Round the
    /// same turning walker it is a push made while following him, not an arc.
    @Test func aPushThatKeepsItsBearingOnATurningWalkerIsAPush() throws {
        let legs = try legsAroundTurningWalker { time, man, _ in Vec3(man.x, 1.6, man.z + 6 - 4 * time / 3) }
        #expect(legs.map(\.move) == [.push] && legs.first?.also == [.track], "\(legs)")
    }

    /// Aimed at a man standing at the origin, the camera circles him a quarter turn only 1.5 m away. Its aim turns
    /// a lot for its travel, but that turn comes from where it goes: an orbit, not a pan.
    @Test func aCloseAimLockedOrbitIsAnOrbit() throws {
        let marks = (0 ... 6).map { step in
            let azimuth = Double.pi + Double.pi / 2 * Double(step) / 6
            return mark(Double(step) * 0.5, at: Vec3(-sin(azimuth) * 1.5, 1.6, -cos(azimuth) * 1.5))
        }
        let legs = try cameraLegs(frames: 73, marks: marks, subject: ("person.man", [(0, Vec3.zero)]), aimed: true)
        #expect(legs.map(\.move) == [.orbitLeft], "\(legs)")
    }

    /// Pushing in 1 m while zooming 35 to 85 mm is one push with a zoom riding on it.
    @Test func aPushWithAStrongZoomIsOnePush() throws {
        let legs = try cameraLegs(
            frames: 73, marks: [mark(0, at: Vec3(0, 1.6, 6)), mark(3, at: Vec3(0, 1.6, 5), focalLength: 85)]
        )
        #expect(legs.map(\.move) == [.push] && legs.first?.also == [.zoomIn], "\(legs)")
        #expect(legs.first?.focalLength == [35, 85])
    }

    /// The camera creeps 30 cm while a man walks 8 m up to it, a little to one side, and the other way round: it
    /// neither follows him nor pushes in or pulls out by his 8 m. It holds.
    @Test(arguments: [true, false])
    func aCreepBesideAWalkerIsAHold(approaching: Bool) throws {
        let ends = [Vec3(-0.5, 0, -8), Vec3(-0.5, 0, 0)], camera = [Vec3(0, 1.6, 6), Vec3(0, 1.6, 5.7)]
        let man = approaching ? ends : ends.reversed(), drift = approaching ? camera : camera.reversed()
        let legs = try cameraLegs(
            frames: 73, marks: [mark(0, at: drift[0]), mark(3, at: drift[1])],
            subject: ("person.man", [(0, man[0]), (3, man[1])]), aimed: true
        )
        #expect(legs.map(\.move) == [.static], "\(legs)")
    }

    /// Looking straight down, a quarter turn of pan spins the picture about the lens: a roll.
    @Test func aTopDownSpinIsARoll() throws {
        let tilt = -Double.pi / 2 + 0.001
        let legs = try cameraLegs(
            frames: 73,
            marks: [mark(0, at: Vec3(0, 10, 0), tilt: tilt), mark(3, at: Vec3(0, 10, 0), pan: .pi / 2, tilt: tilt)]
        )
        #expect(legs.map(\.move) == [.rollCounterclockwise], "\(legs)")
    }

    /// A man placed facing −X walks off along −Z, so the evaluator snaps him to his path as he leaves. The camera
    /// keeps 4 m behind his path the whole time: the snap doesn't swing it round him, and it is a track.
    @Test func aWalkersSnapToHisPathDoesNotSwingTheCamera() throws {
        var scene = try shotScene(
            frames: 73, marks: (0 ... 12).map { mark(Double($0) / 4, at: Vec3(0, 1.6, 4 - 0.35 * Double($0))) },
            subject: ("person.man", [(0, Vec3.zero), (3, Vec3(0, 0, -4.2))]), aimed: true
        )
        scene.entities[0].placement.heading = .pi / 2
        let legs = try facts(scene).cameraLegs
        #expect(legs.map(\.move) == [.track], "\(legs.map { "\($0.move) \($0.fromFrame)-\($0.toFrame)" })")
    }

    /// The camera rides behind a sedan that turns a corner: it stays behind the car, so it is still a track.
    @Test func aCarMountedCameraTracksItsCarRoundACorner() throws {
        var scene = try shotScene(
            frames: 73, marks: [mark(0, at: Vec3(0, 1.5, 4))],
            subject: ("vehicle.sedan", [(0, Vec3.zero), (1.5, Vec3(0, 0, -10)), (3, Vec3(-10, 0, -20))])
        )
        scene.shots[0].camera.rig = .carMount
        scene.shots[0].camera.mountID = "ent_subject"
        #expect(try facts(scene).cameraLegs.map(\.move) == [.track])
    }

    @Test func aDollyZoomPushesInWhileZoomingOut() throws {
        let facts = try facts(shotScene(
            frames: 73, marks: [mark(0, at: Vec3(0, 1.6, 6)), mark(3, at: Vec3(0, 1.6, 3), focalLength: 20)]
        ))
        #expect(facts.cameraLegs.map(\.move) == [.push] && facts.cameraLegs.first?.also == [.zoomOut])
        let prose = PromptTemplate.description(facts)
        #expect(prose.contains("On a 35 mm lens, the camera pushes in"), "\(prose)")
        #expect(prose.contains("while zooming out to a 20 mm lens"), "\(prose)")
    }

    /// The moves come from the steady camera; the rig's noise shows only as shake.
    @Test func aHandheldRigShakesWithoutChangingTheMove() throws {
        let marks = [mark(0, at: Vec3(0, 1.6, 6)), mark(3, at: Vec3(0, 1.6, 3))]
        var scene = try shotScene(frames: 73, marks: marks)
        #expect(try facts(scene).shake == nil)
        scene.shots[0].camera.rig = .handheld
        scene.shots[0].camera.rigIntensity = 1
        let shaken = try facts(scene)
        #expect(shaken.shake == .strong && shaken.cameraLegs.map(\.move) == [.push])
        #expect(PromptTemplate.description(shaken).contains("The camera shakes strongly."))
    }

    @Test func withoutCameraMarksTheShotHoldsOnA35mmLens() throws {
        let facts = try facts(shotScene(frames: 73, marks: []))
        #expect(facts.cameraLegs.map(\.move) == [.static] && facts.cameraLegs.first?.focalLength == [35, 35])
        #expect(PromptTemplate.description(facts).contains("On a 35 mm lens, the camera holds a static shot."))
    }
}

private func mark(
    _ time: Double,
    at position: Vec3,
    hold: Double = 0,
    pan: Double = 0,
    tilt: Double = 0,
    focalLength: Double = 35
) -> CameraMark {
    CameraMark(
        id: "cam_\(time)", time: time, hold: hold, easeIn: 0, easeOut: 0, position: position, pan: pan, tilt: tilt,
        roll: 0, focalLength: focalLength
    )
}

/// A man walks a quarter turn left, from the origin to (−6, 0, −6) over 3 s through (0, 0, −4) and (−2, 0, −6).
/// The camera, aimed at him, has a mark every quarter second wherever `place` puts it for his position and heading
/// then.
private func legsAroundTurningWalker(
    _ place: (_ time: Double, _ man: Vec3, _ heading: Double) -> Vec3
) throws -> [PromptFacts.CameraLeg] {
    var scene = try shotScene(frames: 73, marks: [], subject: ("person.man", [(0, Vec3.zero), (3, Vec3(-6, 0, -6))]))
    scene.blocking[0].tracks[0].marks[1].via = [Vec3(0, 0, -4), Vec3(-2, 0, -6)]
    let walker = try ShotEvaluator(scene: scene, shotID: scene.shots[0].id, catalog: ContentCatalog.bundled())
    scene.shots[0].camera.marks = (0 ... 12).map { step in
        let time = Double(step) / 4
        let man = walker.frame(at: time).entities.first
        return mark(time, at: place(time, man?.position ?? .zero, man?.heading ?? 0))
    }
    scene.shots[0].camera.trackIDs = ["ent_subject"]
    return try facts(scene).cameraLegs
}

/// One shot with `marks`, and optionally one subject walking (or driving) through `path`, aim-locked or not.
private func shotScene(
    frames: Int,
    marks: [CameraMark],
    subject: (asset: String, path: [(time: Double, at: Vec3)])? = nil,
    aimed: Bool = false
) throws -> PrevisScene {
    var scene = PrevisScene.make(
        id: "scene_legs", name: "Legs", takeID: "take_legs", shotID: "shot_legs", cameraMarkID: "cam_0"
    )
    scene.shots[0].frameCount = frames
    scene.shots[0].camera.marks = marks
    if let subject {
        let start = try #require(subject.path.first?.at)
        scene.entities = [PrevisEntity(
            id: "ent_subject", assetID: subject.asset, name: "Subject",
            placement: Placement(position: start, heading: 0, scale: 1)
        )]
        if subject.path.count > 1 {
            scene.blocking[0].tracks = [Track(entityID: "ent_subject", marks: subject.path.enumerated().map {
                ActorMark(
                    id: "m\($0.offset)", time: $0.element.time, hold: 0, easeIn: 0, easeOut: 0,
                    position: $0.element.at, gait: .walk
                )
            })]
        }
        scene.shots[0].camera.trackIDs = aimed ? ["ent_subject"] : []
    }
    return scene
}

private func facts(_ scene: PrevisScene) throws -> PromptFacts {
    try ShotPromptCompiler.facts(scene: scene, shotID: scene.shots[0].id, catalog: ContentCatalog.bundled())
}

private func cameraLegs(
    frames: Int,
    marks: [CameraMark],
    subject: (asset: String, path: [(time: Double, at: Vec3)])? = nil,
    aimed: Bool = false
) throws -> [PromptFacts.CameraLeg] {
    try facts(shotScene(frames: frames, marks: marks, subject: subject, aimed: aimed)).cameraLegs
}
