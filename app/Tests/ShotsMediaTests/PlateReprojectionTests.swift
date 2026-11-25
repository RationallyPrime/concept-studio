import CoreGraphics
import PrevisCore
@testable import ShotsMedia
import Testing

struct PlateReprojectionTests {
    @Test func translatingTheCameraMovesHallAndDaisMarksByTheirSeparateDepths() async throws {
        let size = PixelSize(width: 256, height: 256)
        let match = PlateMatch(
            position: Vec3(0, 2.1, 4), pan: 0, tilt: 0, roll: 0, focalLength: 18.66, sensor: .super35
        )
        let plate = LocationPlate(
            id: "plate_000000000001", name: "Hall from dais", file: "hall.png", size: size, match: match,
            guides: PlateGuides(floorLevel: 0.6)
        )
        let dais = SetPiece(kind: .dais, size: Vec3(1.5, 0.6, 1.6), steps: 2, inPlate: true)
        let entity = PrevisEntity(
            id: "ent_000000000001", assetID: dais.assetID, name: "Dais",
            placement: Placement(position: Vec3(0.9, 0, -0.8), heading: 0, scale: 1), setPiece: dais
        )
        var shot = Shot.make(
            id: "shot_000000000001", name: "Truck right", takeID: "take_000000000001", cameraMarkID: "cam_000000000001"
        )
        shot.frameCount = 5
        shot.canvas = ShotCanvas(width: size.width, height: size.height)
        shot.plateID = plate.id
        var end = match.cameraMark(id: "cam_000000000002")
        end.time = FrameGrid.time(ofFrame: 4)
        end.position.x += 0.6
        shot.camera.marks = [match.cameraMark(id: "cam_000000000001"), end]
        let scene = PrevisScene(
            id: "scene_000000000001", name: "Hall", revision: 0, lighting: .day,
            entities: [entity], blocking: [BlockingTake(id: shot.blockingTakeID, name: "Master")],
            shots: [shot], plates: [plate]
        )
        // With focal length = sensor height, this square image has focal length 256 px. For the level
        // camera, u = 128 + 256 * (X - cameraX) / (4 - Z), v = 128 + 256 * (2.1 - Y) / (4 - Z).
        // The hall mark is at (-1, 0, -2.4), the dais mark at (0.9, 0.6, -0.8).
        let source = try PassDrawing.image(size: size) { context in
            context.setFillColor(gray: 0.1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height))
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 85, y: 209, width: 6, height: 6))
            context.fill(CGRect(x: 173, y: 205, width: 6, height: 6))
        }
        let evaluator = try ShotEvaluator(scene: scene, shotID: shot.id, catalog: ContentCatalog.bundled())
        let image = try await PlateReprojection.image(for: evaluator.frame(4), size: size, sources: [(plate, source)])
        let marks = try Pixels(image).brightBlobs().sorted { $0.x < $1.x }
        try #require(marks.count == 2)
        // A 0.6 m truck shifts the hall mark 24 px and the dais mark 32 px. Calibration's floorLevel
        // identifies a height reference. The raised surface's footprint comes from its authored geometry.
        #expect(hypot(marks[0].x - 64, marks[0].y - 212) < 1)
        #expect(hypot(marks[1].x - 144, marks[1].y - 208) < 1)
    }
}
