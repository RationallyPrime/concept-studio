import AppKit
@testable import ConceptStudio
import ImageIO
import PrevisCore
import Testing

@Suite("Plate editing and project preservation")
@MainActor
struct ShotsPlateTests {
    @Test func importingCopiesOriginalAndRestoresOneUndoStep() throws {
        let root = temporaryTestDirectory("plate-import")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.png")
        try png(width: 576, height: 1024).write(to: source)
        let store = try makeStore(project: root.appendingPathComponent("Project"))
        let before = store.document
        try store.importPlate(from: source)
        let plate = try #require(store.currentPlate)
        #expect(plate.pixelSize == PixelSize(width: 576, height: 1024))
        #expect(store.currentShot?.canvas == ShotCanvas(width: 576, height: 1024))
        #expect(try Data(contentsOf: #require(store.plateRootURL).appendingPathComponent(plate.imagePath))
            == Data(contentsOf: source))
        try store.flush()
        let loaded = try ShotsDocumentFile.load(from: ShotsDocumentFile.url(in: root.appendingPathComponent("Project")))
        #expect(loaded.document == store.document)
        store.undo()
        #expect(store.document == before)
        store.redo()
        #expect(store.currentPlate == plate)
    }

    @Test func matchingUsesSelectedViewAndKeepsSharedBlocking() throws {
        let store = try makeStore()
        let scene = try #require(store.currentScene)
        let shot = try #require(store.currentShot)
        let blocking = scene.blocking
        let plates = [
            LocationPlate(
                id: "master",
                name: "Master",
                imagePath: "m.png",
                pixelSize: PixelSize(width: 576, height: 1024)
            ),
            LocationPlate(
                id: "reverse",
                name: "Reverse",
                imagePath: "b.png",
                pixelSize: PixelSize(width: 576, height: 1024),
                calibration: PlateCalibration(position: Vec3(0, 1.7, -8), pan: .pi, focalLength: 24)
            ),
        ]
        try store.perform(plates.map { .putPlate(scene.id, $0) })
        try store.perform([.setPlate(shot.id, "reverse"), .matchPlateCamera(shot.id)])
        #expect(store.currentShot?.camera.marks.count == 1)
        #expect(store.currentShot?.camera.marks.first?.pan == .pi)
        #expect(store.currentShot?.camera.marks.first?.focalLength == 24)
        #expect(store.currentScene?.blocking == blocking)
        #expect(store.currentScene?.plates.count == 2)
    }

    @Test func placingBlockedActorMovesMarksTogether() throws {
        let store = try makeStore()
        let frame = try #require(store.frame)
        let actor = try #require(frame.entities.first)
        let before = try #require(store.currentScene?.blocking.first?.tracks.first)
        store.selection = .entities([actor.id])
        store.moveSelectedToPlatePoint(Vec3(actor.position.x + 2, actor.position.y + 0.5, actor.position.z - 1))
        let after = try #require(store.currentScene?.blocking.first?.tracks.first)
        #expect(after.marks.count == before.marks.count)
        for (old, new) in zip(before.marks, after.marks) {
            #expect(abs(new.position.x - old.position.x - 2) < 1e-9)
            #expect(abs(new.position.y - old.position.y - 0.5) < 1e-9)
            #expect(abs(new.position.z - old.position.z + 1) < 1e-9)
        }
    }

    @Test func readonlyImportWritesNothing() throws {
        let root = temporaryTestDirectory("plate-readonly")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ShotsStore(
            catalog: ContentCatalog.bundled(),
            document: ShotsSamples.twoPersonWalk(),
            saveURL: ShotsDocumentFile.url(in: root),
            readOnly: true
        )
        #expect(throws: ShotsEditingError.self) {
            try store.importPlate(from: root.appendingPathComponent("unused.png"))
        }
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func canvasChangeKeepsGuideAndControlAspectsTogether() throws {
        let store = try makeStore()
        let shot = try #require(store.currentShot)
        try store.perform(.setCanvas(shot.id, ShotCanvas(width: 576, height: 1024)))
        try store.perform(.setKeyCanvas(shot.id, ShotCanvas(width: 1440, height: 2560)))
        try store.perform(.setCanvas(shot.id, ShotCanvas(width: 768, height: 768)))
        #expect(store.currentShot?.keyCanvas == nil)
        #expect(store.currentShot?.guideCanvas == ShotCanvas(width: 768, height: 768))
    }

    @Test func reverseCameraGridClipsItsNearPlane() throws {
        let camera = PlateCalibration(position: Vec3(0, 1.6, -6), pan: .pi).frame(aspect: 9.0 / 16)
        let segment = try #require(ShotsPlateOverlay.clip(Vec3(1, 0, -12), Vec3(1, 0, 4), camera: camera))
        let view = camera.viewMatrix()
        #expect(abs(-view.transform(segment.0).z - CameraFrame.near) < 1e-9)
        #expect(-view.transform(segment.1).z > CameraFrame.near)
        #expect(ShotsPlateOverlay.clip(Vec3(1, 0, -12), Vec3(1, 0, -10), camera: camera) == nil)
    }

    @Test func squarePlateImportSelectsCompatibleCanvas() throws {
        let root = temporaryTestDirectory("plate-square")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("square.png")
        try png(width: 512, height: 512).write(to: source)
        let store = try makeStore(project: root.appendingPathComponent("Project"))
        try store.importPlate(from: source)
        #expect(store.currentShot?.canvas.aspect == 1)
        #expect(store.currentShot?.guideCanvas == ShotCanvas(width: 512, height: 512))
    }

    private func makeStore(project: URL? = nil) throws -> ShotsStore {
        try ShotsStore(
            catalog: ContentCatalog.bundled(),
            document: ShotsSamples.twoPersonWalk(),
            saveURL: project.map { ShotsDocumentFile.url(in: $0) }
        )
    }

    private func png(width: Int, height: Int) throws -> Data {
        let image = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        return try #require(image?.representation(using: .png, properties: [:]))
    }
}
