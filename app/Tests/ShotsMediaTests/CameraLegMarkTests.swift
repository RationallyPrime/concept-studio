import Foundation
import PrevisCore
@testable import ShotsMedia
import Testing

/// Around a travelling subject a relative move is read between the camera's marks, where camera and subject are
/// both where they were put; these are the edges of that rule.
@Suite("camera legs between the camera's marks")
struct CameraLegMarkTests {
    /// The camera pushes 3 m in on a man who stands for 3 s and then sprints off before its next mark. While he
    /// stands, its push is read on its own, not against where he ends up.
    @Test func aPushOnAManWhoThenRunsOffIsAPush() throws {
        let end = 140.0 / 24
        var scene = try shotScene(
            frames: 141,
            marks: [mark(0, at: Vec3(0, 1.6, 6)), mark(end, at: Vec3(0, 1.6, 0))],
            subject: ("person.man", [(0, .zero), (end, Vec3(0, 0, -18))]),
            aimed: true
        )
        scene.blocking[0].tracks[0].marks[0].hold = 3
        let legs = try legs(scene)
        #expect(legs.map(\.move) == [.push, .static] && legs.first?.toFrame == 72, "\(legs)")
    }

    /// A camera on a car, aimed at a runner, closes straight in behind him while the car drives, then holds when
    /// the car stops at 4 s. The car's marks place the camera as much as its own do.
    @Test func aCameraCarClosingOnARunnerThenStoppingPushesThenHolds() throws {
        let end = 191.0 / 24
        var scene = try shotScene(
            frames: 192,
            marks: [mark(0, at: Vec3(0, 1.5, 0))],
            subject: ("person.man", [(0, .zero), (end, Vec3(0, 0, -40))]),
            aimed: true
        )
        scene.entities.append(PrevisEntity(
            id: "ent_car", assetID: "vehicle.sedan", name: "Car",
            placement: Placement(position: Vec3(0, 0, 10), heading: 0, scale: 1)
        ))
        scene.blocking[0].tracks.append(Track(entityID: "ent_car", marks: [
            ActorMark(id: "c0", time: 0, hold: 0, easeIn: 0, easeOut: 0, position: Vec3(0, 0, 10), gait: .walk),
            ActorMark(id: "c1", time: 4, hold: 0, easeIn: 0, easeOut: 0, position: Vec3(0, 0, -16), gait: .walk),
        ]))
        scene.shots[0].camera.rig = .carMount
        scene.shots[0].camera.mountID = "ent_car"
        let legs = try legs(scene)
        #expect(legs.map(\.move) == [.push, .static] && legs.first?.toFrame == 96, "\(legs)")
    }

    /// Between two marks, curved by two waypoints, the camera goes three quarters of the way round a man walking
    /// slowly, counter-clockwise seen from above. Summed step by step, that is an orbit left, though its two ends
    /// are a quarter turn apart the other way.
    @Test func threeQuartersRoundAWalkerIsAnOrbitLeft() throws {
        var marks = [mark(0, at: Vec3(0, 1.6, 4)), mark(3, at: Vec3(-4, 1.6, -1.5))]
        marks[1].via = [Vec3(4, 1.6, -0.5), Vec3(0, 1.6, -5)]
        let scene = try shotScene(
            frames: 73, marks: marks, subject: ("person.man", [(0, .zero), (3, Vec3(0, 0, -1.5))]), aimed: true
        )
        let legs = try legs(scene)
        #expect(legs.map(\.move) == [.orbitLeft], "\(legs)")
    }

    /// Following a walker 6 m back, the camera jumps to 2 m back at 1.5 s, two marks at the same time, and follows
    /// on. The jump is a cut, not a move: the shot is one track.
    @Test func aJumpBetweenTwoMarksAtTheSameTimeIsNoMove() throws {
        let marks = [
            mark(0, at: Vec3(0, 1.6, 6)), mark(1.5, at: Vec3(0, 1.6, 3)), mark(1.5, at: Vec3(0, 1.6, -1)),
            mark(3, at: Vec3(0, 1.6, -4)),
        ]
        let scene = try shotScene(
            frames: 73, marks: marks, subject: ("person.man", [(0, .zero), (3, Vec3(0, 0, -6))]), aimed: true
        )
        let legs = try legs(scene)
        #expect(legs.map(\.move) == [.track], "\(legs)")
    }

    /// The camera's first mark holds past its second, so the evaluator leaves it 0.1 s before the second; both are
    /// the same place, where the camera waits, tilting up as a man walks off, then follows him 5 m back, eased out
    /// of its mark as Blockout's camera marks are by default. The hold's written end, half a second into the follow,
    /// places nothing: the follow is one track.
    @Test func aHoldCutShortPlacesTheCameraWhereTheEvaluatorLeaves() throws {
        let end = 191.0 / 24
        var marks = [
            mark(0, at: Vec3(0, 1.6, 0), hold: 2.5), mark(2, at: Vec3(0, 1.6, 0)),
            mark(end, at: Vec3(0, 1.6, -2 * end + 4)),
        ]
        marks[1].easeOut = 0.3
        let scene = try shotScene(
            frames: 192, marks: marks, subject: ("person.man", [(0, Vec3(0, 0, -1)), (end, Vec3(0, 0, -1 - 2 * end))]),
            aimed: true
        )
        let legs = try legs(scene)
        #expect(legs.map(\.move) == [.tiltUp, .track] && legs.first?.toFrame == 48, "\(legs)")
    }

    /// A4's follow-behind around a man who stands for 3 s and then walks off. Its marks are 1.14 s apart, so the
    /// camera starts closing on him 0.7 s before he moves, a push, then follows. Once he moves, its offset is read
    /// between its marks, where it is 4 m behind him; a centimetre of rounding there names nothing.
    @Test func aFollowRoundAManWhoStandsAndThenWalksPushesThenTracks() throws {
        let catalog = try ContentCatalog.bundled(), end = 191.0 / 24
        var scene = try shotScene(
            frames: 192,
            marks: [mark(0, at: Vec3(0, 1.6, 6))],
            subject: ("person.man", [(0, .zero), (end, Vec3(0, 0, -10))]),
            aimed: true
        )
        scene.blocking[0].tracks[0].marks[0].hold = 3
        let move = try CameraMoves.marks(
            "follow-behind", scene: scene, shotID: scene.shots[0].id, subjects: ["ent_subject"], catalog: catalog
        )
        scene.shots[0].camera.marks = move.marks
        let legs = try legs(scene)
        #expect(legs.map(\.move) == [.static, .push, .track], "\(legs)")
    }

    /// A man walks at 1.4 m/s, eased into and out of a mark every 2 s, as Blockout's actor marks are by default; the
    /// camera is keyed 4 m behind and 1.8 m above him a quarter of a second after each. Slowing into his marks he
    /// never stands, so the follow is one track.
    @Test func aCameraKeyedJustAfterAnEasedWalkersMarksTracksHim() throws {
        let end = 191.0 / 24
        let times = [0, 2, 4, 6, end], cameraTimes = [0, 2.25, 4.25, 6.25, end]
        var scene = try shotScene(
            frames: 192,
            marks: cameraTimes.map { mark($0, at: Vec3(0, 1.8, 4 - 1.4 * $0)) },
            subject: ("person.man", times.map { ($0, Vec3(0, 0, -1.4 * $0)) }),
            aimed: true
        )
        scene.blocking[0].tracks[0].marks = scene.blocking[0].tracks[0].marks.map { mark in
            var mark = mark
            (mark.easeIn, mark.easeOut) = (0.25, 0.25)
            return mark
        }
        let legs = try legs(scene)
        #expect(legs.map(\.move) == [.track], "\(legs)")
    }

    /// Beside a man walking at 1.4 m/s, the camera steps 0.2 m further out in two frames and follows on from there.
    /// Beside a walker that step is no move of its own, and too short for a snap: the shot is one track.
    @Test func aStepAsideBesideAWalkerIsNoMove() throws {
        let step = 1.5 + 2.0 / 24
        let marks = [
            mark(0, at: Vec3(4, 1.6, 0)), mark(1.5, at: Vec3(4, 1.6, -2.1)),
            mark(step, at: Vec3(4.2, 1.6, -1.4 * step)), mark(3, at: Vec3(4.2, 1.6, -4.2)),
        ]
        let scene = try shotScene(
            frames: 73, marks: marks, subject: ("person.man", [(0, .zero), (3, Vec3(0, 0, -4.2))]), aimed: true
        )
        let legs = try legs(scene)
        #expect(legs.map(\.move) == [.track], "\(legs)")
    }

    /// The camera passes 3 m straight over a man standing still, crossing him at frame 30, in the middle of the piece
    /// 24-36: a push, then a pull, with nothing in between.
    @Test func aPassStraightOverAStandingManIsAPushThenAPull() throws {
        let scene = try shotScene(
            frames: 73,
            marks: [mark(0, at: Vec3(-5, 3, 0)), mark(3, at: Vec3(7, 3, 0))],
            subject: ("person.man", [(0, .zero)]),
            aimed: true
        )
        let legs = try legs(scene)
        #expect(legs.map(\.move) == [.push, .pull], "\(legs)")
    }

    /// Between two marks, curved by three waypoints, the camera goes all the way round a man walking slowly and ends
    /// where it started, 4 m behind him. The way round says orbit, though the offset ends where it began.
    @Test func aFullTurnRoundAWalkerIsAnOrbit() throws {
        var marks = [mark(0, at: Vec3(0, 1.6, 4)), mark(3, at: Vec3(0, 1.6, 2.5))]
        marks[1].via = [Vec3(4, 1.6, -0.375), Vec3(0, 1.6, -4.75), Vec3(-4, 1.6, -1.125)]
        let scene = try shotScene(
            frames: 73, marks: marks, subject: ("person.man", [(0, .zero), (3, Vec3(0, 0, -1.5))]), aimed: true
        )
        let legs = try legs(scene)
        #expect(legs.map(\.move) == [.orbitLeft], "\(legs)")
    }

    /// A jump between two marks at the same time is a cut wherever it falls: up onto a camera that then stays put and
    /// tilts up as the man walks off, at a time between frames, and sideways in the middle of a free push.
    @Test func aJumpIsNoMoveWhereverItFalls() throws {
        let walker: (asset: String, path: [(time: Double, at: Vec3)]) = (
            "person.man", [(0, .zero), (3, Vec3(0, 0, -6))]
        )
        let ontoAHold = try shotScene(
            frames: 73,
            marks: [mark(0, at: Vec3(0, 1.6, 6)), mark(2, at: Vec3(0, 1.6, 2)), mark(2, at: Vec3(0, 4, -2))],
            subject: walker, aimed: true
        )
        let ontoAHoldLegs = try legs(ontoAHold)
        #expect(ontoAHoldLegs.map(\.move) == [.track, .tiltUp], "\(ontoAHoldLegs)")
        let betweenFrames = try shotScene(
            frames: 73,
            marks: [
                mark(0, at: Vec3(0, 1.6, 6)), mark(1.48, at: Vec3(0, 1.6, 3.04)),
                mark(1.48, at: Vec3(0, 1.6, -0.96)), mark(3, at: Vec3(0, 1.6, -4)),
            ],
            subject: walker, aimed: true
        )
        let betweenFramesLegs = try legs(betweenFrames)
        #expect(betweenFramesLegs.map(\.move) == [.track], "\(betweenFramesLegs)")
        // Pushing 1 m in all: medium, where the 3 m jump counted in would make it large.
        let sideways = try shotScene(
            frames: 73,
            marks: [
                mark(0, at: Vec3(0, 1.6, 6)), mark(1.5, at: Vec3(0, 1.6, 5.5)), mark(1.5, at: Vec3(3, 1.6, 5.5)),
                mark(3, at: Vec3(3, 1.6, 5)),
            ]
        )
        let sidewaysLegs = try legs(sideways)
        #expect(sidewaysLegs.map(\.move) == [.push] && sidewaysLegs.first?.amplitude == .medium, "\(sidewaysLegs)")
    }

    private func legs(_ scene: PrevisScene) throws -> [PromptFacts.CameraLeg] {
        try ShotPromptCompiler.facts(scene: scene, shotID: scene.shots[0].id, catalog: ContentCatalog.bundled())
            .cameraLegs
    }
}
