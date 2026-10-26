@testable import ConceptStudio
import CoreGraphics
import Foundation
import PrevisCore
import RealityKit
import ShotsMedia
import Testing

private let viewportRenderingEnabled = ShotFrameRenderer.isAvailable
    && ProcessInfo.processInfo.environment["SHOTS_SKIP_RENDER"] == nil

@Suite("Viewport D1 display, gestures, grid and snapshots")
struct ViewportDisplayTests {
    @Test func orbitPanAndDollyGesturesUpdateEditorCameraDeterministically() {
        var camera = EditorCamera.defaultView
        let initialYaw = camera.yaw
        let initialPitch = camera.pitch
        let initialTarget = camera.target
        let size = PixelSize(width: 800, height: 600)

        ViewportCameraGestures.applyDrag(
            to: &camera,
            deltaPoints: CGSize(width: 40, height: -20),
            viewportSize: size,
            optionPressed: false
        )
        #expect(camera.yaw != initialYaw)
        #expect(camera.pitch != initialPitch)
        #expect(camera.target == initialTarget)

        ViewportCameraGestures.applyDrag(
            to: &camera,
            deltaPoints: CGSize(width: 30, height: 25),
            viewportSize: size,
            optionPressed: true
        )
        #expect(camera.target != initialTarget)

        let beforeScrollDistance = camera.distance
        ViewportCameraGestures.applyScrollOrTrackpad(
            to: &camera,
            scrollingDeltaX: 0,
            scrollingDeltaY: 15,
            hasPreciseScrollingDeltas: false,
            optionPressed: false,
            viewportSize: size
        )
        #expect(camera.distance < beforeScrollDistance)
    }

    @Test(.enabled(if: viewportRenderingEnabled))
    @MainActor
    func defaultAndTopSnapshotsDrawEveryEntityAboveBackgroundAndKeepOverlaySeparate() async throws {
        let smallDoc = ShotsSamples.twoPersonWalk(small: true)
        let scene = try #require(smallDoc.scenes.first)
        let shot = try #require(scene.shots.first)
        let evaluator = try ShotEvaluator(scene: scene, shotID: shot.id, catalog: ContentCatalog.bundled())
        let frame = evaluator.frame(shot.guideFrames.first ?? 0)
        let look = PrevisLook(scene: scene)
        let renderer = try ShotFrameRenderer()
        let overlayRoot = ViewportGrid.makeOverlayRoot()

        let tempFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("d1-snapshots-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempFolder) }

        let views = [
            ("d1-default-small.png", EditorCamera.defaultView),
            ("d1-top-small.png", EditorCamera.topView),
        ]
        for (label, camera) in views {
            try await verifySnapshot(
                label: label,
                camera: camera,
                frame: frame,
                look: look,
                overlayRoot: overlayRoot,
                renderer: renderer,
                folder: tempFolder
            )
        }

        let cleanWithoutOverlay = try await SnapshotPixels(
            renderer.image(
                of: frame,
                look: look,
                camera: EditorCamera.defaultView.cameraFrame(for: frame.canvas.pixelSize),
                overlay: nil,
                size: frame.canvas.pixelSize
            )
        )
        let withGridOverlay = try await SnapshotPixels(
            ViewportSnapshotRenderer.renderSnapshot(
                frame: frame,
                look: look,
                camera: EditorCamera.defaultView,
                overlayRoot: overlayRoot,
                size: frame.canvas.pixelSize,
                renderer: renderer
            )
        )
        #expect(cleanWithoutOverlay.bytes != withGridOverlay.bytes)
        #expect(overlayRoot.parent == nil)
    }

    @Test(.enabled(if: viewportRenderingEnabled && ProcessInfo.processInfo.environment["SHOTS_SNAPSHOT_DIR"] != nil))
    @MainActor
    func writesFullSizeDefaultAndTopSnapshotsWhenSnapshotDirectoryIsSet() async throws {
        let fullDoc = ShotsSamples.twoPersonWalk(small: false)
        let scene = try #require(fullDoc.scenes.first)
        let shot = try #require(scene.shots.first)
        let evaluator = try ShotEvaluator(scene: scene, shotID: shot.id, catalog: ContentCatalog.bundled())
        let frame = evaluator.frame(shot.guideFrames.first ?? 0)
        let look = PrevisLook(scene: scene)
        let renderer = try ShotFrameRenderer()
        let overlayRoot = ViewportGrid.makeOverlayRoot()

        let views = [
            ("d1-sample-default.png", EditorCamera.defaultView),
            ("d1-sample-top.png", EditorCamera.topView),
        ]
        for (name, camera) in views {
            let image = try await ViewportSnapshotRenderer.renderSnapshot(
                frame: frame,
                look: look,
                camera: camera,
                overlayRoot: overlayRoot,
                size: frame.canvas.pixelSize,
                renderer: renderer
            )
            let url = try ViewportSnapshotRenderer.writeSnapshot(image: image, named: name)
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
    }

    @MainActor
    private func verifySnapshot(
        label: String,
        camera: EditorCamera,
        frame: SceneFrame,
        look: PrevisLook,
        overlayRoot: Entity,
        renderer: ShotFrameRenderer,
        folder: URL
    ) async throws {
        let snapshotImage = try await ViewportSnapshotRenderer.renderSnapshot(
            frame: frame,
            look: look,
            camera: camera,
            overlayRoot: overlayRoot,
            size: frame.canvas.pixelSize,
            renderer: renderer
        )
        let savedURL = try ViewportSnapshotRenderer.writeSnapshot(
            image: snapshotImage,
            named: label,
            directory: folder
        )
        #expect(FileManager.default.fileExists(atPath: savedURL.path))

        var bareFrame = frame
        bareFrame.entities = []
        let bareImage = try await ViewportSnapshotRenderer.renderSnapshot(
            frame: bareFrame,
            look: look,
            camera: camera,
            overlayRoot: overlayRoot,
            size: frame.canvas.pixelSize,
            renderer: renderer
        )

        let drawnPixels = try SnapshotPixels(snapshotImage)
        let barePixels = try SnapshotPixels(bareImage)
        let backgroundRGB = (57, 64, 72)

        for entity in frame.entities {
            let centre = Vec3(
                (entity.bounds.min.x + entity.bounds.max.x) / 2,
                (entity.bounds.min.y + entity.bounds.max.y) / 2,
                (entity.bounds.min.z + entity.bounds.max.z) / 2
            )
            let projected = try #require(
                camera.project(centre, size: frame.canvas.pixelSize),
                "\(entity.name) did not project in \(label)"
            )
            let inBounds = projected.x >= 0 && projected.x < Double(drawnPixels.width)
                && projected.y >= 0 && projected.y < Double(drawnPixels.height)
            #expect(inBounds, "\(entity.name) projected outside \(label) at \(projected)")
            let rgb = drawnPixels.rgb(at: projected)
            let bgDiff = abs(rgb.0 - backgroundRGB.0) + abs(rgb.1 - backgroundRGB.1) + abs(rgb.2 - backgroundRGB.2)
            #expect(bgDiff > 24, "\(entity.name) centre pixel \(rgb) is background in \(label)")
            #expect(
                drawnPixels.differs(from: barePixels, at: projected),
                "\(entity.name) centre pixel does not differ from bare scene in \(label)"
            )
        }
    }
}

private struct SnapshotPixels {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let bytes: [UInt8]

    init(_ image: CGImage) throws {
        width = image.width
        height = image.height
        bytesPerRow = image.bytesPerRow
        let data = try #require(image.dataProvider?.data) as Data
        bytes = [UInt8](data)
    }

    func rgb(at point: Point2) -> (Int, Int, Int) {
        let x = min(max(Int(point.x), 0), width - 1)
        let y = min(max(Int(point.y), 0), height - 1)
        let offset = y * bytesPerRow + x * 4
        return (Int(bytes[offset + 2]), Int(bytes[offset + 1]), Int(bytes[offset]))
    }

    func differs(from other: SnapshotPixels, at point: Point2) -> Bool {
        let (r1, g1, b1) = rgb(at: point)
        let (r2, g2, b2) = other.rgb(at: point)
        return abs(r1 - r2) + abs(g1 - g2) + abs(b1 - b2) > 12
    }
}
