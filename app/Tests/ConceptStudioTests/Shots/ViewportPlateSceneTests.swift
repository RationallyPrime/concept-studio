import AppKit
@testable import ConceptStudio
import PrevisCore
import ShotsMedia
import Testing

@Suite("Plate-backed scene viewport", .enabled(if: ShotFrameRenderer.isAvailable))
@MainActor
struct ViewportPlateSceneTests {
    @Test func sceneSnapshotShowsSharedGeometryWithoutLoadingThePlate() async throws {
        let size = PixelSize(width: 320, height: 240)
        let camera = EditorCamera.defaultView
        let plate = LocationPlate(
            id: "plate",
            name: "Plate",
            imagePath: "missing.png",
            pixelSize: PixelSize(width: 576, height: 1024)
        )
        var frame = SceneFrame(
            time: 0,
            canvas: ShotCanvas(width: 320, height: 256),
            camera: plate.calibration.frame(aspect: 0.5625),
            plate: plate,
            setPieces: [PlateSetPiece(
                id: "dais",
                name: "Dais",
                position: .zero,
                size: Vec3(4, 0.6, 3)
            )]
        )
        let withGeometry = try await ViewportSnapshotRenderer.renderSnapshot(
            frame: frame, look: PrevisLook(lighting: .day), camera: camera, size: size
        )
        frame.setPieces = []
        let empty = try await ViewportSnapshotRenderer.renderSnapshot(
            frame: frame, look: PrevisLook(lighting: .day), camera: camera, size: size
        )
        #expect(withGeometry.width == size.width && withGeometry.height == size.height)
        let pixels = try #require(withGeometry.dataProvider?.data) as Data
        let emptyPixels = try #require(empty.dataProvider?.data) as Data
        #expect(pixels != emptyPixels)
    }
}
