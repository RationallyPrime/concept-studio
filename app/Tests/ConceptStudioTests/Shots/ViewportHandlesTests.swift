import AppKit
@testable import ConceptStudio
import Foundation
import PrevisCore
import RealityKit
import SwiftUI
import Testing

@MainActor
@Suite("Viewport D4 move and rotate handles")
struct ViewportHandlesTests {
    @Test
    func entityPlaneAndShiftSingleAxisMoveDragPreviewsThreePointsAndCommitsOnceWithUndoRedo() throws {
        let catalog = try ContentCatalog.bundled()
        var document = ShotsSamples.twoPersonWalk(small: true)
        document.scenes[0].entities[2].placement.scale = 1.25
        let store = ShotsStore(catalog: catalog, document: document, saveURL: nil)
        let camera = EditorCamera.defaultView
        let size = PixelSize(width: 640, height: 480)

        let chairID = "ent_000000000003"
        store.selection = .entities([chairID])
        let beforeDocument = store.document
        let initialRevision = try #require(store.currentScene?.revision)
        let initialChair = try #require(store.currentScene?.entities.first(where: { $0.id == chairID }))
        let startPivot = initialChair.placement.position
        let startPixel = try #require(camera.project(startPivot, size: size))

        var drag = ViewportHandles.beginDrag(
            at: startPixel,
            in: store,
            mode: .move,
            camera: camera,
            size: size
        )
        #expect(drag != nil)
        #expect(drag?.component == .planeXZ)

        let waypoints = [
            Vec3(startPivot.x - 0.35, startPivot.y, startPivot.z + 0.25),
            Vec3(startPivot.x - 0.70, startPivot.y, startPivot.z + 0.55),
            Vec3(startPivot.x - 1.10, startPivot.y, startPivot.z + 0.85),
        ]
        for waypoint in waypoints {
            let wpPixel = try #require(camera.project(waypoint, size: size))
            let previewCmd = ViewportHandles.updateDrag(
                &drag,
                at: wpPixel,
                in: store,
                camera: camera,
                size: size
            )
            #expect(previewCmd != nil)
            #expect(store.preview == previewCmd)
            #expect(store.document == beforeDocument)
            #expect(store.document.scenes[0].revision == initialRevision)
            let previewChair = try #require(store.currentScene?.entities.first(where: { $0.id == chairID }))
            #expect(distance(previewChair.placement.position, waypoint) < 0.005)
            #expect(previewChair.placement.scale == 1.25)
        }

        let committed = ViewportHandles.endDrag(&drag, in: store, camera: camera, size: size)
        #expect(committed)
        #expect(drag == nil)
        #expect(store.preview == nil)
        #expect(store.document.scenes[0].revision == initialRevision + 1)
        #expect(store.canUndo)

        let movedChair = try #require(store.currentScene?.entities.first(where: { $0.id == chairID }))
        #expect(distance(movedChair.placement.position, waypoints[2]) < 0.005)
        #expect(movedChair.placement.scale == 1.25)

        store.undo()
        #expect(store.document == beforeDocument)
        #expect(store.preview == nil)
        store.redo()
        let redoneChair = try #require(store.currentScene?.entities.first(where: { $0.id == chairID }))
        #expect(distance(redoneChair.placement.position, waypoints[2]) < 0.005)
    }
}

extension ViewportHandlesTests {
    @Test
    func shiftPlaneDragAndAxisHandlesConstrainTranslationToSingleAxes() throws {
        let catalog = try ContentCatalog.bundled()
        let document = ShotsSamples.twoPersonWalk(small: true)
        let store = ShotsStore(catalog: catalog, document: document, saveURL: nil)
        let camera = EditorCamera.defaultView
        let size = PixelSize(width: 640, height: 480)

        let chairID = "ent_000000000003"
        store.selection = .entities([chairID])
        let basePos = try #require(store.currentScene?.entities.first(where: { $0.id == chairID })?.placement.position)
        let startPixel = try #require(camera.project(basePos, size: size))

        var shiftDrag = ViewportHandles.beginDrag(
            at: startPixel,
            in: store,
            mode: .move,
            camera: camera,
            size: size
        )
        let diagonalTarget = Vec3(basePos.x + 0.9, basePos.y, basePos.z + 0.25)
        let diagonalPixel = try #require(camera.project(diagonalTarget, size: size))
        _ = ViewportHandles.updateDrag(
            &shiftDrag,
            at: diagonalPixel,
            shiftPressed: true,
            in: store,
            camera: camera,
            size: size
        )
        _ = ViewportHandles.endDrag(&shiftDrag, in: store, camera: camera, size: size)
        let afterShiftX = try #require(store.currentScene?.entities.first(where: { $0.id == chairID }))
        #expect(abs(afterShiftX.placement.position.x - (basePos.x + 0.9)) < 0.005)
        #expect(abs(afterShiftX.placement.position.z - basePos.z) < 1e-6)

        store.undo()
        var axisYDrag = ViewportHandles.beginDrag(
            at: startPixel,
            in: store,
            mode: .move,
            component: .axisY,
            camera: camera,
            size: size
        )
        let elevatedTarget = Vec3(basePos.x, basePos.y + 0.65, basePos.z)
        let elevatedPixel = try #require(camera.project(elevatedTarget, size: size))
        _ = ViewportHandles.updateDrag(&axisYDrag, at: elevatedPixel, in: store, camera: camera, size: size)
        _ = ViewportHandles.endDrag(&axisYDrag, in: store, camera: camera, size: size)
        let afterAxisY = try #require(store.currentScene?.entities.first(where: { $0.id == chairID }))
        #expect(abs(afterAxisY.placement.position.y - 0.65) < 0.005)
        #expect(abs(afterAxisY.placement.position.x - basePos.x) < 1e-6)
        #expect(abs(afterAxisY.placement.position.z - basePos.z) < 1e-6)
    }

    @Test
    func quarterTurnRotationSetsEntityActorMarkAndCameraMarkHeadingWithinOneHundredthRadian() throws {
        let catalog = try ContentCatalog.bundled()
        let document = ShotsSamples.twoPersonWalk(small: true)
        let store = ShotsStore(catalog: catalog, document: document, saveURL: nil)
        let camera = EditorCamera.defaultView
        let size = PixelSize(width: 640, height: 480)

        // 1. Entity quarter-turn (+pi / 2) rotation via setPlacement
        let chairID = "ent_000000000003"
        store.selection = .entities([chairID])
        let chairStart = try #require(store.currentScene?.entities.first(where: { $0.id == chairID }))
        let chairTarget = try #require(ViewportHandles.resolveTarget(in: store, useCommittedDocument: true))
        let chairGizmo = ViewportHandles.gizmoGeometry(for: chairTarget, mode: .rotate, camera: camera, size: size)
        let ring0 = try #require(camera.project(chairGizmo.ringPointWorld(angle: 0), size: size))
        let ring45 = try #require(camera.project(chairGizmo.ringPointWorld(angle: .pi / 4.0), size: size))
        let ring90 = try #require(camera.project(chairGizmo.ringPointWorld(angle: .pi / 2.0), size: size))

        var entityRotDrag = ViewportHandles.beginDrag(
            at: ring0,
            in: store,
            mode: .rotate,
            camera: camera,
            size: size
        )
        #expect(entityRotDrag != nil)
        _ = ViewportHandles.updateDrag(&entityRotDrag, at: ring45, in: store, camera: camera, size: size)
        #expect(store.preview != nil)
        _ = ViewportHandles.updateDrag(&entityRotDrag, at: ring90, in: store, camera: camera, size: size)
        #expect(ViewportHandles.endDrag(&entityRotDrag, in: store, camera: camera, size: size))
        #expect(store.preview == nil)

        let rotatedChair = try #require(store.currentScene?.entities.first(where: { $0.id == chairID }))
        let expectedChairHeading = ViewportHandles.normalizeAngle(chairStart.placement.heading + .pi / 2.0)
        #expect(abs(rotatedChair.placement.heading - expectedChairHeading) < 0.01)
        #expect(rotatedChair.placement.position == chairStart.placement.position)
        #expect(rotatedChair.placement.scale == chairStart.placement.scale)
    }
}

extension ViewportHandlesTests {
    @Test
    func actorMarkAndCameraMarkMoveAndRotatePreserveUnrelatedFieldsAndHandleMountedCamera() throws {
        let catalog = try ContentCatalog.bundled()
        var document = ShotsSamples.twoPersonWalk(small: true)
        let manID = "ent_000000000001"
        let markID = "mark_000000000002"
        document.scenes[0].blocking[0].tracks[0].marks[1].hold = 0.4
        document.scenes[0].blocking[0].tracks[0].marks[1].via = [Vec3(-0.8, 0, 0.2)]
        document.scenes[0].blocking[0].tracks[0].marks[1].joints = [.elbowR: 0.35]
        document.scenes[0].blocking[0].tracks[0].marks[1].arriveHeading = 0.0

        let camMarkID = "cam_000000000002"
        document.scenes[0].shots[0].camera.marks[1].hold = 0.5
        document.scenes[0].shots[0].camera.marks[1].via = [Vec3(0.1, 1.55, 5.2)]
        document.scenes[0].shots[0].camera.marks[1].roll = 0.08
        document.scenes[0].shots[0].camera.marks[1].focusDistance = 4.2

        let store = ShotsStore(catalog: catalog, document: document, saveURL: nil)
        let camera = EditorCamera.defaultView
        let size = PixelSize(width: 640, height: 480)

        // 1. Actor mark move through 3 points + quarter-turn rotate
        store.selection = .actorMark(manID, markID)
        let origActorMark = try #require(
            store.currentScene?.blocking.first?.tracks.first?.marks.first(where: { $0.id == markID })
        )
        let markStartPx = try #require(camera.project(origActorMark.position, size: size))
        var markMoveDrag = ViewportHandles.beginDrag(
            at: markStartPx,
            in: store,
            mode: .move,
            camera: camera,
            size: size
        )
        let markPts = [
            Vec3(origActorMark.position.x + 0.2, 0, 0.3),
            Vec3(origActorMark.position.x + 0.5, 0, 0.6),
            Vec3(origActorMark.position.x + 0.8, 0, 0.9),
        ]
        for pt in markPts {
            let px = try #require(camera.project(pt, size: size))
            _ = ViewportHandles.updateDrag(&markMoveDrag, at: px, in: store, camera: camera, size: size)
            #expect(store.preview != nil)
        }
        #expect(ViewportHandles.endDrag(&markMoveDrag, in: store, camera: camera, size: size))
        #expect(store.preview == nil)

        let movedActorMark = try #require(
            store.currentScene?.blocking.first?.tracks.first?.marks.first(where: { $0.id == markID })
        )
        #expect(distance(movedActorMark.position, markPts[2]) < 0.005)
        #expect(movedActorMark.hold == 0.4)
        #expect(movedActorMark.via == [Vec3(-0.8, 0, 0.2)])
        #expect(movedActorMark.joints == [.elbowR: 0.35])

        let actorTarget = try #require(ViewportHandles.resolveTarget(in: store, useCommittedDocument: true))
        let actorGizmo = ViewportHandles.gizmoGeometry(for: actorTarget, mode: .rotate, camera: camera, size: size)
        let mRing0 = try #require(camera.project(actorGizmo.ringPointWorld(angle: 0), size: size))
        let mRing90 = try #require(camera.project(actorGizmo.ringPointWorld(angle: .pi / 2.0), size: size))
        var markRotDrag = ViewportHandles.beginDrag(
            at: mRing0,
            in: store,
            mode: .rotate,
            camera: camera,
            size: size
        )
        _ = ViewportHandles.updateDrag(&markRotDrag, at: mRing90, in: store, camera: camera, size: size)
        #expect(ViewportHandles.endDrag(&markRotDrag, in: store, camera: camera, size: size))
        let rotatedActorMark = try #require(
            store.currentScene?.blocking.first?.tracks.first?.marks.first(where: { $0.id == markID })
        )
        #expect(abs((rotatedActorMark.arriveHeading ?? 0) - (.pi / 2.0)) < 0.01)
        #expect(rotatedActorMark.hold == 0.4)
        #expect(rotatedActorMark.joints == [.elbowR: 0.35])

        // 2. Camera mark move + pan and tilt rotation
        try verifyCameraMarkMoveAndRotate(in: store, camMarkID: camMarkID, size: size)
    }
}

extension ViewportHandlesTests {
    private func verifyCameraMarkMoveAndRotate(
        in store: ShotsStore,
        camMarkID: MarkID,
        size: PixelSize
    ) throws {
        var camEditor = EditorCamera.defaultView
        camEditor.target = Vec3(0, 1.5, 4.5)
        camEditor.yaw = 0.65
        store.selection = .cameraMark(camMarkID)
        let origCamMark = try #require(store.currentShot?.camera.marks.first(where: { $0.id == camMarkID }))
        let cStartPx = try #require(camEditor.project(origCamMark.position, size: size))

        var camMoveDrag = ViewportHandles.beginDrag(
            at: cStartPx,
            in: store,
            mode: .move,
            camera: camEditor,
            size: size
        )
        let camDest = Vec3(0.75, origCamMark.position.y, 4.1)
        let camDestPx = try #require(camEditor.project(camDest, size: size))
        _ = ViewportHandles.updateDrag(&camMoveDrag, at: camDestPx, in: store, camera: camEditor, size: size)
        #expect(ViewportHandles.endDrag(&camMoveDrag, in: store, camera: camEditor, size: size))

        let movedCamMark = try #require(store.currentShot?.camera.marks.first(where: { $0.id == camMarkID }))
        #expect(distance(movedCamMark.position, camDest) < 0.005)
        #expect(movedCamMark.hold == 0.5)
        #expect(movedCamMark.via == [Vec3(0.1, 1.55, 5.2)])
        #expect(movedCamMark.roll == 0.08)
        #expect(movedCamMark.focusDistance == 4.2)

        let camTarget = try #require(ViewportHandles.resolveTarget(in: store, useCommittedDocument: true))
        let camGizmo = ViewportHandles.gizmoGeometry(for: camTarget, mode: .rotate, camera: camEditor, size: size)
        let cRing0 = try #require(camEditor.project(camGizmo.ringPointWorld(angle: 0), size: size))
        let cRing90 = try #require(camEditor.project(camGizmo.ringPointWorld(angle: .pi / 2.0), size: size))
        var camPanDrag = ViewportHandles.beginDrag(
            at: cRing0,
            in: store,
            mode: .rotate,
            camera: camEditor,
            size: size
        )
        _ = ViewportHandles.updateDrag(&camPanDrag, at: cRing90, in: store, camera: camEditor, size: size)
        #expect(ViewportHandles.endDrag(&camPanDrag, in: store, camera: camEditor, size: size))
        let pannedCamMark = try #require(store.currentShot?.camera.marks.first(where: { $0.id == camMarkID }))
        #expect(abs(pannedCamMark.pan - (.pi / 2.0)) < 0.01)
        #expect(abs(pannedCamMark.tilt - origCamMark.tilt) < 0.01)

        // Vertical tilt drag on .rotateTilt (+0.35 rad)
        let tiltTarget = try #require(ViewportHandles.resolveTarget(in: store, useCommittedDocument: true))
        let tiltGizmo = ViewportHandles.gizmoGeometry(for: tiltTarget, mode: .rotate, camera: camEditor, size: size)
        let tArc0 = try #require(camEditor.project(tiltGizmo.tiltArcPointWorld(tiltAngle: 0), size: size))
        let tArcUp = try #require(camEditor.project(tiltGizmo.tiltArcPointWorld(tiltAngle: 0.35), size: size))
        var camTiltDrag = ViewportHandles.beginDrag(
            at: tArc0,
            in: store,
            mode: .rotate,
            component: .rotateTilt,
            camera: camEditor,
            size: size
        )
        _ = ViewportHandles.updateDrag(&camTiltDrag, at: tArcUp, in: store, camera: camEditor, size: size)
        #expect(ViewportHandles.endDrag(&camTiltDrag, in: store, camera: camEditor, size: size))
        let tiltedCamMark = try #require(store.currentShot?.camera.marks.first(where: { $0.id == camMarkID }))
        #expect(abs(tiltedCamMark.tilt - 0.35) < 0.01)
        #expect(abs(tiltedCamMark.pan - (.pi / 2.0)) < 0.01)
        #expect(tiltedCamMark.roll == 0.08)
        #expect(tiltedCamMark.focusDistance == 4.2)
    }
}

extension ViewportHandlesTests {
    @Test
    func escapeCancelsDragAndReadOnlyNoOpErrorAndInvalidationKeepPreviewClean() throws {
        let catalog = try ContentCatalog.bundled()
        let document = ShotsSamples.twoPersonWalk(small: true)
        let store = ShotsStore(catalog: catalog, document: document, saveURL: nil)
        let session = ViewportLiveSession()
        let camera = EditorCamera.defaultView
        let size = PixelSize(width: 640, height: 480)
        let chairID = "ent_000000000003"
        store.selection = .entities([chairID])
        let beforeDoc = store.document
        let startPivot = try #require(store.currentScene?.entities.first(where: { $0.id == chairID })?.placement
            .position)
        let startPx = try #require(camera.project(startPivot, size: size))
        let movedPx = try #require(camera.project(Vec3(startPivot.x - 0.8, 0, startPivot.z + 0.5), size: size))

        // 1. Escape cancels active drag, clears preview, and prevents subsequent update/end from committing
        session.viewportSize = size
        #expect(session.beginHandleDrag(at: startPx, in: store))
        session.updateHandleDrag(at: movedPx, shiftPressed: false, in: store)
        #expect(store.preview != nil)
        #expect(ViewportPicking.handleKeyDown(
            charactersIgnoringModifiers: "\u{1B}",
            keyCode: 53,
            in: store,
            session: session
        ))
        #expect(store.preview == nil)
        #expect(session.activeHandleDrag == nil)
        session.updateHandleDrag(at: movedPx, shiftPressed: false, in: store)
        session.endHandleDrag(at: movedPx, shiftPressed: false, in: store)
        #expect(store.document == beforeDoc)
        #expect(!store.canUndo)

        // 2. No-op drag (release at start point) does not bump revision or add undo entry
        #expect(session.beginHandleDrag(at: startPx, in: store))
        session.endHandleDrag(at: startPx, shiftPressed: false, in: store)
        #expect(store.preview == nil)
        #expect(store.document == beforeDoc)
        #expect(!store.canUndo)

        // 3. Selection invalidation mid-drag cancels and clears preview
        #expect(session.beginHandleDrag(at: startPx, in: store))
        session.updateHandleDrag(at: movedPx, shiftPressed: false, in: store)
        #expect(store.preview != nil)
        store.selection = .none
        session.updateHandleDrag(at: movedPx, shiftPressed: false, in: store)
        #expect(store.preview == nil)
        #expect(session.activeHandleDrag == nil)

        // 4. Read-only store disables handles and G/R while preserving selection and camera orbit
        let readOnlyStore = ShotsStore(catalog: catalog, document: document, saveURL: nil, readOnly: true)
        readOnlyStore.selection = .entities([chairID])
        #expect(ViewportHandles.resolveTarget(in: readOnlyStore) == nil)
        #expect(!session.beginHandleDrag(at: startPx, in: readOnlyStore))
        #expect(!ViewportPicking.handleKeyDown(
            charactersIgnoringModifiers: "g",
            keyCode: 5,
            in: readOnlyStore,
            session: session
        ))
        #expect(!ViewportPicking.handleKeyDown(
            charactersIgnoringModifiers: "r",
            keyCode: 15,
            in: readOnlyStore,
            session: session
        ))
    }

    @Test
    func constantScreenSizeGizmoMaintainsPixelRadiusAcrossDistinctCameraDistancesAndStaysInOverlayOnly() throws {
        let catalog = try ContentCatalog.bundled()
        let document = ShotsSamples.twoPersonWalk(small: true)
        let store = ShotsStore(catalog: catalog, document: document, saveURL: nil)
        let session = ViewportLiveSession()
        let size = PixelSize(width: 640, height: 480)
        store.selection = .entities(["ent_000000000001"])
        let target = try #require(ViewportHandles.resolveTarget(in: store))

        let distances: [Double] = [3.0, 6.5, 18.0]
        var worldRadii: [Double] = []
        for dist in distances {
            var cam = EditorCamera.defaultView
            cam.target = target.worldPivot
            cam.distance = dist
            let geom = ViewportHandles.gizmoGeometry(for: target, mode: .move, camera: cam, size: size)
            worldRadii.append(geom.worldRadius)
            let projRadius = try #require(geom.projectedScreenRadius(camera: cam, size: size))
            #expect(abs(projRadius - ViewportHandleGizmoGeometry.targetScreenRadiusPixels) < 0.05)

            session.editorCamera = cam
            session.sync(with: store, frame: store.frame, size: size)
            let handlesEntity = try #require(session.overlayRoot.findEntity(named: ViewportHandles.rootEntityName))
            #expect(handlesEntity.isEnabled)
            #expect(abs(Double(handlesEntity.scale.x) - geom.worldRadius) < 1e-4)
        }
        #expect(worldRadii[2] > worldRadii[1] && worldRadii[1] > worldRadii[0])
        #expect(abs(worldRadii[2] / worldRadii[0] - 6.0) < 0.01)
        #expect(session.mapper.root.findEntity(named: ViewportHandles.rootEntityName) == nil)
    }
}

extension ViewportHandlesTests {
    private func distance(_ a: Vec3, _ b: Vec3) -> Double {
        let dx = a.x - b.x
        let dy = a.y - b.y
        let dz = a.z - b.z
        return (dx * dx + dy * dy + dz * dz).squareRoot()
    }
}

extension ViewportHandlesTests {
    @Test
    func cameraSelectionCarMountMoveCombinedPanTiltAndErrorClearPreview() throws {
        let catalog = try ContentCatalog.bundled()
        let document = ShotsSamples.twoPersonWalk(small: true)
        let store = ShotsStore(catalog: catalog, document: document, saveURL: nil)
        let size = PixelSize(width: 640, height: 480)
        var camEditor = EditorCamera.defaultView
        camEditor.target = Vec3(0, 1.6, 6.0)
        camEditor.yaw = 0.55

        // 1. .camera selection resolves active camera mark at playhead and supports combined pan + tilt
        store.playhead = 0
        store.selection = .camera
        let target = try #require(ViewportHandles.resolveTarget(in: store, useCommittedDocument: true))
        let gizmo = ViewportHandles.gizmoGeometry(for: target, mode: .rotate, camera: camEditor, size: size)
        let startWorld = gizmo.ringPointWorld(angle: 0)
        let startPx = try #require(camEditor.project(startWorld, size: size))
        var panTiltDrag = ViewportHandles.beginDrag(
            at: startPx,
            in: store,
            mode: .rotate,
            component: .rotatePanAndTilt,
            camera: camEditor,
            size: size
        )
        let liftedWorld = Vec3(
            startWorld.x - gizmo.worldRadius * 0.4,
            startWorld.y + gizmo.worldRadius * tan(0.22),
            startWorld.z
        )
        let liftedPx = try #require(camEditor.project(liftedWorld, size: size))
        _ = ViewportHandles.updateDrag(&panTiltDrag, at: liftedPx, in: store, camera: camEditor, size: size)
        #expect(ViewportHandles.endDrag(&panTiltDrag, in: store, camera: camEditor, size: size))
        let updatedCam0 = try #require(store.currentShot?.camera.marks.first)
        #expect(abs(updatedCam0.pan) > 0.1)
        #expect(abs(updatedCam0.tilt) > 0.05)

        // 2. Car-mounted camera mark move drag converts world target into mount-local coordinates
        let shotID = try #require(store.currentShotID)
        store.run(.setCameraRig(shotID, sensor: .super35, rig: .carMount, intensity: 0))
        store.run(.setMount(shotID, "ent_000000000001"))
        let mountedTarget = try #require(ViewportHandles.resolveTarget(in: store, useCommittedDocument: true))
        let mountedStartWorld = mountedTarget.worldPivot
        let mStartPx = try #require(camEditor.project(mountedStartWorld, size: size))
        let mGoalWorld = Vec3(mountedStartWorld.x + 0.6, mountedStartWorld.y, mountedStartWorld.z - 0.4)
        let mGoalPx = try #require(camEditor.project(mGoalWorld, size: size))
        var mDrag = ViewportHandles.beginDrag(at: mStartPx, in: store, mode: .move, camera: camEditor, size: size)
        _ = ViewportHandles.updateDrag(&mDrag, at: mGoalPx, in: store, camera: camEditor, size: size)
        #expect(ViewportHandles.endDrag(&mDrag, in: store, camera: camEditor, size: size))
        let afterMountTarget = try #require(ViewportHandles.resolveTarget(in: store, useCommittedDocument: true))
        #expect(distance(afterMountTarget.worldPivot, mGoalWorld) < 0.01)

        // 3. Invalid command (NaN position) reports through store.onError on release and still clears store.preview
        var capturedError: String?
        store.onError = { capturedError = $0 }
        var badDrag = ViewportHandles.beginDrag(at: mGoalPx, in: store, mode: .move, camera: camEditor, size: size)
        badDrag?.latestCommand = .setPlacement(
            "ent_000000000001",
            Placement(position: Vec3(.nan, 0, 0), heading: 0, scale: 1)
        )
        store.preview = badDrag?.latestCommand
        _ = ViewportHandles.endDrag(&badDrag, in: store, camera: camEditor, size: size)
        #expect(store.preview == nil)
        #expect(capturedError != nil)
    }
}
