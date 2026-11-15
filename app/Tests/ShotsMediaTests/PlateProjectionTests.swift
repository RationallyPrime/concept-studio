import CoreGraphics
import Foundation
import PrevisCore
@testable import ShotsMedia
import Testing

@Suite("Shared location projection")
@MainActor
struct PlateProjectionTests {
    @Test func movingCameraSamplesVisibleFacesFromBothViewsAndMarksUnseenFaces() throws {
        let frame = fixture()
        let front = try solid(0xDC1E1E)
        let right = try solid(0x1E3CDC)
        let textures = try PlateTextures(frame: frame, root: URL(fileURLWithPath: "/unused")) {
            $0.id == "front" ? front : right
        }
        let frontPoint = Vec3(0, 1, 1.001)
        let rightPoint = Vec3(1.001, 1, 0)
        #expect(textures.color(at: frontPoint, normal: Vec3(0, 0, 1)) == 0xDC1E1E)
        #expect(textures.color(at: rightPoint, normal: Vec3(1, 0, 0)) == 0x1E3CDC)
        #expect(textures.color(at: Vec3(1.2, 0, 1.2), normal: Vec3(0, 1, 0)) != nil)
        // Both source cameras are below the top and cannot see the cube's back face.
        #expect(textures.color(at: Vec3(0, 2.001, 0), normal: Vec3(0, 1, 0)) == nil)
        #expect(textures.color(at: Vec3(0, 1, -1), normal: Vec3(0, 0, -1)) == nil)
        #expect(textures.color(at: Vec3(0, 1, 0.99), normal: Vec3(0, 0, 1)) == nil)
        let projected = try PassDrawing.image(size: frame.canvas.pixelSize) { context in
            var rasterizer = PlateRasterizer(frame: frame, camera: frame.camera, context: context)
            PlateRasterizer.drawUnmapped(in: context, rect: rasterizer.content)
            rasterizer.drawLocation(using: textures)
        }
        let pixels = try Pixels(projected)
        let first = try #require(frame.project(frontPoint))
        let second = try #require(frame.project(rightPoint))
        #expect(pixels.rgb(Int(first.x), Int(first.y)) == (220, 30, 30))
        #expect(pixels.rgb(Int(second.x), Int(second.y)) == (30, 60, 220))
        let top = try #require(frame.project(Vec3(0, 2.001, 0)))
        let unknown = pixels.rgb(Int(top.x), Int(top.y))
        #expect(unknown == (97, 44, 89) || unknown == (36, 33, 41))
    }

    @Test func draftCalibrationRemainsAvailableForInteractiveProjection() throws {
        var frame = fixture()
        frame.referencePlates[0].calibration.confirmed = false
        frame.referencePlates[1].calibration.confirmed = false
        let color = try solid(0xDC1E1E)
        let textures = try PlateTextures(frame: frame, root: URL(fileURLWithPath: "/unused")) { _ in color }
        #expect(textures.color(at: Vec3(0, 1, 1.001), normal: Vec3(0, 0, 1)) == 0xDC1E1E)
    }

    @Test(.enabled(if: renderingEnabled))
    func matchingAnyCalibratedViewPreservesItsOriginalPixels() async throws {
        let folder = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let front = try solid(0xDC1E1E), right = try solid(0x1E3CDC)
        try StillWriter.writePNG(front, to: folder.appendingPathComponent("front.png"))
        try StillWriter.writePNG(right, to: folder.appendingPathComponent("right.png"))
        var frame = fixture()
        frame.camera = frame.referencePlates[1].calibration.frame(aspect: frame.canvas.aspect)
        let image = try await ShotFrameRenderer(plateRoot: folder).image(of: frame, look: PrevisLook(lighting: .day))
        let result = try Pixels(image)
        let original = try Pixels(right)
        #expect(result.bytes == original.bytes)
    }

    private func fixture() -> SceneFrame {
        let size = PixelSize(width: 320, height: 320)
        let front = LocationPlate(
            id: "front",
            name: "Front",
            imagePath: "front.png",
            pixelSize: size,
            calibration: PlateCalibration(
                position: Vec3(0, 1, 6),
                focalLength: 20,
                confirmed: true
            )
        )
        let right = LocationPlate(
            id: "right",
            name: "Right",
            imagePath: "right.png",
            pixelSize: size,
            calibration: PlateCalibration(
                position: Vec3(6, 1, 0),
                pan: .pi / 2,
                focalLength: 20,
                confirmed: true
            )
        )
        let camera = CameraFrame.make(
            position: Vec3(4, 3, 4),
            pan: .pi / 4,
            tilt: -atan(2 / sqrt(32)),
            roll: 0,
            focalLength: 20,
            sensor: .super35,
            aspect: 1
        )
        return SceneFrame(
            index: 0,
            time: 0,
            canvas: ShotCanvas(width: 320, height: 320),
            camera: camera,
            plate: front,
            setPieces: [PlateSetPiece(
                id: "box",
                name: "Box",
                position: .zero,
                size: Vec3(2, 2, 2)
            )],
            referencePlates: [front, right]
        )
    }

    private func solid(_ rgb: UInt32) throws -> CGImage {
        try PassDrawing.image(size: PixelSize(width: 320, height: 320)) { context in
            context.setFillColor(CGColor(
                srgbRed: Double((rgb >> 16) & 255) / 255,
                green: Double((rgb >> 8) & 255) / 255,
                blue: Double(rgb & 255) / 255,
                alpha: 1
            ))
            context.fill(CGRect(x: 0, y: 0, width: 320, height: 320))
        }
    }
}
