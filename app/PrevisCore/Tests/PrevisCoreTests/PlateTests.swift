import Foundation
@testable import PrevisCore
import Testing

struct PlateTests {
    private func plate() -> LocationPlate {
        LocationPlate(
            id: "plate", name: "Hall C", imagePath: "plates/hall.png",
            pixelSize: PixelSize(width: 1440, height: 2560),
            calibration: PlateCalibration(focalLength: 20, confirmed: true)
        )
    }

    private func pieces() -> [PlateSetPiece] {
        [PlateSetPiece(
            id: "table", name: "Table", position: Vec3(0, 0, 1), size: Vec3(4, 1, 1),
            supportsStanding: false
        )]
    }

    private func scene() throws -> PrevisScene {
        var scene = try #require(ShotsSamples.twoPersonWalk(small: true).scenes.first)
        scene.plates = [plate()]
        scene.setPieces = pieces()
        scene.shots[0].plateID = "plate"
        scene.shots[0].canvas = ShotCanvas(width: 576, height: 1024)
        scene.shots[0].keyCanvas = ShotCanvas(width: 1440, height: 2560)
        scene.shots[0].requestedFraming = .full
        scene.shots[0].camera.marks = [CameraMark(
            id: "plate-camera", time: 0, hold: 0, easeIn: 0, easeOut: 0,
            position: scene.plates[0].calibration.position, pan: 0, tilt: 0, roll: 0, focalLength: 20
        )]
        scene.entities = [PrevisEntity(
            id: "actor", assetID: "person.man", name: "Speaker",
            placement: Placement(position: .zero, heading: .pi, scale: 1)
        )]
        scene.blocking[0].tracks = []
        return scene
    }

    @Test func oldDocumentsKeepTheirOriginalCanvasAndHaveNoPlate() throws {
        let data = Data(#"{"scenes":[{"id":"s","shots":[{"id":"a"}]}]}"#.utf8)
        let document = try JSONDecoder().decode(ShotsDocument.self, from: data)
        let scene = try #require(document.scenes.first)
        let shot = try #require(scene.shots.first)
        #expect(scene.plates.isEmpty)
        #expect(shot.plateID == nil)
        #expect(shot.keyCanvas == nil)
        #expect(shot.guideCanvas == .portrait)
    }

    @Test func platesAndKeyCanvasRoundTripWithScene() throws {
        let document = try ShotsDocument(version: 1, scenes: [scene()])
        let data = try JSONEncoder().encode(document)
        #expect(try JSONDecoder().decode(ShotsDocument.self, from: data) == document)
        #expect(try ShotsValidation.problems(in: document, catalog: .bundled()).isEmpty)
        #expect(document.scenes[0].shots[0].guideCanvas == ShotCanvas(width: 1440, height: 2560))
        #expect(!document.scenes[0].shots[0].guideCanvas.isValid)
        #expect(document.scenes[0].shots[0].guideCanvas.isValidKey)
    }

    @Test func matchUsesTheSameProjectionAsTheShotCameraAtEveryDepth() throws {
        let plate = plate()
        let size = plate.pixelSize
        let camera = plate.calibration.frame(aspect: size.aspect)
        for point in [Vec3(0, 0, 0), Vec3(1, 0, -3), Vec3(-1, 0, 2)] {
            let pixel = try #require(camera.project(point, size: size))
            let placed = try #require(plate.placementPoint(at: pixel, size: size, setPieces: []))
            #expect((placed - point).length < 1e-8)
        }
        #expect(plate.calibration.matches(camera, aspect: size.aspect))
        var moved = camera
        moved.position.x += 0.1
        #expect(!plate.calibration.matches(moved, aspect: size.aspect))
    }

    @Test func tableOccludesTheLowerBodyAndDaisSupportsPlacement() throws {
        let plate = plate()
        let camera = plate.calibration.frame(aspect: plate.pixelSize.aspect)
        #expect(plate.isOccluded(Vec3(0, 0.4, 0), camera: camera, setPieces: pieces()))
        #expect(!plate.isOccluded(Vec3(0, 1.8, 0), camera: camera, setPieces: pieces()))
        #expect(!plate.isOccluded(Vec3(0, 0.4, 3), camera: camera, setPieces: pieces()))
        let dais = [PlateSetPiece(
            id: "dais", name: "Dais", position: Vec3(0, 0, 0), size: Vec3(4, 0.5, 4)
        )]
        #expect(plate.surfaceHeight(at: .zero, setPieces: dais) == 0.5)
        #expect(plate.surfaceHeight(at: Vec3(3, 0, 0), setPieces: dais) == 0)
        let pixel = try #require(camera.project(Vec3(0, 0.5, 0), size: plate.pixelSize))
        #expect(try #require(plate.placementPoint(at: pixel, size: plate.pixelSize, setPieces: dais)).y == 0.5)
    }

    @Test func rayIntersectionHandlesParallelMissesInsideAndBehind() {
        let piece = pieces()[0]
        #expect(piece.rayIntersection(origin: Vec3(0, 0.5, 6), direction: Vec3(0, 0, -1)) == 4.5)
        #expect(piece.rayIntersection(origin: Vec3(3, 0.5, 6), direction: Vec3(0, 0, -1)) == nil)
        #expect(piece.rayIntersection(origin: Vec3(0, 0.5, 1), direction: Vec3(1, 0, 0)) == 0)
        #expect(piece.rayIntersection(origin: Vec3(0, 0.5, 6), direction: Vec3(0, 0, 1)) == nil)
    }

    @Test func fittedPlateProjectionAndPlacementAgreeWithLetterboxing() throws {
        var plate = plate()
        plate.pixelSize = PixelSize(width: 1920, height: 1080)
        let size = PixelSize(width: 576, height: 1024)
        let camera = plate.calibration.frame(aspect: plate.pixelSize.aspect)
        let rect = plate.imageRect(in: size)
        #expect(rect.width == 576)
        #expect(rect.height == 324)
        #expect(rect.y == 350)
        let point = Vec3(0, 0, 0)
        let projected = try #require(plate.project(point, camera: camera, size: size))
        let placed = try #require(plate.placementPoint(at: projected, size: size, setPieces: []))
        #expect((placed - point).length < 1e-8)
        #expect(plate.placementPoint(at: Point2(x: 288, y: 100), size: size, setPieces: []) == nil)
        var scene = try scene()
        scene.plates = [plate]
        let frame = try ShotEvaluator(scene: scene, shotID: scene.shots[0].id, catalog: .bundled()).frame(0)
        #expect(abs(frame.camera.verticalFOV - camera.verticalFOV) < 1e-10)
        #expect(frame.project(point) == projected)
    }

    @Test func stagingAndDiagnosticsDescribeActualOcclusion() throws {
        let scene = try scene()
        let shot = scene.shots[0]
        let evaluator = try ShotEvaluator(scene: scene, shotID: shot.id, catalog: .bundled())
        let frame = evaluator.frame(0)
        #expect(frame.plate == scene.plates[0])
        let description = ShotStaging.description(frame: frame, shot: shot)
        #expect(description.contains("Plate Hall C"))
        #expect(description.contains("Speaker is centre"))
        #expect(description.contains("facing the camera"))
        #expect(description.contains("20 mm"))
        #expect(!description.contains("visible head to boots"))
        #expect(evaluator.warnings().contains { $0.message.contains("cannot be seen head to boots") })
        #expect(!evaluator.warnings().contains { $0.message.contains("matched viewpoint") })
    }

    @Test func fourCalibratedViewsShareOneSetAndOneBlockingTake() throws {
        var scene = try scene()
        let positions = [Vec3(0, 1.6, 6), Vec3(6, 1.6, 0), Vec3(0, 1.6, -6), Vec3(-6, 1.6, 0)]
        scene.plates = positions.enumerated().map { index, position in
            var plate = plate()
            plate.id = "plate-\(index)"
            plate.calibration.position = position
            plate.calibration.pan = Double(index) * .pi / 2
            return plate
        }
        let original = scene.shots[0]
        scene.shots = scene.plates.enumerated().map { index, plate in
            var shot = original
            shot.id = "shot-\(index)"
            shot.plateID = plate.id
            shot.camera.marks[0].id = "camera-\(index)"
            shot.camera.marks[0].position = plate.calibration.position
            shot.camera.marks[0].pan = plate.calibration.pan
            return shot
        }
        let frames = try scene.shots.map {
            try ShotEvaluator(scene: scene, shotID: $0.id, catalog: .bundled()).frame(0)
        }
        #expect(frames.allSatisfy { $0.setPieces == scene.setPieces })
        #expect(frames.allSatisfy { $0.referencePlates == scene.plates })
        #expect(frames.allSatisfy { $0.entities[0].position == .zero })
        #expect(Set(frames.compactMap { $0.plate?.id }).count == 4)
        #expect(frames.allSatisfy { abs($0.project(Vec3(0, 1, 0))!.x - 288) < 1e-8 })
        let data = try JSONEncoder().encode(scene)
        let decoded = try JSONDecoder().decode(PrevisScene.self, from: data)
        #expect(decoded.setPieces == scene.setPieces)
    }

    @Test func movingFramesRetainEveryReferenceView() throws {
        var scene = try scene()
        var otherView = scene.plates[0]
        otherView.id = "side-view"
        otherView.imagePath = "plates/side.png"
        otherView.calibration.position = Vec3(6, 1.6, 0)
        otherView.calibration.pan = .pi / 2
        scene.plates.append(otherView)
        var destination = scene.shots[0].camera.marks[0]
        destination.id = "moving-camera"
        destination.time = scene.shots[0].duration
        destination.position.x += 2
        scene.shots[0].camera.marks.append(destination)
        let evaluator = try ShotEvaluator(scene: scene, shotID: scene.shots[0].id, catalog: .bundled())
        let first = evaluator.frame(0), last = evaluator.frame(scene.shots[0].frameCount - 1)
        #expect(first.camera.position != last.camera.position)
        #expect(first.plate == scene.plates[0])
        #expect(last.plate == first.plate)
        #expect(first.referencePlates == scene.plates)
        #expect(last.referencePlates == first.referencePlates)
        #expect(last.setPieces == first.setPieces)
    }

    @Test func reconstructionDiagnosticsExplainMissingMatchesAndSurfacesWithoutBlocking() throws {
        var scene = try scene()
        scene.setPieces = []
        scene.plates[0].calibration.confirmed = false
        var destination = scene.shots[0].camera.marks[0]
        destination.id = "moving-camera"
        destination.time = scene.shots[0].duration
        destination.position.x += 1
        scene.shots[0].camera.marks.append(destination)
        let evaluator = try ShotEvaluator(scene: scene, shotID: scene.shots[0].id, catalog: .bundled())
        let warnings = evaluator.warnings()
        #expect(warnings.contains { $0.message.contains("no confirmed reference camera") })
        #expect(warnings.contains { $0.message.contains("Only the floor has a projection surface") })
        #expect(warnings.allSatisfy { $0.severity == .warning })
        #expect(try ShotsValidation.problems(
            in: ShotsDocument(version: 1, scenes: [scene]), catalog: .bundled()
        ).isEmpty)
    }

    @Test func exactReferenceMatchingPrefersTheSelectedDraftPlate() throws {
        let scene = try scene()
        let shot = scene.shots[0]
        var frame = try ShotEvaluator(scene: scene, shotID: shot.id, catalog: .bundled()).frame(0)
        frame.plate?.calibration.confirmed = false
        var duplicate = scene.plates[0]
        duplicate.id = "duplicate"
        frame.referencePlates = try [duplicate, #require(frame.plate)]
        #expect(frame.matchedReferencePlate?.id == frame.plate?.id)
        #expect(!frame.usesProjectedLocation)
    }

    @Test func alternateExactViewRequiresMatchingAspectAndMovingViewsUseProjection() throws {
        let scene = try scene()
        let shot = scene.shots[0]
        var frame = try ShotEvaluator(scene: scene, shotID: shot.id, catalog: .bundled()).frame(0)
        var alternate = scene.plates[0]
        alternate.id = "alternate"
        alternate.name = "Hall side"
        alternate.calibration.position.x += 2
        alternate.calibration.confirmed = false
        frame.camera = alternate.calibration.frame(aspect: alternate.pixelSize.aspect)
        var differentAspect = alternate
        differentAspect.id = "landscape"
        differentAspect.pixelSize = PixelSize(width: 1920, height: 1080)
        frame.referencePlates = [differentAspect, alternate]
        #expect(frame.matchedReferencePlate?.id == alternate.id)
        #expect(!frame.usesProjectedLocation)
        #expect(ShotStaging.description(frame: frame, shot: shot).contains("Plate Hall side."))
        frame.referencePlates = [differentAspect]
        #expect(frame.matchedReferencePlate == nil)
        #expect(frame.usesProjectedLocation)
        #expect(ShotStaging.description(frame: frame, shot: shot).contains("Location view projected from Hall side."))
        frame.plate = nil
        #expect(!frame.usesProjectedLocation)
    }

    @Test func placementUsesTheMovedShotCameraWhenProvided() throws {
        let plate = plate()
        let size = plate.pixelSize
        var camera = plate.calibration.frame(aspect: size.aspect)
        camera.position.x = 1
        let target = Vec3(0.5, 0, 0)
        let pixel = try #require(plate.project(target, camera: camera, size: size))
        let placed = try #require(plate.placementPoint(at: pixel, size: size, setPieces: [], camera: camera))
        #expect((placed - target).length < 1e-8)
        let calibrated = try #require(plate.placementPoint(at: pixel, size: size, setPieces: []))
        #expect((calibrated - target).length > 0.5)
    }

    @Test func stagingExcludesActorsInsideThePlateLetterbox() throws {
        var scene = try scene()
        scene.plates[0].pixelSize = PixelSize(width: 128, height: 512)
        scene.entities[0].placement.position.x = -1
        scene.setPieces = []
        let shot = scene.shots[0]
        let frame = try ShotEvaluator(scene: scene, shotID: shot.id, catalog: .bundled()).frame(0)
        let pixel = try #require(frame.project(Vec3(-1, 1, 0)))
        let content = scene.plates[0].imageRect(in: frame.canvas.pixelSize)
        #expect(pixel.x > 0 && pixel.x < content.x)
        let subject = try #require(ShotStaging.subjects(in: frame).first)
        #expect(subject.visibleFraction == 0)
        #expect(subject.horizontal == "off frame left")
        #expect(subject.visibleBody == "not visible")
        #expect(PlateDiagnostics.problems(frame: frame, shot: shot, sceneID: scene.id).contains {
            $0.message.contains("outside the frame or fully hidden")
        })
    }

    @Test func invalidReferencesAndMismatchedCanvasesAreReported() throws {
        var scene = try scene()
        scene.shots[0].plateID = "missing"
        scene.shots[0].keyCanvas = ShotCanvas(width: 768, height: 768)
        scene.setPieces[0].size.x = 0
        let messages = try ShotsValidation.problems(
            in: ShotsDocument(version: 1, scenes: [scene]), catalog: .bundled()
        ).map(\.message)
        #expect(messages.contains { $0.contains("missing plate") })
        #expect(messages.contains { $0.contains("same aspect ratio") })
        #expect(messages.contains { $0.contains("dimensions above zero") })
    }
}
