import Foundation
@testable import PrevisCore
import Testing

/// Blockout's own preset tests, ported for the presets this package implements. The reference is
/// https://github.com/wassermanproductions/blockout at 3f2d0564fd575f70fc28e9bfaa7e94b05e3955d9:
/// `tests/unit/action-presets.test.ts` (the universal contract on a ground and an airborne start, plus the targeted
/// behaviours) and `tests/unit/camera-moves.test.ts` (the universal contract on a walking subject, plus the targeted
/// behaviours). Unlike the golden vectors these state properties, so they also guard anything a vector would miss.
struct ReferenceGeneratorTests {
    private let catalog: ContentCatalog
    private let duration = 8.0

    init() throws {
        catalog = try ContentCatalog.bundled()
    }

    // MARK: Action presets

    private func action(_ id: String, airborne: Bool = false) throws -> [ActionSpec] {
        let start = ActionStart(position: Vec3(0, airborne ? 12 : 0, 0), heading: 0)
        return try #require(ActionPresets.generate(id, start: start, duration: duration), "no generator for \(id)")
    }

    @Test(arguments: [false, true])
    func everyActionPresetKeepsTheUniversalContract(airborne: Bool) throws {
        for id in [
            "plane-takeoff",
            "plane-landing",
            "plane-flyby",
            "plane-banked-circle",
            "plane-crash-dive",
            "heli-orbit",
            "bird-circle-soar",
            "bird-swoop",
            "walk-forward",
            "run-forward",
            "walk-up-stairs",
            "jump-forward",
            "door-burst-run",
            "horse-gallop-loop",
        ] {
            let marks = try action(id, airborne: airborne)
            let label = "\(id) [\(airborne ? "airborne" : "ground")]"
            #expect(marks.count >= 5, "\(label): at least 5 marks")
            #expect(abs(marks[0].time) < 1e-9, "\(label): first mark at t = 0")
            #expect(marks[0].position == Vec3(0, airborne ? 12 : 0, 0), "\(label): first mark exactly at the start")
            #expect(abs((marks.last?.time ?? 0) - duration) < 1e-6, "\(label): last mark at the duration")
            #expect(zip(marks, marks.dropFirst()).allSatisfy { $0.time < $1.time }, "\(label): times strictly increase")
            let finite = marks
                .allSatisfy { mark in [mark.position.x, mark.position.y, mark.position.z].allSatisfy(\.isFinite) }
            #expect(finite, "\(label): finite")
            #expect(marks.allSatisfy { $0.position.y >= 0 }, "\(label): y never below the ground")
            #expect(marks.allSatisfy { $0.easeIn >= 0 && $0.easeOut >= 0 && $0.hold >= 0 }, "\(label): ease and hold")
            #expect(marks.allSatisfy { [.walk, .jog, .run, .stand].contains($0.gait) }, "\(label): gait")
        }
    }

    /// Forward distance for heading 0 is −z.
    private func forward(_ mark: ActionSpec) -> Double {
        -mark.position.z
    }

    @Test func planeTakeoffEndsHighAndFar() throws {
        let last = try #require(action("plane-takeoff").last)
        #expect(last.position.y >= 10 && forward(last) >= 25)
    }

    @Test func planeLandingFromTheAirEndsStoppedOnTheGround() throws {
        let last = try #require(action("plane-landing", airborne: true).last)
        #expect(abs(last.position.y) < 1e-6 && last.gait == .stand)
    }

    @Test func birdsStayAboveTheGroundOnceAirborne() throws {
        for id in ["bird-circle-soar", "bird-swoop"] {
            // the pinned first mark sits exactly at the start, on the ground
            #expect(try action(id).dropFirst().allSatisfy { $0.position.y >= 0.3 }, "\(id)")
        }
    }

    @Test func aFlybyClampsUpToASafeAltitudeFromALowStart() throws {
        #expect(try action("plane-flyby").dropFirst().allSatisfy { $0.position.y >= 8 })
    }

    @Test func theLoopsReturnNearTheirStart() throws {
        for (id, airborne) in [("plane-banked-circle", true), ("horse-gallop-loop", false)] {
            let marks = try action(id, airborne: airborne)
            let first = marks[0].position, last = try #require(marks.last).position
            #expect(hypot(last.x - first.x, last.z - first.z) < 4, "\(id)")
        }
    }

    @Test func walkingUpStairsClimbsMonotonicallyAndEndsStoppedAtTheTop() throws {
        let marks = try action("walk-up-stairs")
        let last = try #require(marks.last)
        #expect((1.2 ... 1.6).contains(last.position.y) && last.gait == .stand)
        #expect(zip(marks, marks.dropFirst()).allSatisfy { $1.position.y >= $0.position.y - 1e-9 })
    }

    @Test func runAndWalkForwardCoverTheirDistancesAtTheirGaits() throws {
        let run = try action("run-forward")
        #expect(try forward(#require(run.last)) >= 30 && run.allSatisfy { $0.gait == .run })
        let walk = try action("walk-forward")
        let metres = try forward(#require(walk.last))
        #expect(metres > 9 && metres < 13 && walk.allSatisfy { $0.gait == .walk })
    }

    @Test func jumpForwardArcsUpAndLandsStopped() throws {
        let marks = try action("jump-forward")
        #expect((marks.map(\.position.y).max() ?? 0) > 0.3)
        let last = try #require(marks.last)
        #expect(abs(last.position.y) < 1e-6 && last.gait == .stand && forward(last) > 3)
    }

    // MARK: Camera moves

    private func context() -> CameraMoveContext {
        CameraMoveContext(
            subjectAt: { SubjectSample(x: 0, y: 0, z: -2 * $0, heading: 0) },
            subjectHeight: 1.75,
            camera: CameraStart(position: Vec3(0, 1.6, 6), pan: 0, tilt: 0, focalLength: 35),
            duration: duration
        )
    }

    private func move(_ id: String) throws -> [CameraSpec] {
        try #require(CameraMovePresets.generate(id, context()), "no generator for \(id)")
    }

    @Test func everyCameraMoveKeepsTheUniversalContract() throws {
        for id in try catalog.starter.cameraMoves {
            let marks = try move(id)
            #expect(marks.count >= 5, "\(id): at least 5 marks")
            #expect(
                abs(marks[0].time) < 1e-6 && abs((marks.last?.time ?? 0) - duration) < 1e-6,
                "\(id): spans the shot"
            )
            #expect(zip(marks, marks.dropFirst()).allSatisfy { $0.time < $1.time }, "\(id): times strictly increase")
            let numbers = marks.flatMap { [$0.position.x, $0.position.y, $0.position.z, $0.pan, $0.tilt, $0.roll] }
            let finite = numbers.allSatisfy(\.isFinite)
            #expect(finite, "\(id): finite")
            #expect(marks.allSatisfy { (8 ... 300).contains($0.focalLength) }, "\(id): lens within 8 to 300 mm")
            #expect(marks.first?.easeIn == 0.25 && marks.last?.easeOut == 0.25, "\(id): edge marks eased")
            #expect(
                marks.dropFirst().dropLast().allSatisfy { $0.easeIn == 0 && $0.easeOut == 0 },
                "\(id): interior not"
            )
            #expect(marks.allSatisfy { $0.hold == 0 }, "\(id): no holds")
        }
    }

    @Test func followBehindStaysAboutFourMetresFromTheSubjectAndMovesWithIt() throws {
        let marks = try move("follow-behind")
        for mark in marks {
            let subject = context().subjectAt(mark.time)
            let planar = hypot(mark.position.x - subject.x, mark.position.z - subject.z)
            #expect(planar > 3 && planar < 5, "\(planar)")
        }
        #expect(try #require(marks.last).position.z < marks[0].position.z)
    }

    @Test func vertigoDollyZoomNarrowsTheLensStrictlyAndEndsBelowThreeQuartersOfTheStart() throws {
        let marks = try move("vertigo-dolly-zoom")
        #expect(zip(marks, marks.dropFirst()).allSatisfy { $1.focalLength < $0.focalLength })
        #expect(try #require(marks.last).focalLength < marks[0].focalLength * 0.75)
    }

    @Test func aWhipPanTurnsAtLeastOnePointTwoRadiansWithinASecond() throws {
        let marks = try move("whip-pan")
        let found = zip(marks, marks.dropFirst()).contains { abs($1.pan - $0.pan) >= 1.2 && $1.time - $0.time <= 1 }
        #expect(found)
    }

    @Test func spiralInDescendTightensAndDropsTowardTheSubject() throws {
        let marks = try move("spiral-in-descend")
        let (first, last) = try (marks[0], #require(marks.last))
        let sFirst = context().subjectAt(first.time), sLast = context().subjectAt(last.time)
        let planarFirst = hypot(first.position.x - sFirst.x, first.position.z - sFirst.z)
        let planarLast = hypot(last.position.x - sLast.x, last.position.z - sLast.z)
        #expect(planarLast < planarFirst && last.position.y < first.position.y)
    }
}
