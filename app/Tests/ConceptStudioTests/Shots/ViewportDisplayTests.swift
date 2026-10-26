import AppKit
@testable import ConceptStudio
import CoreGraphics
import Foundation
import PrevisCore
import RealityKit
import ShotsMedia
import SwiftUI
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
        let expectedDeltaYaw = -40.0 * (2.0 * .pi / 600.0)
        let expectedDeltaPitch = 20.0 * (2.0 * .pi / 600.0)
        #expect(abs(camera.yaw - (initialYaw + expectedDeltaYaw)) < 1e-12)
        #expect(abs(camera.pitch - (initialPitch + expectedDeltaPitch)) < 1e-12)
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

    @Test func verticalAndNearVerticalTrackpadScrollStayInPanModeWhileMouseWheelDollies() {
        let size = PixelSize(width: 800, height: 600)

        // Purely vertical trackpad two-finger scroll (scrollingDeltaX == 0, hasPreciseScrollingDeltas == true)
        // must pan the target without altering distance.
        var verticalTrackpadCamera = EditorCamera.defaultView
        let initialDistance = verticalTrackpadCamera.distance
        let initialTarget = verticalTrackpadCamera.target
        ViewportCameraGestures.applyScrollOrTrackpad(
            to: &verticalTrackpadCamera,
            scrollingDeltaX: 0,
            scrollingDeltaY: 24,
            hasPreciseScrollingDeltas: true,
            optionPressed: false,
            viewportSize: size
        )
        #expect(verticalTrackpadCamera.distance == initialDistance)
        #expect(verticalTrackpadCamera.target != initialTarget)
        #expect(verticalTrackpadCamera.target.y > initialTarget.y)

        // Near-vertical trackpad sequence where scrollingDeltaX crosses above and below 0.01
        // must remain in pan mode across every sample and never dolly.
        var nearVerticalCamera = EditorCamera.defaultView
        let deltaXSamples: [CGFloat] = [0.0, 0.004, -0.008, 0.015, 0.0]
        for deltaX in deltaXSamples {
            let previousTarget = nearVerticalCamera.target
            ViewportCameraGestures.applyScrollOrTrackpad(
                to: &nearVerticalCamera,
                scrollingDeltaX: deltaX,
                scrollingDeltaY: 12,
                hasPreciseScrollingDeltas: true,
                optionPressed: false,
                viewportSize: size
            )
            #expect(nearVerticalCamera.distance == initialDistance)
            #expect(nearVerticalCamera.target.y > previousTarget.y)
        }

        // Discrete mouse wheel (hasPreciseScrollingDeltas == false) dollies along distance without panning target.
        var wheelCamera = EditorCamera.defaultView
        ViewportCameraGestures.applyScrollOrTrackpad(
            to: &wheelCamera,
            scrollingDeltaX: 0,
            scrollingDeltaY: 12,
            hasPreciseScrollingDeltas: false,
            optionPressed: false,
            viewportSize: size
        )
        #expect(wheelCamera.distance < initialDistance)
        #expect(wheelCamera.target == initialTarget)
    }

    @Test @MainActor func appKitHitTestingRoutesScrollAndDragEventsThroughViewportOverlay() throws {
        let store = try makeSampleStore()
        let (window, host) = mountViewport(store: store, size: CGSize(width: 640, height: 480))
        defer { closeOffscreenWindow(window) }
        let hitPoint = CGPoint(x: 320, y: 240)
        let hitView = try #require(host.hitTest(hitPoint))
        let captureView = try #require(hitView as? ViewportScrollWheelOverlay.ScrollCapturingView)
        let session = try #require(captureView.session)

        let initialCamera = session.editorCamera
        let initialCameraEntityPos = session.mapper.cameraEntity(
            for: initialCamera.cameraFrame(for: session.viewportSize)
        ).position

        // 1. Continuous pixel scroll (trackpad vertical two-finger gesture: deltaX == 0, deltaY == 28) pans target.
        let trackpadScrollCG = try #require(
            CGEvent(
                scrollWheelEvent2Source: nil,
                units: .pixel,
                wheelCount: 2,
                wheel1: 28,
                wheel2: 0,
                wheel3: 0
            )
        )
        let trackpadScrollEvent = try #require(NSEvent(cgEvent: trackpadScrollCG))
        #expect(trackpadScrollEvent.hasPreciseScrollingDeltas)
        captureView.scrollWheel(with: trackpadScrollEvent)

        #expect(session.editorCamera.distance == initialCamera.distance)
        #expect(session.editorCamera.target != initialCamera.target)
        #expect(session.editorCamera.target.y > initialCamera.target.y)

        // 2. Discrete line scroll (mouse wheel) dollies distance.
        let beforeWheelDistance = session.editorCamera.distance
        let beforeWheelTarget = session.editorCamera.target
        let mouseWheelCG = try #require(
            CGEvent(
                scrollWheelEvent2Source: nil,
                units: .line,
                wheelCount: 1,
                wheel1: 5,
                wheel2: 0,
                wheel3: 0
            )
        )
        let mouseWheelEvent = try #require(NSEvent(cgEvent: mouseWheelCG))
        #expect(!mouseWheelEvent.hasPreciseScrollingDeltas)
        captureView.scrollWheel(with: mouseWheelEvent)

        #expect(session.editorCamera.distance < beforeWheelDistance)
        #expect(session.editorCamera.target == beforeWheelTarget)

        // 3. Primary click-drag orbits yaw and pitch.
        let beforeOrbitYaw = session.editorCamera.yaw
        let beforeOrbitPitch = session.editorCamera.pitch
        let downEvent = try makeMouseEvent(type: .leftMouseDown, location: CGPoint(x: 200, y: 200), flags: [])
        let dragEvent = try makeMouseEvent(type: .leftMouseDragged, location: CGPoint(x: 245, y: 175), flags: [])
        let upEvent = try makeMouseEvent(type: .leftMouseUp, location: CGPoint(x: 245, y: 175), flags: [])
        captureView.mouseDown(with: downEvent)
        captureView.mouseDragged(with: dragEvent)
        captureView.mouseUp(with: upEvent)

        #expect(session.editorCamera.yaw != beforeOrbitYaw)
        #expect(session.editorCamera.pitch != beforeOrbitPitch)

        // 4. Option + click-drag pans target and updates the mapped RealityKit cameraEntity transform.
        let beforeOptionPanTarget = session.editorCamera.target
        let optDown = try makeMouseEvent(type: .leftMouseDown, location: CGPoint(x: 200, y: 200), flags: [.option])
        let optDrag = try makeMouseEvent(type: .leftMouseDragged, location: CGPoint(x: 235, y: 225), flags: [.option])
        let optUp = try makeMouseEvent(type: .leftMouseUp, location: CGPoint(x: 235, y: 225), flags: [])
        captureView.mouseDown(with: optDown)
        captureView.mouseDragged(with: optDrag)
        captureView.mouseUp(with: optUp)

        #expect(session.editorCamera.target != beforeOptionPanTarget)
        let updatedCameraEntityPos = session.mapper.cameraEntity(
            for: session.editorCamera.cameraFrame(for: session.viewportSize)
        ).position
        #expect(updatedCameraEntityPos != initialCameraEntityPos)
    }

    @Test @MainActor func deletingLastShotOrSceneClearsMappedEntitiesFromViewportStage() throws {
        let store = try makeSampleStore()
        let (window, host) = mountViewport(store: store, size: CGSize(width: 640, height: 480))
        defer { closeOffscreenWindow(window) }
        let captureView = try #require(
            host.hitTest(CGPoint(x: 320, y: 240)) as? ViewportScrollWheelOverlay.ScrollCapturingView
        )
        let session = try #require(captureView.session)

        #expect(store.frame != nil)
        #expect(session.mappedEntityContainerNames.count == 4)

        let shotID = try #require(store.currentShot?.id)
        try store.perform(.deleteShot(shotID))
        host.layoutSubtreeIfNeeded()

        #expect(store.currentShot == nil)
        #expect(store.frame == nil)
        #expect(session.mappedEntityContainerNames.isEmpty)
    }

    @Test @MainActor func liveViewportAppliesSelectedLookCanonicalBackgroundInLightAndDarkAppearances() throws {
        let store = try makeSampleStore()
        let sceneID = try #require(store.currentScene?.id)
        let size = CGSize(width: 640, height: 480)
        let samplePoint = Point2(x: 560, y: 90)
        let presets: [LightingPreset] = [.day, .night, .goldenHour, .interiorWarm, .interiorCool]

        for appearanceName in [NSAppearance.Name.aqua, NSAppearance.Name.darkAqua] {
            let appearance = try #require(NSAppearance(named: appearanceName))
            var renderedByPreset: [LightingPreset: [Int]] = [:]
            for preset in presets {
                try store.perform(.setLighting(sceneID, preset))
                let (window, host) = mountViewport(store: store, size: size, appearance: appearance)
                defer { closeOffscreenWindow(window) }
                let captureView = try #require(
                    host.hitTest(CGPoint(x: 320, y: 240)) as? ViewportScrollWheelOverlay.ScrollCapturingView
                )
                let session = try #require(captureView.session)
                #expect(session.activeLighting == preset)
                #expect(session.mapper.look.lighting == preset)

                let bitmap = try captureHostedBitmap(of: host)
                let actualRGB = rgb(in: bitmap, at: samplePoint)
                let expectedRGB = try expectedHostedRGB(
                    for: ViewportGrid.nsBackgroundColor(for: preset),
                    appearance: appearance
                )
                let diff = abs(actualRGB.0 - expectedRGB.0)
                    + abs(actualRGB.1 - expectedRGB.1)
                    + abs(actualRGB.2 - expectedRGB.2)
                #expect(
                    diff <= 6,
                    "Preset \(preset.rawValue) in \(appearanceName.rawValue) drew \(actualRGB), expected \(expectedRGB)"
                )
                renderedByPreset[preset] = [actualRGB.0, actualRGB.1, actualRGB.2]
            }
            #expect(renderedByPreset[.day] != renderedByPreset[.night])
            #expect(renderedByPreset[.day] != renderedByPreset[.goldenHour])
            #expect(renderedByPreset[.interiorWarm] != renderedByPreset[.interiorCool])
        }
    }

    @Test @MainActor func groundGridMatchesBlockoutSixtyMetreReference() {
        #expect(ViewportGrid.gridExtent == 30)
        let overlayRoot = ViewportGrid.makeOverlayRoot()
        #expect(overlayRoot.name == "viewport.overlayRoot")
        #expect(overlayRoot.parent == nil)
        let grid = overlayRoot.children.first { $0.name == "viewport.groundGrid" }
        #expect(grid != nil)
        let childNames = Set(grid?.children.map(\.name) ?? [])
        #expect(childNames == ["viewport.groundGrid.axes", "viewport.groundGrid.divisions"])
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

        let defaultPixels = try await verifySnapshot(
            label: "d1-default-small.png",
            camera: EditorCamera.defaultView,
            frame: frame,
            look: look,
            overlayRoot: overlayRoot,
            renderer: renderer,
            folder: tempFolder
        )
        _ = try await verifySnapshot(
            label: "d1-top-small.png",
            camera: EditorCamera.topView,
            frame: frame,
            look: look,
            overlayRoot: overlayRoot,
            renderer: renderer,
            folder: tempFolder
        )

        // Determinism check (reference: Blockout tests/e2e/smoke.spec.ts:114-130):
        // rendering defaultView again after an intervening topView render yields byte-identical pixels.
        let repeatedDefaultPixels = try await SnapshotPixels(
            ViewportSnapshotRenderer.renderSnapshot(
                frame: frame,
                look: look,
                camera: EditorCamera.defaultView,
                overlayRoot: overlayRoot,
                size: frame.canvas.pixelSize,
                renderer: renderer
            )
        )
        #expect(defaultPixels.bytes == repeatedDefaultPixels.bytes)

        let cleanWithoutOverlay = try await SnapshotPixels(
            renderer.image(
                of: frame,
                look: look,
                camera: EditorCamera.defaultView.cameraFrame(for: frame.canvas.pixelSize),
                overlay: nil,
                size: frame.canvas.pixelSize
            )
        )
        #expect(cleanWithoutOverlay.bytes != defaultPixels.bytes)
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
}

@MainActor
private func makeSampleStore() throws -> ShotsStore {
    try ShotsStore(
        catalog: ContentCatalog.bundled(),
        document: ShotsSamples.twoPersonWalk(small: true),
        saveURL: nil
    )
}

@MainActor
private func mountViewport(
    store: ShotsStore,
    size: CGSize,
    appearance: NSAppearance? = NSAppearance(named: .aqua)
) -> (NSWindow, NSHostingView<ShotsViewport>) {
    let host = NSHostingView(rootView: ShotsViewport(store: store))
    host.appearance = appearance
    host.frame = NSRect(origin: .zero, size: size)
    let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: size),
        styleMask: [.titled, .closable, .resizable],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    window.appearance = appearance
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    return (window, host)
}

@MainActor
private func closeOffscreenWindow(_ window: NSWindow) {
    window.contentView = nil
    window.delegate = nil
    window.close()
}

@MainActor
private func captureHostedBitmap(of host: NSView) throws -> NSBitmapImageRep {
    host.layoutSubtreeIfNeeded()
    let bounds = host.bounds
    let rep = try #require(host.bitmapImageRepForCachingDisplay(in: bounds))
    host.cacheDisplay(in: bounds, to: rep)
    return rep
}

@MainActor
private func expectedHostedRGB(for nsColor: NSColor, appearance: NSAppearance) throws -> (Int, Int, Int) {
    let swatchSize = CGSize(width: 16, height: 16)
    let host = NSHostingView(rootView: Color(nsColor: nsColor).frame(width: 16, height: 16))
    host.appearance = appearance
    host.frame = NSRect(origin: .zero, size: swatchSize)
    let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: swatchSize),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    window.appearance = appearance
    window.contentView = host
    defer { closeOffscreenWindow(window) }
    let rep = try captureHostedBitmap(of: host)
    return rgb(in: rep, at: Point2(x: 8, y: 8))
}

private func rgb(in rep: NSBitmapImageRep, at point: Point2) -> (Int, Int, Int) {
    let x = min(max(Int(point.x), 0), rep.pixelsWide - 1)
    let y = min(max(Int(point.y), 0), rep.pixelsHigh - 1)
    let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) ?? .black
    return (
        Int((color.redComponent * 255.0).rounded()),
        Int((color.greenComponent * 255.0).rounded()),
        Int((color.blueComponent * 255.0).rounded())
    )
}

private func makeMouseEvent(
    type: NSEvent.EventType,
    location: CGPoint,
    flags: NSEvent.ModifierFlags
) throws -> NSEvent {
    try #require(
        NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        )
    )
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
) async throws -> SnapshotPixels {
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
    return drawnPixels
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
