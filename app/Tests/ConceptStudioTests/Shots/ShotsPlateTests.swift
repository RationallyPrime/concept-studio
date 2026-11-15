@testable import ConceptStudio
import Foundation
import PrevisCore
import ShotsMedia
import Testing

/// Blocking over a plate in the app: the plate commands, the match screen's model, pointer blocking in the
/// shot-camera view, and blocking from a description.
@Suite("Shots over a plate")
@MainActor
struct ShotsPlateTests {
    private let woman = "ent_000000000111", man = "ent_000000000112"

    private func plateStore() throws -> ShotsStore {
        try ShotsStore(catalog: ContentCatalog.bundled(), document: ShotsSamples.plateStaging(), saveURL: nil)
    }

    private func match(height: Double) -> PlateMatch {
        PlateMatch(position: Vec3(0, height, 0), pan: 0.1, tilt: -0.2, roll: 0, focalLength: 40, sensor: .fullFrame)
    }

    @Test func blockingAShotOverAPlatePutsItOnThePlatesCameraAndAMatchMovesEveryShotOnIt() throws {
        let store = try ShotsStore(
            catalog: ContentCatalog.bundled(),
            document: ShotsSamples.twoPersonWalk(),
            saveURL: nil
        )
        let scene = try #require(store.currentScene), shot = try #require(store.currentShot)
        let plate = LocationPlate(
            id: "plate_a", name: "Hall A", file: "plate_a.png", size: PixelSize(width: 1440, height: 2560),
            match: match(height: 1.5), guides: .none
        )
        try store.perform([.addPlate(scene.id, plate), .setShotPlate(shot.id, plate.id)])
        try store.perform(.duplicateShot(shot.id, newID: "shot_second"))
        var onPlate = try #require(store.currentScene?.shots.first { $0.id == shot.id })
        #expect(onPlate.plateID == "plate_a")
        #expect(onPlate.canvas == ShotCanvas(width: 576, height: 1024))
        #expect(onPlate.camera.sensor == .fullFrame)
        #expect(onPlate.camera.marks[0].position == Vec3(0, 1.5, 0) && onPlate.camera.marks[0].focalLength == 40)
        // The sample's second camera mark, its push-in, is kept: only the first frame is the plate's.
        #expect(onPlate.camera.marks.count == 2)

        var corrected = plate
        corrected.match = match(height: 1.72)
        try store.perform(.updatePlate(scene.id, corrected))
        for id in [shot.id, "shot_second"] {
            onPlate = try #require(store.currentScene?.shots.first { $0.id == id })
            #expect(onPlate.camera.marks[0].position.y == 1.72)
        }
        try store.perform(.deletePlate(scene.id, "plate_a"))
        #expect(store.currentScene?.shots.allSatisfy { $0.plateID == nil } == true)
        store.undo()
        #expect(store.currentScene?.plates.count == 1)
    }

    @Test func aSetPieceFromTheLibraryStartsInViewSquareToTheSetAndAsTheplatesOwn() throws {
        let store = try plateStore()
        let scene = try #require(store.currentScene)
        let id = try store.addLibraryAsset("set.bench")
        let bench = try #require(store.currentScene?.entities.first { $0.id == id })
        #expect(bench.setPiece == SetPiece.standard(.bench, inPlate: true))
        // Four metres in front of the plate's camera at the origin, turned a quarter turn at a time to face it.
        #expect(abs(bench.placement.position.z - -4) < 1e-9 && abs(bench.placement.position.x) < 1e-9)
        #expect(abs(abs(bench.placement.heading) - .pi) < 1e-9)
        var wider = try #require(bench.setPiece)
        wider.size.x = 3
        wider.kind = .wall // the kind is the asset's and stays
        try store.perform(.setSetPiece(id, wider))
        let changed = try #require(store.currentScene?.entities.first { $0.id == id }?.setPiece)
        #expect(changed.size.x == 3 && changed.kind == .bench)
        #expect(scene.plates.count == 1)
    }

    @Test func deletingACharacterRemovesWhatTheShotAskedOfThem() throws {
        let store = try plateStore()
        let shot = try #require(store.currentShot)
        try store.perform(.setAsks(shot.id, [
            FramingAsk(entityID: woman, extent: .headToBoots), FramingAsk(entityID: man, extent: .face),
        ]))
        #expect(store.problems.contains { $0.message.contains("from head to boots") })
        try store.perform(.deleteEntities([woman]))
        #expect(store.currentShot?.asks == [FramingAsk(entityID: man, extent: .face)])
    }

    @Test func aPlateIsCopiedIntoTheProjectByteForByte() throws {
        let project = FileManager.default.temporaryDirectory
            .appendingPathComponent("shots-plates-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: project) }
        // A 2 × 3 PNG.
        let png = try #require(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAIAAAADCAIAAAA2iEnWAAAAEklEQVR4nGP4z8DAAMIM/xkYAA/9Av5dW9JlAAAAAElFTkSuQmCC"))
        let source = project.appendingPathComponent("Throne staging.png")
        try png.write(to: source)
        let plate = try ShotsPlateFiles.importPlate(from: source, intoProject: project, id: "plate_x")
        #expect(plate.name == "Throne staging" && plate.file == "plate_x.png")
        #expect(plate.size == PixelSize(width: 2, height: 3) && plate.match == nil)
        let copied = try Data(contentsOf: PlateImages.folder(inProject: project).appendingPathComponent(plate.file))
        #expect(copied == png)
    }

    @Test func aRaisedFloorLiftsTheCameraWithoutMovingThePictureAndTwoQuarterTurnsMakeAReverse() throws {
        let plate = try #require(ShotsSamples.plateStaging().scenes[0].plates.first)
        var model = PlateMatchModel(plate: plate)
        let before = model.solved
        let feet = try #require(model.position(of: .figure))
        model.floorLevel = 0.6
        model.solve()
        #expect(abs(model.solved.position.y - (before.position.y + 0.6)) < 1e-9)
        // The height field is still told from the floor the plate shows, and the figure still stands on it.
        #expect(abs(model.height - before.position.y) < 1e-9)
        let raised = try #require(model.position(of: .figure))
        #expect(abs(raised.x - feet.x) < 1e-9 && abs(raised.y - feet.y) < 1e-9)
        #expect(model.result(for: plate).guides.floorLevel == 0.6)

        model.turnQuarter()
        model.turnQuarter()
        #expect(abs(cos(model.solved.pan - before.pan) + 1) < 1e-9)
        #expect(model.position(of: .figure) != nil)
    }

    @Test func theMatchScreenSolvesAsHandlesMoveAndSavesWhatWasDrawn() throws {
        let plate = try #require(ShotsSamples.plateStaging().scenes[0].plates.first)
        var model = PlateMatchModel(plate: plate)
        // Opened on a matched plate with no lines, the fields are the match.
        #expect(model.solved == plate.match && model.problem == nil)
        #expect(!model.usesLinesA && abs(model.tiltDegrees - -0.1 * 180 / .pi) < 1e-9)
        model.height = 2
        model.solve()
        #expect(model.solved.position.y == 2)

        // Lines drawn where a known camera sees the floor's two directions give that camera back.
        // The camera is turned 0.4 rad off the set's axes, as a plate taken at an angle is.
        let truth = PlateMatch(
            position: Vec3(0, 1.4, 0),
            pan: 0,
            tilt: -0.25,
            roll: 0,
            focalLength: 32,
            sensor: .super35
        )
        let camera = truth.camera(aspect: plate.size.aspect)
        let turn = 0.4
        func turned(_ x: Double, _ z: Double) -> Vec3 {
            // About the rectangle's own middle, six metres in front of the camera.
            Vec3(x * cos(turn) + (z + 6) * sin(turn), 0, -6 - x * sin(turn) + (z + 6) * cos(turn))
        }
        func fraction(_ point: Vec3) throws -> Point2 {
            let pixel = try #require(camera.project(point, size: plate.size))
            return Point2(x: pixel.x / Double(plate.size.width), y: pixel.y / Double(plate.size.height))
        }
        model.usesLinesA = true
        model.usesLinesB = true
        model.lensFromLines = true
        // Corners of a floor rectangle the camera sees whole: 0.8 m wide and 2 m deep.
        let near = (left: turned(-0.4, -5), right: turned(0.4, -5)), far = (
            left: turned(-0.4, -7),
            right: turned(0.4, -7)
        )
        try model.move(.lineA(0, end: 0), to: fraction(near.left))
        try model.move(.lineA(0, end: 1), to: fraction(near.right))
        try model.move(.lineA(1, end: 0), to: fraction(far.left))
        try model.move(.lineA(1, end: 1), to: fraction(far.right))
        try model.move(.lineB(0, end: 0), to: fraction(near.left))
        try model.move(.lineB(0, end: 1), to: fraction(far.left))
        try model.move(.lineB(1, end: 0), to: fraction(near.right))
        try model.move(.lineB(1, end: 1), to: fraction(far.right))
        #expect(model.problem == nil && model.lensIsSolved)
        #expect(abs(model.solved.focalLength - 32) < 0.1 && abs(model.solved.tilt - -0.25) < 1e-3)
        // The world is turned so the grid runs along the set: the camera's turn is the set's angle.
        #expect(abs(abs(model.solved.pan) - turn) < 1e-3)
        let saved = model.result(for: plate)
        #expect(saved.match == model.solved && saved.guides.linesA.count == 2 && saved.guides.linesB.count == 2)

        // The reference figure follows the pointer along the floor.
        let spot = try fraction(Vec3(0.3, 0, -5))
        model.move(.figure, to: spot)
        let back = try #require(model.position(of: .figure))
        #expect(abs(back.x - spot.x) < 1e-6 && abs(back.y - spot.y) < 1e-6)
    }

    @Test func aClickInTheShotCameraSelectsAndADragSlidesAlongTheFloorAsOneStep() throws {
        let store = try plateStore()
        let frame = try #require(store.frame)
        let staged = try #require(StagingAnalysis.characters(in: frame).first { $0.entityID == woman })
        let box = try #require(staged.box)
        let on = Point2(x: box.x + box.width / 2, y: box.y + box.height / 2)
        var drag = ShotCameraFloorDrag()
        drag.handle(.down, at: on, in: store)
        drag.handle(.up, at: on, in: store)
        #expect(store.selection == .entities([woman]))

        let before = try #require(store.currentScene?.entities.first { $0.id == woman }).placement.position
        let to = Point2(x: on.x + 0.2, y: on.y)
        drag.handle(.down, at: on, in: store)
        drag.handle(.moved, at: Point2(x: on.x + 0.1, y: on.y), in: store)
        #expect(!store.preview.isEmpty && !store.canUndo)
        drag.handle(.moved, at: to, in: store)
        drag.handle(.up, at: to, in: store)
        let after = try #require(store.currentScene?.entities.first { $0.id == woman }).placement.position
        #expect(store.preview.isEmpty && store.canUndo)
        // Toward frame right is +X for this plate's camera; she stays on the floor, at her depth.
        #expect(after.x > before.x + 0.3 && after.y == before.y && abs(after.z - before.z) < 0.05)
        store.undo()
        #expect(store.currentScene?.entities.first { $0.id == woman }?.placement.position == before)
        #expect(!store.canUndo)

        // A click on the bare plate clears the selection.
        drag.handle(.down, at: Point2(x: 0.02, y: 0.02), in: store)
        drag.handle(.up, at: Point2(x: 0.02, y: 0.02), in: store)
        #expect(store.selection == .none)
    }

    @Test func rowsOfADescriptionBecomeShotsInOneUndoStep() async throws {
        let store = try plateStore()
        let sceneID = try #require(store.currentSceneID)
        let rows = ShotsBlocking.rows(in: """
        TS-02 medium. Woman frame left behind the Long table, facing Man. Man frame right behind the Long table.

        TS-03 Woman centred on the Dais, facing the camera.
        """)
        #expect(rows.count == 2)
        let outcomes = try await ShotsBlocking.block(rows: rows, sceneID: sceneID, in: store) { row, scene in
            BlockingReader.brief(from: row, scene: scene)
        }
        #expect(outcomes.map(\.shotName) == ["TS-02", "TS-03"])
        #expect(store.currentScene?.shots.map(\.name) == ["TS-01", "TS-02", "TS-03"])
        #expect(store.currentShot?.name == "TS-03")
        #expect(store.currentScene?.shots.allSatisfy { $0.plateID != nil } == true)
        store.undo()
        #expect(store.currentScene?.shots.map(\.name) == ["TS-01"])
        #expect(!store.canUndo)
    }

    @Test func theSavedFramingDocumentHasTheTableAndEachShotsStaging() throws {
        let scene = ShotsSamples.plateStaging().scenes[0]
        let text = try ShotsSceneBoard.document(for: scene, catalog: ContentCatalog.bundled())
        #expect(text.hasPrefix("# Throne room: framing table"))
        #expect(text.contains("| TS-01 | Hall C |") && text.contains("## TS-01"))
        #expect(text.contains("The blue stand-in is Woman."))
    }

    @Test func aDocumentWithPlatesAndSetPiecesSurvivesSavingAndLoading() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("shots-doc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("shots.json")
        var document = ShotsSamples.plateStaging()
        document.scenes[0].plates[0].guides = PlateGuides(
            linesA: [PlateLine(a: Point2(x: 0.1, y: 0.6), b: Point2(x: 0.9, y: 0.5))],
            heightReference: PlateHeightReference(
                foot: Point2(x: 0.5, y: 0.8),
                top: Point2(x: 0.5, y: 0.6),
                height: 0.76
            )
        )
        document.scenes[0].shots[0].asks = [FramingAsk(entityID: woman, extent: .thighsUp)]
        try ShotsDocumentFile.save(document, to: url)
        let loaded = try ShotsDocumentFile.load(from: url)
        #expect(loaded.document == document && !loaded.readOnly && loaded.notice == nil)
    }
}

@Suite("A shot's own blocking")
@MainActor
struct ShotsOwnBlockingTests {
    private let woman = "ent_000000000111"

    @Test func aShotGivenItsOwnBlockingKeepsItsMovesToItself() throws {
        let store = try ShotsStore(
            catalog: ContentCatalog.bundled(),
            document: ShotsSamples.plateStaging(),
            saveURL: nil
        )
        let first = try #require(store.currentShot)
        try store.perform(.duplicateShot(first.id, newID: "shot_second"))
        store.selectShot("shot_second")
        try store.perform(.giveOwnBlocking("shot_second", takeID: "take_second"))
        #expect(store.currentScene?.shotsSharingBlocking(with: "shot_second").map(\.id) == ["shot_second"])

        // Moved through the inspector's fields in the second shot, she stays put in the first.
        let start = try #require(store.firstMark(of: woman)).position
        store.move(woman, to: Vec3(1.5, 0, -6))
        store.turn(woman, to: 0.5)
        let moved = try #require(store.frame?.entities.first { $0.id == woman })
        #expect(moved.position.x == 1.5 && abs(moved.heading - 0.5) < 1e-9)
        store.selectShot(first.id)
        #expect(store.frame?.entities.first { $0.id == woman }?.position == start)

        // Someone added once the shots have parted has a place of their own in each of them.
        let id = try store.addLibraryAsset("person.man")
        store.selectShot("shot_second")
        store.move(id, to: Vec3(-1, 0, -5))
        store.selectShot(first.id)
        #expect(store.frame?.entities.first { $0.id == id }?.position.x != -1)

        // A take id already in the project is refused.
        try store.perform(.duplicateShot(first.id, newID: "shot_third"))
        #expect(throws: (any Error).self) { try store.perform(.giveOwnBlocking("shot_third", takeID: "take_second")) }
    }
}
