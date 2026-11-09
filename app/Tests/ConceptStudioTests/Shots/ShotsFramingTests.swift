@testable import ConceptStudio
import PrevisCore
import Testing

/// The camera inspector's framing buttons, as Blockout frames (`SceneManager.ts` `autoFrame`, `framingSubjects`,
/// `writeCameraPose` at 3f2d0564).
@Suite("Shots framing")
@MainActor
struct ShotsFramingTests {
    private let man = "ent_000000000001"
    private let woman = "ent_000000000002"
    private let chair = "ent_000000000003"
    private let wall = "ent_000000000004"

    /// Close-up on the selected man, with aim lock off as in the sample, shows his face in the camera view at the
    /// playhead: on a frame that already has a camera mark (0) and between marks (61).
    @Test(arguments: [0, 61])
    func closeUpOnTheSelectedManFramesHisHead(frame index: Int) throws {
        let store = try makeStore()
        var errors: [String] = []
        store.onError = { errors.append($0) }
        #expect(store.currentShot?.camera.trackIDs.isEmpty == true)
        store.selection = .entities([man])
        store.playhead = index
        store.applyFraming(.closeUp)
        #expect(errors.isEmpty, "\(errors)")

        let frame = try #require(store.frame)
        let size = frame.canvas.pixelSize
        let body = try #require(frame.entities.first { $0.id == man })
        let points = Dictionary(body.keypoints.map { ($0.name, $0.position) }) { first, _ in first }
        let nose = try #require(points[.nose]), neck = try #require(points[.neck])
        let rightEye = try #require(points[.rightEye]), leftEye = try #require(points[.leftEye])
        let rightHip = try #require(points[.rightHip]), leftHip = try #require(points[.leftHip])
        func pixel(_ point: Vec3) -> Point2? {
            frame.camera.project(point, size: size)
        }
        func inside(_ pixel: Point2?) -> Bool {
            guard let pixel else { return false }
            return (0 ..< Double(size.width)).contains(pixel.x) && (0 ..< Double(size.height)).contains(pixel.y)
        }
        for (label, point) in [("nose", nose), ("right eye", rightEye), ("left eye", leftEye), ("neck", neck)] {
            #expect(inside(pixel(point)), "frame \(index): \(label) at \(String(describing: pixel(point)))")
        }
        // The head, from the top of the body to the neck, fills most of the frame height.
        let top = Vec3(body.position.x, body.bounds.max.y, body.position.z)
        let headTop = try #require(pixel(top)), chin = try #require(pixel(neck))
        let share = abs(chin.y - headTop.y) / Double(size.height)
        #expect(share > 0.5, "frame \(index): the head fills \(share) of the frame height")
        // Chest and hips are below the frame.
        func between(_ a: Vec3, _ b: Vec3, _ u: Double) -> Vec3 {
            Vec3(a.x + (b.x - a.x) * u, a.y + (b.y - a.y) * u, a.z + (b.z - a.z) * u)
        }
        let hips = between(rightHip, leftHip, 0.5)
        let chest = between(neck, hips, 0.4)
        for (label, below) in [("chest", chest), ("hips", hips)] {
            let located = pixel(below)
            #expect(!inside(located), "frame \(index): \(label) at \(String(describing: located)) is in the frame")
        }
    }

    @Test func framingTakesItsSubjectsFromTheSelectionAndLeavesAimLockAlone() throws {
        var document = ShotsSamples.twoPersonWalk()
        document.scenes[0].shots[0].camera.trackIDs = [woman]
        let store = try ShotsStore(catalog: ContentCatalog.bundled(), document: document, saveURL: nil)
        store.selection = .entities([man])
        store.playhead = 61
        store.applyFraming(.closeUp)
        let shot = try #require(store.currentShot)
        #expect(shot.camera.trackIDs == [woman])
        let mark = try #require(shot.camera.marks.first { FrameGrid.frame(atTime: $0.time) == 61 })
        let frame = try #require(store.frame)
        let manAt = try #require(frame.entities.first { $0.id == man }).position
        let womanAt = try #require(frame.entities.first { $0.id == woman }).position
        func flat(_ a: Vec3, _ b: Vec3) -> Double {
            ((a.x - b.x) * (a.x - b.x) + (a.z - b.z) * (a.z - b.z)).squareRoot()
        }
        #expect(flat(mark.position, manAt) < 0.6, "the close-up stands by the selected man")
        #expect(flat(mark.position, womanAt) > 0.6)
    }

    @Test func subjectsFollowBlockoutsRules() throws {
        let scene = try #require(ShotsSamples.twoPersonWalk().scenes.first)
        func subjects(_ kind: Framing.Kind, _ selection: ShotsSelection) -> [EntityID] {
            ShotsFramingSubjects.subjects(for: kind, in: scene, selection: selection)
        }
        // Shot sizes: exactly one selected, else the first person.
        #expect(subjects(.closeUp, .entities([woman])) == [woman])
        #expect(subjects(.wide, .entities([chair])) == [chair])
        #expect(subjects(.medium, .none) == [man])
        #expect(subjects(.full, .camera) == [man])
        #expect(subjects(.closeUp, .entities([chair, woman])) == [man])
        // The others: two or more selected in document order, else every person.
        #expect(subjects(.twoShot, .entities([chair, woman])) == [woman, chair])
        #expect(subjects(.low, .entities([woman])) == [man, woman])
        #expect(subjects(.top, .none) == [man, woman])
        // No people: the first entity, or the first two.
        var props = scene
        props.entities.removeAll { $0.assetID.hasPrefix("person.") }
        #expect(ShotsFramingSubjects.subjects(for: .closeUp, in: props, selection: .none) == [chair])
        #expect(ShotsFramingSubjects.subjects(for: .reverse, in: props, selection: .none) == [chair, wall])
        props.entities = []
        #expect(ShotsFramingSubjects.subjects(for: .closeUp, in: props, selection: .none).isEmpty)
    }

    @Test func aFramingOnAMarksFrameRewritesThatMarkAndBetweenMarksAddsOne() throws {
        let store = try makeStore()
        let before = try #require(store.currentShot?.camera.marks)
        store.selection = .entities([man])
        store.playhead = 0
        store.applyFraming(.medium)
        var marks = try #require(store.currentShot?.camera.marks)
        #expect(marks.count == before.count)
        #expect(marks.map(\.id) == before.map(\.id))
        #expect(marks[0].time == before[0].time && marks[0].position != before[0].position)
        #expect(marks[1] == before[1])

        store.applyFraming(.dutch)
        let dutch = try #require(store.currentShot?.camera.marks)
        #expect(dutch[0].roll == 0.35)
        #expect(dutch[0].position == marks[0].position && dutch[0].pan == marks[0].pan)

        store.playhead = 61
        store.applyFraming(.medium)
        marks = try #require(store.currentShot?.camera.marks)
        #expect(marks.count == before.count + 1)
        #expect(marks.map(\.time) == marks.map(\.time).sorted())
        #expect(marks.contains { FrameGrid.frame(atTime: $0.time) == 61 })
    }

    private func makeStore() throws -> ShotsStore {
        try ShotsStore(catalog: ContentCatalog.bundled(), document: ShotsSamples.twoPersonWalk(), saveURL: nil)
    }
}
