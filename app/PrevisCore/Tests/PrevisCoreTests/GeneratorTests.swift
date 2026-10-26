import Foundation
@testable import PrevisCore
import Testing

/// Behaviour of the A4 helpers on the two-person sample: motions, framing and attachments.
struct GeneratorTests {
    private let catalog: ContentCatalog
    private let scene: PrevisScene
    private let shotID: ShotID
    private let man: PrevisEntity
    private let woman: PrevisEntity

    init() throws {
        catalog = try ContentCatalog.bundled()
        scene = try #require(ShotsSamples.twoPersonWalk().scenes.first)
        shotID = try #require(scene.shots.first).id
        man = try #require(scene.entities.first { $0.name == "Man" })
        woman = try #require(scene.entities.first { $0.name == "Woman" })
    }

    private func frame(of scene: PrevisScene, _ index: Int) throws -> SceneFrame {
        try ShotEvaluator(scene: scene, shotID: shotID, catalog: catalog).frame(index)
    }

    private func entity(_ id: EntityID, in frame: SceneFrame) throws -> EntityFrame {
        try #require(frame.entities.first { $0.id == id })
    }

    // MARK: Motions

    @Test func applyingAMotionLaysItsKeyframesDownAtTheEntitysPose() throws {
        let wave = try #require(catalog.motion("wave"))
        let track = try Motions.apply("wave", to: man, track: nil, at: 1, catalog: catalog)
        #expect(track.entityID == man.id && track.marks.count == wave.keyframes.count)
        #expect(zip(track.marks, wave.keyframes)
            .allSatisfy { abs($0.time - (1 + $1.t)) < 1e-12 && $0.joints == $1.joints })
        #expect(track.marks.allSatisfy { $0.position == man.placement.position && $0.gait == .stand })
        #expect(Set(track.marks.map(\.id)).count == track.marks.count)
    }

    @Test func aMotionDroppedIntoATrackKeepsTheMarksBeforeItAndReplacesTheRest() throws {
        let existing = try #require(scene.blocking.first?.tracks.first { $0.entityID == man.id })
        let result = try Motions.apply("nod-yes", to: man, track: existing, at: 2, catalog: catalog)
        let before = existing.marks.filter { $0.time < 2 }
        #expect(!before.isEmpty && Array(result.marks.prefix(before.count)) == before)
        #expect(result.marks.dropFirst(before.count).allSatisfy { $0.time >= 2 })
        // it starts where the man is then, not at his placement
        let start = try #require(result.marks.dropFirst(before.count).first)
        #expect(start.position.x > man.placement.position.x)
    }

    @Test func aRootMoveShiftsAKeyframeForwardAndUp() throws {
        let hop = try #require(catalog.motions.first { $0.keyframes.contains { ($0.move?.up ?? 0) > 0 } })
        let marks = try Motions.apply(hop.id, to: man, track: nil, at: 0, catalog: catalog).marks
        let top = try #require(zip(marks, hop.keyframes).max { ($0.1.move?.up ?? 0) < ($1.1.move?.up ?? 0) })
        #expect(abs(top.0.position.y - (top.1.move?.up ?? 0)) < 1e-12)
    }

    @Test func onlyPeopleCanPlayAMotionAndUnknownOnesFail() throws {
        let chair = try #require(scene.entities.first { $0.name == "Chair" })
        #expect(throws: ShotsError.self) { try Motions.apply("wave", to: chair, track: nil, at: 0, catalog: catalog) }
        #expect(throws: ShotsError.self) { try Motions.apply(
            "no-such-motion",
            to: man,
            track: nil,
            at: 0,
            catalog: catalog
        ) }
        #expect(throws: ShotsError.self) { try Motions.apply("wave", to: man, track: nil, at: -1, catalog: catalog) }
    }

    @Test func overlayingAWaveOnAWalkKeepsThePositionsAndTheLegsAndSetsTheArm() throws {
        let walk = try ActionPaths.marks(
            "walk-forward",
            entity: man,
            startTime: 0,
            duration: 6,
            speed: nil,
            catalog: catalog
        )
        var legged = walk
        legged[2].joints = [.kneeL: 0.4, .hipRX: 0.2]
        let result = try Motions.overlay("wave", onto: Track(entityID: man.id, marks: legged), catalog: catalog)

        #expect(result.marks.map(\.position) == legged.map(\.position))
        #expect(result.marks.map(\.time) == legged.map(\.time) && result.marks.map(\.gait) == legged.map(\.gait))
        #expect(result.marks[2].joints[.kneeL] == 0.4 && result.marks[2].joints[.hipRX] == 0.2)

        let wave = try #require(catalog.motion("wave"))
        for mark in result.marks {
            let expected = Motions.sample(wave, at: mark.time - (walk.first?.time ?? 0))
            for (joint, value) in expected {
                #expect(abs((mark.joints[joint] ?? .nan) - value) < 1e-12, "\(joint)")
            }
        }
        // the right arm is raised at some mark: shoulderRX follows the wave's -2.3
        #expect(result.marks.contains { ($0.joints[.shoulderRX] ?? 0) < -2 })
    }

    @Test func overlayRefusesMotionsThatMoveTheLegs() throws {
        let walk = try ActionPaths.marks(
            "walk-forward",
            entity: man,
            startTime: 0,
            duration: 4,
            speed: nil,
            catalog: catalog
        )
        #expect(throws: ShotsError.self) {
            try Motions.overlay("front-kick", onto: Track(entityID: man.id, marks: walk), catalog: catalog)
        }
    }

    // MARK: Framing

    private func framed(_ kind: Framing.Kind, subjects: [PrevisEntity]? = nil, in base: PrevisScene? = nil) throws
        -> (scene: PrevisScene, mark: CameraMark) {
        var scene = base ?? scene
        let mark = try Framing.cameraMark(
            kind,
            scene: scene,
            shotID: shotID,
            subjects: (subjects ?? [man, woman]).map(\.id),
            atFrame: 61,
            catalog: catalog
        )
        scene.shots[0].camera.marks = [mark]
        scene.shots[0].camera.trackIDs = []
        return (scene, mark)
    }

    /// Where a subject's head is in the canvas: nil behind the camera.
    private func head(of id: EntityID, in frame: SceneFrame) throws -> Point2? {
        let body = try entity(id, in: frame)
        return frame.camera.project(body.position + Vec3(0, 1.5, 0), size: frame.canvas.pixelSize)
    }

    @Test(arguments: Framing.Kind.allCases)
    func everyKindKeepsTheSubjectsItIsAboutInsideTheCanvas(kind: Framing.Kind) throws {
        let (framedScene, mark) = try framed(kind)
        #expect(mark.focalLength == 20)
        let frame = try frame(of: framedScene, 61)
        let size = frame.canvas.pixelSize
        // The subjects each kind frames: the primary alone for sizes, low and dutch; both for the others. Over the
        // shoulder frames the far subject (the second person is nearer the camera in the sample).
        let expected: [EntityID] = switch kind {
        case .wide, .full, .medium, .closeUp, .low, .dutch: [man.id]
        case .overShoulder: [woman.id]
        default: [man.id, woman.id]
        }
        for id in expected {
            let located = try head(of: id, in: frame)
            let pixel = try #require(located, "\(kind): \(id) is behind the camera")
            #expect(
                (0 ..< Double(size.width)).contains(pixel.x) && (0 ..< Double(size.height)).contains(pixel.y),
                "\(kind): \(id) head at \(pixel)"
            )
        }
    }

    @Test func shotSizesFillMoreOfTheFrameAsTheyTighten() throws {
        func headHeight(_ kind: Framing.Kind) throws -> Double {
            let (framedScene, _) = try framed(kind, subjects: [man])
            let frame = try frame(of: framedScene, 61)
            let body = try entity(man.id, in: frame)
            let top = try #require(frame.camera.project(body.position + Vec3(0, 1.78, 0), size: frame.canvas.pixelSize))
            let bottom = try #require(frame.camera.project(body.position, size: frame.canvas.pixelSize))
            return abs(bottom.y - top.y) / Double(frame.canvas.height)
        }
        let wide = try headHeight(.wide), full = try headHeight(.full)
        #expect(wide > 0.5 && wide < 0.8 && full > 0.8 && full <= 1.0, "wide \(wide), full \(full)")
    }

    @Test func aShotSizeTiltsTowardTheMiddleOfWhatItFrames() throws {
        // Blockout set the camera to the target height, so every shot-size mark had tilt 0.
        let wide = try framed(.wide, subjects: [man]).mark
        #expect(wide.tilt < -0.05, "a wide shot from eye height looks down at the middle of the figure: \(wide.tilt)")
    }

    @Test func aTwoShotBacksOffFurtherOnAPortraitCanvasThanOnALandscapeOne() throws {
        func distance(canvas: ShotCanvas) throws -> Double {
            var scene = scene
            scene.shots[0].canvas = canvas
            let mark = try Framing.cameraMark(
                .twoShot, scene: scene, shotID: shotID, subjects: [man.id, woman.id], atFrame: 61, catalog: catalog
            )
            let mid = try frame(of: scene, 61).entities.prefix(2).reduce(Vec3.zero) { $0 + $1.position } * 0.5
            return (mark.position - Vec3(mid.x, mark.position.y, mid.z)).length
        }
        let portrait = try distance(canvas: .portrait)
        let landscape = try distance(canvas: ShotCanvas(width: 1152, height: 640))
        #expect(portrait > landscape * 1.3, "portrait \(portrait) m, landscape \(landscape) m")
    }

    @Test func dutchCyclesTheHorizonAndBadRequestsFail() throws {
        let level = try framed(.dutch).mark
        #expect(level.roll == 0.35)
        var tilted = scene
        tilted.shots[0].camera.marks = [level]
        let next = try Framing.cameraMark(
            .dutch,
            scene: tilted,
            shotID: shotID,
            subjects: [man.id],
            atFrame: 0,
            catalog: catalog
        )
        #expect(next.roll == -0.35)
        #expect(throws: ShotsError.self) {
            try Framing.cameraMark(
                .twoShot,
                scene: scene,
                shotID: shotID,
                subjects: [man.id],
                atFrame: 0,
                catalog: catalog
            )
        }
        #expect(throws: ShotsError.self) {
            try Framing.cameraMark(.wide, scene: scene, shotID: shotID, subjects: [], atFrame: 0, catalog: catalog)
        }
        #expect(throws: ShotsError.self) {
            try Framing.cameraMark(
                .wide,
                scene: scene,
                shotID: shotID,
                subjects: ["ghost"],
                atFrame: 0,
                catalog: catalog
            )
        }
    }

    // MARK: Attachments

    @Test func anAttachmentKeepsTheChildWhereItStandsAndThenRidesTheParent() throws {
        let chair = try #require(scene.entities.first { $0.name == "Chair" })
        let attachment = try Attachments.attachment(
            child: chair.id, parent: man.id, scene: scene, shotID: shotID, atFrame: 20, catalog: catalog
        )
        #expect(attachment.parentID == man.id)
        var attached = scene
        try attached.entities[#require(attached.entities.firstIndex { $0.id == chair.id })].attachment = attachment

        let before = try entity(chair.id, in: frame(of: scene, 20))
        let after = try entity(chair.id, in: frame(of: attached, 20))
        #expect((before.position - after.position).length < 1e-9 && abs(before.heading - after.heading) < 1e-9)

        // later it has moved with the man by the same amount
        let manThen = try entity(man.id, in: frame(of: attached, 20)).position
        let manLater = try entity(man.id, in: frame(of: attached, 60)).position
        let chairLater = try entity(chair.id, in: frame(of: attached, 60)).position
        #expect(((chairLater - after.position) - (manLater - manThen)).length < 1e-9)
    }

    @Test func detachingKeepsTheChildWhereItStandsWithItsOwnScale() throws {
        let chair = try #require(scene.entities.first { $0.name == "Chair" })
        let attachment = try Attachments.attachment(
            child: chair.id, parent: man.id, scene: scene, shotID: shotID, atFrame: 20, catalog: catalog
        )
        var attached = scene
        let index = try #require(attached.entities.firstIndex { $0.id == chair.id })
        attached.entities[index].attachment = attachment
        attached.entities[index].placement.scale = 1.5
        let placement = try Attachments.placementWhenDetached(
            child: chair.id, scene: attached, shotID: shotID, atFrame: 60, catalog: catalog
        )
        let standing = try entity(chair.id, in: frame(of: attached, 60))
        #expect((placement.position - standing.position).length < 1e-12 && placement.heading == standing.heading)
        #expect(placement.scale == 1.5)
    }

    @Test func anAttachmentCycleIsAnErrorThatNamesBothEntities() throws {
        let chair = try #require(scene.entities.first { $0.name == "Chair" })
        var riding = scene
        let index = try #require(riding.entities.firstIndex { $0.id == man.id })
        riding.entities[index].attachment = EntityAttachment(parentID: chair.id, offset: .zero, rotation: .identity)
        do {
            _ = try Attachments.attachment(
                child: chair.id, parent: man.id, scene: riding, shotID: shotID, atFrame: 0, catalog: catalog
            )
            Issue.record("expected a cycle error")
        } catch let error as ShotsError {
            let text = error.errorDescription ?? ""
            #expect(text.contains("Man") && text.contains("Chair") && text.contains("cycle"), "\(text)")
        }
        #expect(throws: ShotsError.self) {
            try Attachments.attachment(
                child: man.id, parent: man.id, scene: scene, shotID: shotID, atFrame: 0, catalog: catalog
            )
        }
    }
}
