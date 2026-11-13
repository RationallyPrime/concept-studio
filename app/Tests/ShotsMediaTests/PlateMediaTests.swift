import CoreGraphics
import Foundation
import ImageIO
import PrevisCore
import RealityKit
@testable import ShotsMedia
import Testing

@Suite("plate composition and control alignment")
@MainActor
struct PlateMediaTests {
    @Test func backgroundKeepsEveryPixelAndFitsWithoutCropping() throws {
        let sourceSize = PixelSize(width: 64, height: 128)
        let source = try pattern(size: sourceSize)
        let frame = fixture(size: sourceSize).frame
        let result = try PassDrawing.image(size: sourceSize) { context in
            var rasterizer = PlateRasterizer(frame: frame, camera: frame.camera, context: context)
            PlateRasterizer.drawBackground(source, in: context, rect: rasterizer.content)
            rasterizer.draw()
        }
        #expect(try Pixels(source).bytes == Pixels(result).bytes)
        let wider = try PassDrawing.image(size: PixelSize(width: 128, height: 128)) { context in
            let rect = frame.plate!.imageRect(in: PixelSize(width: 128, height: 128))
            PlateRasterizer.drawBackground(
                source,
                in: context,
                rect: CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
            )
        }
        let pixels = try Pixels(wider)
        #expect(pixels.rgb(0, 0) == (0, 0, 0))
        #expect(pixels.rgb(32, 0) == (220, 40, 30))
        #expect(pixels.rgb(95, 127) == (20, 80, 210))
        #expect(pixels.rgb(127, 127) == (0, 0, 0))
    }

    @Test func setSolidsHideTheSameRegionInCompositionAndLayout() throws {
        var setup = fixture(size: PixelSize(width: 288, height: 512))
        let bounds = Box3(min: Vec3(-0.3, 0, -0.2), max: Vec3(0.3, 1.8, 0.2))
        var transform = Mat4.identity
        transform.m[13] = 0.9
        setup.frame.entities = [EntityFrame(
            id: "actor", assetID: "person.man", name: "Person", isActor: true,
            position: .zero, heading: 0, gait: .stand, speed: 0, distanceTravelled: 0,
            parts: [PosedPart(
                id: "body",
                shape: .box(size: Vec3(0.6, 1.8, 0.4)),
                transform: transform,
                color: RGB(hex: "#808080")
            )],
            keypoints: [
                Keypoint(name: .nose, position: Vec3(0, 1.7, 0)),
                Keypoint(name: .rightKnee, position: Vec3(0, 0.5, 0)),
            ],
            bounds: bounds
        )]
        setup.frame.setPieces = [PlateSetPiece(
            id: "table", name: "Table", position: Vec3(0, 0, 1), size: Vec3(3, 1.1, 0.5)
        )]
        let size = setup.frame.canvas.pixelSize
        let image = try PassDrawing.image(size: size) { context in
            context.setFillColor(CGColor(srgbRed: 0.2, green: 0.3, blue: 0.4, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height))
            var rasterizer = PlateRasterizer(frame: setup.frame, camera: setup.frame.camera, context: context)
            rasterizer.draw()
        }
        let layout = try PassDrawing.image(size: size) { PassDrawing.drawLayout(setup.frame, in: $0) }
        let pose = try PassDrawing.image(size: size) { PassDrawing.drawPose(setup.frame, in: $0) }
        let upper = try #require(setup.frame.project(Vec3(0, 1.7, 0), size: size))
        let lower = try #require(setup.frame.project(Vec3(0, 0.5, 0), size: size))
        let compositionPixels = try Pixels(image), layoutPixels = try Pixels(layout), posePixels = try Pixels(pose)
        #expect(compositionPixels.rgb(Int(lower.x), Int(lower.y)) == (51, 77, 102))
        #expect(layoutPixels.rgb(Int(lower.x), Int(lower.y)) == (255, 255, 255))
        #expect(posePixels.rgb(Int(lower.x), Int(lower.y)) == (0, 0, 0))
        #expect(layoutPixels.rgb(Int(upper.x), Int(upper.y)) == (230, 25, 75))
        #expect(posePixels.rgb(Int(upper.x), Int(upper.y)) == (255, 0, 0))
        #expect(compositionPixels.rgb(Int(upper.x), Int(upper.y)).0 > 100)
    }

    @Test func poseAndLayoutLeaveThePlateLetterboxEmpty() throws {
        var setup = fixture(size: PixelSize(width: 288, height: 512))
        let sourceSize = PixelSize(width: 128, height: 512)
        setup.frame.plate?.pixelSize = sourceSize
        let bounds = Box3(min: Vec3(-0.85, 1.3, -0.1), max: Vec3(-0.65, 1.8, 0.1))
        var transform = Mat4.identity
        transform.m[12] = -0.75
        transform.m[13] = 1.55
        setup.frame.entities = [EntityFrame(
            id: "outside", assetID: "person.man", name: "Outside", isActor: true,
            position: Vec3(-0.75, 0, 0), heading: 0, gait: .stand, speed: 0, distanceTravelled: 0,
            parts: [PosedPart(
                id: "body",
                shape: .box(size: Vec3(0.2, 0.5, 0.2)),
                transform: transform,
                color: RGB(hex: "#808080")
            )],
            keypoints: [
                Keypoint(name: .nose, position: Vec3(-0.75, 1.7, 0)),
                Keypoint(name: .neck, position: Vec3(-0.75, 1.4, 0)),
            ], bounds: bounds
        )]
        let size = setup.frame.canvas.pixelSize
        let projected = try #require(setup.frame.project(Vec3(-0.75, 1.7, 0)))
        let rect = try #require(setup.frame.plate?.imageRect(in: size))
        #expect(projected.x > 0 && projected.x < rect.x)
        let pose = try Pixels(PassDrawing.image(size: size) { PassDrawing.drawPose(setup.frame, in: $0) })
        let layout = try Pixels(PassDrawing.image(size: size) { PassDrawing.drawLayout(setup.frame, in: $0) })
        let source = try pattern(size: sourceSize)
        let composition = try Pixels(PassDrawing.image(size: size) { context in
            var rasterizer = PlateRasterizer(frame: setup.frame, camera: setup.frame.camera, context: context)
            PlateRasterizer.drawBackground(source, in: context, rect: rasterizer.content)
            rasterizer.draw()
        })
        let x = Int(projected.x), y = Int(projected.y)
        #expect(pose.rgb(x, y) == (0, 0, 0))
        #expect(layout.rgb(x, y) == (255, 255, 255))
        #expect(composition.rgb(x, y) == (0, 0, 0))
    }

    @Test(arguments: [false, true])
    func invalidPlateExportsFailBeforeCreatingAFolder(wrongAspect: Bool) async throws {
        let folder = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var setup = fixture(size: PixelSize(width: 288, height: 512))
        if wrongAspect {
            setup.scene.shots[0].keyCanvas = ShotCanvas(width: 768, height: 768)
        } else {
            setup.scene.shots[0].plateID = "missing"
        }
        let output = folder.appendingPathComponent("output")
        let exporter = try ShotExporter(catalog: ContentCatalog.bundled(), plateRoot: folder)
        await #expect(throws: ShotsError.self) {
            try await exporter.export(
                scene: setup.scene,
                shotID: setup.scene.shots[0].id,
                options: ExportOptions(passes: [.layout]),
                to: FolderDestination(parent: output),
                progress: { _ in }
            )
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test(.enabled(if: renderingEnabled))
    func sharedSetPiecesAreVisibleOnlyInTheExplicitSceneView() throws {
        var setup = fixture(size: PixelSize(width: 288, height: 512))
        setup.frame.setPieces = [PlateSetPiece(
            id: "dais",
            name: "Dais",
            position: .zero,
            size: Vec3(4, 0.6, 3)
        )]
        let mapper = PrevisSceneMapper(look: PrevisLook(lighting: .day))
        mapper.apply(setup.frame, showsSetPieces: true)
        let wireframe = try #require(mapper.root.findEntity(named: "set-piece:dais"))
        #expect(wireframe.children.count == 12)
        mapper.apply(setup.frame, showsSetPieces: true)
        #expect(mapper.root.findEntity(named: "set-piece:dais") === wireframe)
        mapper.apply(setup.frame)
        #expect(mapper.root.findEntity(named: "set-piece:dais") == nil)
    }

    @Test(.enabled(if: renderingEnabled))
    func exportedCompositionUsesTheKeySizeAndPreservesThePlate() async throws {
        let folder = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var setup = fixture(size: PixelSize(width: 288, height: 512))
        setup.scene.shots[0].keyCanvas = ShotCanvas(width: 576, height: 1024)
        let source = try pattern(size: setup.frame.canvas.pixelSize)
        try StillWriter.writePNG(source, to: folder.appendingPathComponent("source.png"))
        let package = try await ShotExporter(catalog: ContentCatalog.bundled(), plateRoot: folder).export(
            scene: setup.scene, shotID: setup.scene.shots[0].id, options: ExportOptions(passes: [.pose, .layout]),
            to: FolderDestination(parent: folder.appendingPathComponent("exports")), progress: { _ in }
        )
        #expect(await PackageValidator.problems(at: package.url).isEmpty)
        let composition = try #require(package.manifest.files.first { $0.role == .composition })
        #expect(composition.frame == 0)
        #expect(composition.pixelSize == PixelSize(width: 576, height: 1024))
        let copied = try #require(package.manifest.files.first { $0.role == .plate })
        #expect(try Data(contentsOf: package.url.appendingPathComponent(copied.path))
            == Data(contentsOf: folder.appendingPathComponent("source.png")))
        let staging = try String(contentsOf: package.url.appendingPathComponent("staging.txt"), encoding: .utf8)
        #expect(staging.contains("Plate Test plate"))
        let sourceImage = try #require(CGImageSourceCreateWithURL(
            package.url.appendingPathComponent(composition.path) as CFURL, nil
        ))
        let image = try #require(CGImageSourceCreateImageAtIndex(sourceImage, 0, nil))
        #expect(image.width == 576 && image.height == 1024)
    }

    private func fixture(size: PixelSize) -> (scene: PrevisScene, frame: SceneFrame) {
        var scene = PrevisScene.make(id: "scene", name: "Scene", takeID: "take", shotID: "shot", cameraMarkID: "camera")
        scene.shots[0].frameCount = 22
        scene.shots[0].canvas = ShotCanvas(width: size.width, height: size.height)
        let plate = LocationPlate(
            id: "plate",
            name: "Test plate",
            imagePath: "source.png",
            pixelSize: size,
            calibration: PlateCalibration(confirmed: true)
        )
        scene.plates = [plate]
        scene.shots[0].plateID = plate.id
        let frame = SceneFrame(
            index: 0,
            time: 0,
            canvas: scene.shots[0].canvas,
            camera: plate.calibration.frame(aspect: size.aspect),
            plate: plate
        )
        return (scene, frame)
    }

    private func pattern(size: PixelSize) throws -> CGImage {
        try PassDrawing.image(size: size) { context in
            context.setFillColor(CGColor(srgbRed: 220.0 / 255, green: 40.0 / 255, blue: 30.0 / 255, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height / 2))
            context.setFillColor(CGColor(srgbRed: 20.0 / 255, green: 80.0 / 255, blue: 210.0 / 255, alpha: 1))
            context.fill(CGRect(x: 0, y: size.height / 2, width: size.width, height: size.height / 2))
        }
    }
}
