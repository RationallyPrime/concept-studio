import AppKit
@testable import ConceptStudio
import CoreGraphics
import Foundation
import PrevisCore
import RealityKit
import ShotsMedia
import SwiftUI
import Testing

private let overlaysRenderingEnabled = ShotFrameRenderer.isAvailable
    && ProcessInfo.processInfo.environment["SHOTS_SKIP_RENDER"] == nil

@Suite("Viewport D2 overlays, playback and sign-check snapshots")
struct ViewportOverlaysTests {
    @Test @MainActor
    func playheadMarksPathsCameraBodyAndSelectionSyncInLiveSessionWithoutMutatingMapperRoot() throws {
        let store = try ShotsStore(
            catalog: ContentCatalog.bundled(),
            document: ShotsSamples.twoPersonWalk(small: true),
            saveURL: nil
        )
        let session = ViewportLiveSession()
        let size = PixelSize(width: 320, height: 576)
        session.sync(with: store, frame: store.frame, size: size)

        let marksGroup = try #require(
            session.overlayRoot.children.first { $0.name == ViewportOverlays.marksGroupName }
        )
        let pathsGroup = try #require(
            session.overlayRoot.children.first { $0.name == ViewportOverlays.pathsGroupName }
        )
        let cameraBody = try #require(
            session.overlayRoot.children.first { $0.name == ViewportOverlays.cameraBodyName }
        )
        let selectionGroup = try #require(
            session.overlayRoot.children.first { $0.name == ViewportOverlays.selectionGroupName }
        )

        #expect(marksGroup.isEnabled)
        #expect(marksGroup.children.count == 8)
        #expect(pathsGroup.isEnabled)
        let pathNames = Set(pathsGroup.children.map(\.name))
        #expect(pathNames.contains("viewport.path.entity:ent_000000000001"))
        #expect(pathNames.contains("viewport.path.entity:ent_000000000002"))
        #expect(pathNames.contains("viewport.path.camera"))

        #expect(cameraBody.isEnabled)
        #expect(abs(cameraBody.position.z - 6.0) < 1e-4)
        #expect(Set(cameraBody.children.map(\.name)) == ["cameraBody.housing", "cameraBody.lens", "cameraBody.frustum"])
        #expect(selectionGroup.children.isEmpty)

        // Toggles for marks and paths.
        session.toggleMarks()
        #expect(!session.showMarks)
        #expect(!marksGroup.isEnabled)
        session.togglePaths()
        #expect(!session.showPaths)
        #expect(!pathsGroup.isEnabled)
        session.toggleMarks()
        session.togglePaths()
        #expect(marksGroup.isEnabled && pathsGroup.isEnabled)

        // Selection boxes draw in overlayRoot without mutating mapper.root.
        let initialMapperNames = session.mappedEntityContainerNames
        store.selection = .entities(["ent_000000000001", "ent_000000000002"])
        session.sync(with: store, frame: store.frame, size: size)
        #expect(Set(selectionGroup.children.map(\.name)) == [
            "viewport.selectionBox.entity:ent_000000000001",
            "viewport.selectionBox.entity:ent_000000000002",
        ])
        #expect(pathsGroup.children.contains { $0.name.hasPrefix("viewport.path.chevron.") })
        #expect(pathsGroup.children.contains { $0.name.hasPrefix("viewport.path.timeLabel:") })
        #expect(session.mappedEntityContainerNames == initialMapperNames)

        store.selection = .camera
        session.sync(with: store, frame: store.frame, size: size)
        #expect(selectionGroup.children.map(\.name) == ["viewport.selectionBox.camera"])

        store.selection = .actorMark("ent_000000000001", "mark_000000000001")
        session.sync(with: store, frame: store.frame, size: size)
        #expect(selectionGroup.children.map(\.name) == [
            "viewport.selectionBox.actorMark:ent_000000000001:mark_000000000001",
        ])

        store.selection = .cameraMark("cam_000000000001")
        session.sync(with: store, frame: store.frame, size: size)
        #expect(selectionGroup.children.map(\.name) == ["viewport.selectionBox.cameraMark:cam_000000000001"])

        // Advancing store.playhead moves posed actors and the shot camera body.
        let manFrame0 = try #require(store.frame?.entities.first { $0.id == "ent_000000000001" })
        store.playhead = 11
        session.sync(with: store, frame: store.frame, size: size)
        let manFrame11 = try #require(store.frame?.entities.first { $0.id == "ent_000000000001" })
        let camZ11 = cameraBody.position.z
        store.playhead = 21
        session.sync(with: store, frame: store.frame, size: size)
        let manFrame21 = try #require(store.frame?.entities.first { $0.id == "ent_000000000001" })
        let camZ21 = cameraBody.position.z

        #expect(manFrame0.bounds.min.x < manFrame11.bounds.min.x)
        #expect(manFrame11.bounds.min.x < manFrame21.bounds.min.x)
        #expect(camZ11 < 6.0 && camZ21 < camZ11)
        #expect(abs(camZ21 - 4.5) < 1e-4)
    }

    @Test @MainActor
    func hostedViewportHUDMarksAndPathsButtonsHitTestAndToggleOverlaysWhileStagePreservesCameraGestures() throws {
        let store = try ShotsStore(
            catalog: ContentCatalog.bundled(),
            document: ShotsSamples.twoPersonWalk(small: true),
            saveURL: nil
        )
        let size = CGSize(width: 640, height: 480)
        let host = NSHostingView(rootView: ShotsViewport(store: store))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer {
            window.contentView = nil
            window.delegate = nil
            window.close()
        }
        host.layoutSubtreeIfNeeded()

        let stageHit = try #require(host.hitTest(CGPoint(x: 320, y: 240)))
        let captureView = try #require(stageHit as? ViewportScrollWheelOverlay.ScrollCapturingView)
        let session = try #require(captureView.session)
        let toggleBar = try #require(findToggleBar(in: host))
        toggleBar.layoutSubtreeIfNeeded()

        let marksCenterInWindow = toggleBar.marksButton.convert(
            CGPoint(x: toggleBar.marksButton.bounds.midX, y: toggleBar.marksButton.bounds.midY),
            to: host.superview
        )
        let pathsCenterInWindow = toggleBar.pathsButton.convert(
            CGPoint(x: toggleBar.pathsButton.bounds.midX, y: toggleBar.pathsButton.bounds.midY),
            to: host.superview
        )
        #expect(host.hitTest(marksCenterInWindow) === toggleBar.marksButton)
        #expect(host.hitTest(pathsCenterInWindow) === toggleBar.pathsButton)

        let marksGroup = try #require(session.overlayRoot.children.first { $0.name == ViewportOverlays.marksGroupName })
        let pathsGroup = try #require(session.overlayRoot.children.first { $0.name == ViewportOverlays.pathsGroupName })
        #expect(session.showMarks && marksGroup.isEnabled && toggleBar.marksButton.state == .on)
        #expect(session.showPaths && pathsGroup.isEnabled && toggleBar.pathsButton.state == .on)

        toggleBar.marksButton.performClick(nil)
        #expect(!session.showMarks && !marksGroup.isEnabled && toggleBar.marksButton.state == .off)
        toggleBar.marksButton.performClick(nil)
        #expect(session.showMarks && marksGroup.isEnabled && toggleBar.marksButton.state == .on)

        toggleBar.pathsButton.performClick(nil)
        #expect(!session.showPaths && !pathsGroup.isEnabled && toggleBar.pathsButton.state == .off)
        toggleBar.pathsButton.performClick(nil)
        #expect(session.showPaths && pathsGroup.isEnabled && toggleBar.pathsButton.state == .on)
    }

    @Test(.enabled(if: overlaysRenderingEnabled))
    @MainActor
    func sampleFirstGuideAndLastFrameSnapshotsShowPosedPeopleMovingAndIsolateOverlayFromExport() async throws {
        let store = try ShotsStore(
            catalog: ContentCatalog.bundled(),
            document: ShotsSamples.twoPersonWalk(small: true),
            saveURL: nil
        )
        let scene = try #require(store.currentScene)
        let look = PrevisLook(scene: scene)
        let renderer = try ShotFrameRenderer()
        let session = ViewportLiveSession()
        let tempFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("d2-snapshots-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempFolder) }

        let checkpoints: [(Int, String)] = [
            (0, "d2-sample-first-small.png"),
            (11, "d2-sample-guide-small.png"),
            (21, "d2-sample-last-small.png"),
        ]
        var snapshots: [OverlaySnapshotPixels] = []
        var manCenters: [Point2] = []
        var womanCenters: [Point2] = []

        for (frameIndex, filename) in checkpoints {
            store.playhead = frameIndex
            let frame = try #require(store.frame)
            session.sync(with: store, frame: frame, size: frame.canvas.pixelSize)
            let image = try await ViewportSnapshotRenderer.renderSnapshot(
                frame: frame,
                look: look,
                camera: session.editorCamera,
                overlayRoot: session.overlayRoot,
                size: frame.canvas.pixelSize,
                renderer: renderer
            )
            let savedURL = try ViewportSnapshotRenderer.writeSnapshot(
                image: image,
                named: filename,
                directory: tempFolder
            )
            #expect(FileManager.default.fileExists(atPath: savedURL.path))
            if ProcessInfo.processInfo.environment["SHOTS_SNAPSHOT_DIR"] != nil {
                _ = try ViewportSnapshotRenderer.writeSnapshot(image: image, named: filename)
            }
            let pixels = try OverlaySnapshotPixels(image)
            snapshots.append(pixels)
            let manPoint = try projectEntityCentre(id: "ent_000000000001", in: frame, camera: session.editorCamera)
            let womanPoint = try projectEntityCentre(id: "ent_000000000002", in: frame, camera: session.editorCamera)
            #expect(pixels.differsFromDayBackground(at: manPoint))
            #expect(pixels.differsFromDayBackground(at: womanPoint))
            manCenters.append(manPoint)
            womanCenters.append(womanPoint)
        }
        #expect(manCenters[0].x < manCenters[1].x && manCenters[1].x < manCenters[2].x)
        #expect(womanCenters[0].x > womanCenters[1].x && womanCenters[1].x > womanCenters[2].x)
        #expect(snapshots[0].bytes != snapshots[1].bytes)
        #expect(snapshots[1].bytes != snapshots[2].bytes)
        #expect(snapshots[0].differs(from: snapshots[2], at: manCenters[0]))
        #expect(snapshots[0].differs(from: snapshots[2], at: manCenters[2]))

        let lastFrame = try #require(store.frame)
        let cleanExport = try await OverlaySnapshotPixels(
            renderer.image(
                of: lastFrame,
                look: look,
                camera: session.editorCamera.cameraFrame(for: lastFrame.canvas.pixelSize),
                overlay: nil,
                size: lastFrame.canvas.pixelSize
            )
        )
        #expect(cleanExport.bytes != snapshots[2].bytes)
        #expect(session.overlayRoot.parent == nil)
    }

    @Test(.enabled(if: overlaysRenderingEnabled))
    @MainActor
    func sideViewSignCheckSnapshotShowsJabCrossWaveAndSitPoses() async throws {
        let catalog = try ContentCatalog.bundled()
        let doc = try makeSideViewSignCheckDocument(catalog: catalog)
        let store = ShotsStore(catalog: catalog, document: doc, saveURL: nil)
        let scene = try #require(store.currentScene)
        let frame = try #require(store.frame)
        let look = PrevisLook(scene: scene)
        let renderer = try ShotFrameRenderer()
        let session = ViewportLiveSession()
        // Side camera at +X looking toward -X (yaw = +pi/2), so each actor's forward (-Z) points right in the image.
        session.editorCamera = EditorCamera(
            target: Vec3(0, 1.05, 0),
            distance: 6.4,
            yaw: .pi * 0.5,
            pitch: 0.06
        )
        let size = PixelSize(width: 576, height: 320)
        session.sync(with: store, frame: frame, size: size)

        let jabActor = try #require(frame.entities.first { $0.id == "ent_jab" })
        let waveActor = try #require(frame.entities.first { $0.id == "ent_wave" })
        let sitActor = try #require(frame.entities.first { $0.id == "ent_sit" })

        let jabWrist = try keypoint(.rightWrist, in: jabActor)
        let jabNeck = try keypoint(.neck, in: jabActor)
        #expect(jabNeck.z - jabWrist.z > 0.3)

        let waveWrist = try keypoint(.rightWrist, in: waveActor)
        let waveHead = try max(keypoint(.leftEar, in: waveActor).y, keypoint(.rightEar, in: waveActor).y)
        #expect(waveWrist.y > waveHead)

        let sitKnee = try keypoint(.rightKnee, in: sitActor)
        let sitHip = try keypoint(.rightHip, in: sitActor)
        #expect(sitHip.z - sitKnee.z > 0.2)

        let tempFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("d2-sign-check-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempFolder) }

        let image = try await ViewportSnapshotRenderer.renderSnapshot(
            frame: frame,
            look: look,
            camera: session.editorCamera,
            overlayRoot: session.overlayRoot,
            size: size,
            renderer: renderer
        )
        let savedURL = try ViewportSnapshotRenderer.writeSnapshot(
            image: image,
            named: "d2-sign-check-side.png",
            directory: tempFolder
        )
        #expect(FileManager.default.fileExists(atPath: savedURL.path))
        if ProcessInfo.processInfo.environment["SHOTS_SNAPSHOT_DIR"] != nil {
            _ = try ViewportSnapshotRenderer.writeSnapshot(image: image, named: "d2-sign-check-side.png")
        }

        let pixels = try OverlaySnapshotPixels(image)
        for worldPoint in [jabWrist, jabNeck, waveWrist, sitKnee, sitHip] {
            let projected = try #require(session.editorCamera.project(worldPoint, size: size))
            #expect(projected.x >= 0 && projected.x < Double(size.width))
            #expect(projected.y >= 0 && projected.y < Double(size.height))
            #expect(pixels.differsFromDayBackground(at: projected), "Keypoint at \(projected) was background")
        }
    }

    @Test(.enabled(if: overlaysRenderingEnabled))
    @MainActor
    func sideViewSignCheckSnapshotReproducesAuthoredSitDownPeakKeyframeDiscrepancy() async throws {
        let catalog = try ContentCatalog.bundled()
        #expect(catalog.motion("sit") == nil)
        let doc = try makeSideViewSignCheckDocument(catalog: catalog, useSitDownPeakKeyframe: true)
        let store = ShotsStore(catalog: catalog, document: doc, saveURL: nil)
        let scene = try #require(store.currentScene)
        let frame = try #require(store.frame)
        let look = PrevisLook(scene: scene)
        let renderer = try ShotFrameRenderer()
        let session = ViewportLiveSession()
        session.editorCamera = EditorCamera(
            target: Vec3(0, 1.05, 0),
            distance: 6.4,
            yaw: .pi * 0.5,
            pitch: 0.06
        )
        let size = PixelSize(width: 576, height: 320)
        session.sync(with: store, frame: frame, size: size)

        let sitDownActor = try #require(frame.entities.first { $0.id == "ent_sit" })
        let sitDownKnee = try keypoint(.rightKnee, in: sitDownActor)
        let sitDownHip = try keypoint(.rightHip, in: sitDownActor)
        // Discrepancy reproducer: motions.v1.json "sit-down" peak (t = 1.1) authors positive hipLX/hipRX = +1.4,
        // which under PersonRig.angles (a.hipL.x -= joint(.hipLX)) swings thighs backward (+Z) so knees land
        // behind the hips (sitDownKnee.z > sitDownHip.z) rather than ahead of the hips (-Z).
        #expect(sitDownKnee.z - sitDownHip.z > 0.3)

        let tempFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("d2-sign-check-sitdown-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempFolder) }

        let image = try await ViewportSnapshotRenderer.renderSnapshot(
            frame: frame,
            look: look,
            camera: session.editorCamera,
            overlayRoot: session.overlayRoot,
            size: size,
            renderer: renderer
        )
        let savedURL = try ViewportSnapshotRenderer.writeSnapshot(
            image: image,
            named: "d2-sign-check-sit-down-peak.png",
            directory: tempFolder
        )
        #expect(FileManager.default.fileExists(atPath: savedURL.path))
        if ProcessInfo.processInfo.environment["SHOTS_SNAPSHOT_DIR"] != nil {
            _ = try ViewportSnapshotRenderer.writeSnapshot(image: image, named: "d2-sign-check-sit-down-peak.png")
        }
        let pixels = try OverlaySnapshotPixels(image)
        let projectedKnee = try #require(session.editorCamera.project(sitDownKnee, size: size))
        #expect(pixels.differsFromDayBackground(at: projectedKnee))
    }
}

private struct SignCheckPoseSpec {
    let id: String
    let name: String
    let z: Double
    let gait: Gait
    let joints: [Joint: Double]
}

@MainActor
private func findToggleBar(in view: NSView) -> ViewportOverlayTogglesRepresentable.ToggleBarView? {
    if let toggleBar = view as? ViewportOverlayTogglesRepresentable.ToggleBarView {
        return toggleBar
    }
    for subview in view.subviews {
        if let found = findToggleBar(in: subview) {
            return found
        }
    }
    return nil
}

private func makeSideViewSignCheckDocument(
    catalog: ContentCatalog,
    useSitDownPeakKeyframe: Bool = false
) throws -> ShotsDocument {
    let jabJoints = try #require(
        catalog.motion("jab-cross")?.keyframes.min { abs($0.t - 0.3) < abs($1.t - 0.3) }?.joints
    )
    let waveJoints = try #require(
        catalog.motion("wave")?.keyframes.min { abs($0.t - 0.55) < abs($1.t - 0.55) }?.joints
    )
    let sitDownJoints = try #require(
        catalog.motion("sit-down")?.keyframes.min { abs($0.t - 1.1) < abs($1.t - 1.1) }?.joints
    )
    let sitSpec = useSitDownPeakKeyframe
        ? SignCheckPoseSpec(id: "ent_sit", name: "Sit-Down-Peak", z: 1.2, gait: .stand, joints: sitDownJoints)
        : SignCheckPoseSpec(id: "ent_sit", name: "Sit", z: 1.2, gait: .sit, joints: [:])
    let specs: [SignCheckPoseSpec] = [
        SignCheckPoseSpec(id: "ent_jab", name: "Jab-Cross", z: -1.2, gait: .stand, joints: jabJoints),
        SignCheckPoseSpec(id: "ent_wave", name: "Wave", z: 0.0, gait: .stand, joints: waveJoints),
        sitSpec,
    ]
    let entities = specs.map { spec in
        PrevisEntity(
            id: spec.id,
            assetID: "person.man",
            name: spec.name,
            placement: Placement(position: Vec3(0, 0, spec.z), heading: 0, scale: 1)
        )
    }
    let tracks = specs.enumerated().map { idx, spec in
        Track(
            entityID: spec.id,
            marks: [
                ActorMark(
                    id: "mark_sign_\(idx + 1)",
                    time: 0,
                    hold: 1,
                    easeIn: 0,
                    easeOut: 0,
                    position: Vec3(0, 0, spec.z),
                    gait: spec.gait,
                    arriveHeading: 0,
                    joints: spec.joints
                ),
            ]
        )
    }
    var shot = Shot.make(id: "shot_sign", name: "SignCheck", takeID: "take_sign", cameraMarkID: "cam_sign")
    shot.frameCount = 22
    shot.canvas = ShotCanvas(width: 576, height: 320)
    let scene = PrevisScene(
        id: "scene_sign",
        name: "Sign Check",
        revision: 0,
        lighting: .day,
        entities: entities,
        blocking: [BlockingTake(id: "take_sign", name: "Master", tracks: tracks)],
        shots: [shot]
    )
    return ShotsDocument(version: ShotsDocument.currentVersion, scenes: [scene])
}

private func keypoint(_ name: KeypointName, in entity: EntityFrame) throws -> Vec3 {
    try #require(entity.keypoints.first { $0.name == name }?.position)
}

private func projectEntityCentre(
    id: EntityID,
    in frame: SceneFrame,
    camera: EditorCamera,
    size: PixelSize? = nil
) throws -> Point2 {
    let entity = try #require(frame.entities.first { $0.id == id })
    let centre = Vec3(
        (entity.bounds.min.x + entity.bounds.max.x) * 0.5,
        (entity.bounds.min.y + entity.bounds.max.y) * 0.5,
        (entity.bounds.min.z + entity.bounds.max.z) * 0.5
    )
    return try #require(camera.project(centre, size: size ?? frame.canvas.pixelSize))
}

private struct OverlaySnapshotPixels {
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

    func differsFromDayBackground(at point: Point2) -> Bool {
        let (r, g, b) = rgb(at: point)
        return abs(r - 57) + abs(g - 64) + abs(b - 72) > 24
    }

    func differs(from other: OverlaySnapshotPixels, at point: Point2) -> Bool {
        let (r1, g1, b1) = rgb(at: point)
        let (r2, g2, b2) = other.rgb(at: point)
        return abs(r1 - r2) + abs(g1 - g2) + abs(b1 - b2) > 12
    }
}
