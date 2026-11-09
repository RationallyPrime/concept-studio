import AppKit
import Foundation
import PrevisCore
import RealityKit

/// Manipulator mode for the 3D blocking viewport (`LANE-D-VIEWPORT.md` D4, `CONTRACTS.md` section 7).
/// Owned by Lane D so `ShotsTool` remains unchanged across lanes.
enum ViewportHandleMode: String, Sendable, Equatable {
    case move
    case rotate
}

/// Interactive handle sub-component on the active viewport manipulator gizmo.
enum ViewportHandleComponent: String, Sendable, Equatable {
    case planeXZ
    case axisX
    case axisY
    case axisZ
    case rotateY
    case rotateTilt
    case rotatePanAndTilt
}

/// Resolved target of the active viewport manipulator handle (`LANE-D-VIEWPORT.md` lines 121-125).
enum ViewportHandleTarget: Sendable, Equatable {
    /// An evaluated world position and heading: a camera mount's, or an entity's body at the playhead.
    struct Pose: Sendable, Equatable {
        var position: Vec3
        var heading: Double
    }

    /// `body` is the entity's evaluated pose at the playhead when it has marks in the shot's take. The handle
    /// sits there, and a drag moves the placement, the marks and their `via` waypoints together (Blockout's
    /// "choreography rides along", `SceneManager.ts:1250-1270`). Without marks it is nil: the handle sits on the
    /// placement and edits only it.
    case entity(id: EntityID, initialPlacement: Placement, body: Pose?)
    case actorMark(shotID: ShotID, entityID: EntityID, initialMark: ActorMark, initialHeading: Double)
    case cameraMark(shotID: ShotID, initialMark: CameraMark, mountPose: Pose?)

    var worldPivot: Vec3 {
        switch self {
        case let .entity(_, placement, body):
            return body?.position ?? placement.position
        case let .actorMark(_, _, mark, _):
            return mark.position
        case let .cameraMark(_, mark, mountPose):
            guard let mount = mountPose else { return mark.position }
            let c = cos(mount.heading)
            let s = sin(mount.heading)
            return Vec3(
                mount.position.x + mark.position.x * c + mark.position.z * s,
                mount.position.y + mark.position.y,
                mount.position.z - mark.position.x * s + mark.position.z * c
            )
        }
    }

    var worldHeading: Double {
        switch self {
        case let .entity(_, placement, body):
            body?.heading ?? placement.heading
        case let .actorMark(_, _, _, heading):
            heading
        case let .cameraMark(_, mark, mountPose):
            mark.pan + (mountPose?.heading ?? 0)
        }
    }

    var isCameraTarget: Bool {
        if case .cameraMark = self { return true }
        return false
    }
}

/// Constant-screen-size 3D handle geometry evaluated for a given `EditorCamera` and `PixelSize`
/// (`LANE-D-VIEWPORT.md` lines 126-127).
struct ViewportHandleGizmoGeometry: Sendable, Equatable {
    static let targetScreenRadiusPixels: Double = 56.0

    var pivot: Vec3
    var heading: Double
    var mode: ViewportHandleMode
    var isCameraTarget: Bool
    var cameraDepth: Double
    var worldRadius: Double
    var screenRadiusPixels: Double
    var projectedPivot: Point2?

    var axisXTipWorld: Vec3 {
        Vec3(pivot.x + worldRadius, pivot.y, pivot.z)
    }

    var axisYTipWorld: Vec3 {
        Vec3(pivot.x, pivot.y + worldRadius, pivot.z)
    }

    var axisZTipWorld: Vec3 {
        Vec3(pivot.x, pivot.y, pivot.z + worldRadius)
    }

    func ringPointWorld(angle: Double) -> Vec3 {
        Vec3(
            pivot.x - worldRadius * sin(angle),
            pivot.y,
            pivot.z - worldRadius * cos(angle)
        )
    }

    func tiltArcPointWorld(tiltAngle: Double) -> Vec3 {
        Vec3(
            pivot.x - worldRadius * cos(tiltAngle) * sin(heading),
            pivot.y + worldRadius * sin(tiltAngle),
            pivot.z - worldRadius * cos(tiltAngle) * cos(heading)
        )
    }

    func projectedScreenRadius(camera: EditorCamera, size: PixelSize) -> Double? {
        guard let center = camera.project(pivot, size: size) else { return nil }
        let viewMat = camera.cameraFrame(for: size).viewMatrix()
        let right = Vec3(viewMat.m[0], viewMat.m[4], viewMat.m[8])
        let edgeWorld = Vec3(
            pivot.x + right.x * worldRadius,
            pivot.y + right.y * worldRadius,
            pivot.z + right.z * worldRadius
        )
        guard let edge = camera.project(edgeWorld, size: size) else { return nil }
        return hypot(edge.x - center.x, edge.y - center.y)
    }
}

/// Active handle drag state tracking the baseline committed target and latest preview command.
struct ViewportHandleDragSession: Sendable, Equatable {
    var baselineDocument: ShotsDocument
    var sceneID: SceneID
    var shotID: ShotID
    var selection: ShotsSelection
    var target: ViewportHandleTarget
    var component: ViewportHandleComponent
    var startPixel: Point2
    var startPlaneHit: Vec3
    var startAxisScalar: Double
    var startAngleY: Double
    var startTiltAngle: Double
    /// What release commits as one undo step, and what `store.preview` holds meanwhile; empty before any move.
    var latestCommands: [ShotsCommand]
}

/// Pure CPU handle math, hit-testing, drag-preview lifecycle, and editor-overlay entity synchronization
/// (`LANE-D-VIEWPORT.md` D4).
///
/// Reference: Blockout `src/renderer/viewport/SceneManager.ts:257-266, 855-860, 960-966, 1025-1063, 1130-1277`
/// and `src/renderer/viewport/Viewport.tsx:303-327`.
/// Intentional Swift/RealityKit deviations:
/// - Hand-built constant-screen-size handle math replaces Three.js `TransformControls` (macOS has no visionOS
///   `ManipulationComponent`, `LANE-D-VIEWPORT.md` lines 164-165).
/// - Handle drags write `store.preview` during movement and commit it on release as one undo step via `store.run`
///   rather than mutating the document in place: one typed command (`setPlacement`, `updateActorMark`,
///   `updateCameraMark`), or, for an entity with marks, `setPlacement` plus an `updateActorMark` per mark, built by
///   the arrow-key nudge's `ViewportKeyboard.entityNudgeCommands`.
enum ViewportHandles {
    static let rootEntityName = "viewport.handles"
    static let maxTiltRadians: Double = .pi / 2.0 - 0.01

    @MainActor
    static func resolveTarget(in store: ShotsStore, useCommittedDocument: Bool = false) -> ViewportHandleTarget? {
        guard !store.isReadOnly,
              store.tool == .select,
              let sceneID = store.currentSceneID,
              let shotID = store.currentShotID
        else { return nil }

        let sourceDoc = useCommittedDocument ? store.document : nil
        guard let scene = (sourceDoc?.scenes.first { $0.id == sceneID }) ?? store.currentScene,
              let shot = scene.shots.first(where: { $0.id == shotID })
        else { return nil }

        switch store.selection {
        case .none:
            return nil
        case let .entities(ids):
            guard let anchorID = ids.last,
                  let entity = scene.entities.first(where: { $0.id == anchorID })
            else { return nil }
            let take = scene.blocking.first { $0.id == shot.blockingTakeID } ?? scene.blocking.first
            guard take?.tracks.first(where: { $0.entityID == entity.id })?.marks.isEmpty == false else {
                return .entity(id: entity.id, initialPlacement: entity.placement, body: nil)
            }
            // Blockout attaches the gizmo to the drawn body (`SceneManager.ts:1060`, posed by `applyTime`).
            guard let body = evaluatedBody(
                of: entity.id,
                in: sourceDoc == nil || store.preview.isEmpty ? nil : scene,
                shotID: shot.id,
                store: store
            ) else {
                return nil
            }
            return .entity(id: entity.id, initialPlacement: entity.placement, body: body)
        case let .actorMark(entityID, markID):
            let take = scene.blocking.first { $0.id == shot.blockingTakeID } ?? scene.blocking.first
            guard let entity = scene.entities.first(where: { $0.id == entityID }),
                  let mark = take?.tracks.first(where: { $0.entityID == entityID })?.marks
                      .first(where: { $0.id == markID })
            else { return nil }
            let heading = mark.arriveHeading
                ?? evaluatedEntityHeading(entityID: entityID, at: mark.time, in: store)
                ?? entity.placement.heading
            return .actorMark(shotID: shot.id, entityID: entityID, initialMark: mark, initialHeading: heading)
        case let .cameraMark(markID):
            guard let mark = shot.camera.marks.first(where: { $0.id == markID }) else { return nil }
            let mountPose = resolveMountPose(for: shot, at: mark.time, in: store)
            return .cameraMark(shotID: shot.id, initialMark: mark, mountPose: mountPose)
        case .camera:
            let playheadTime = FrameGrid.time(ofFrame: store.playhead)
            guard let mark = activeCameraMark(in: shot, at: playheadTime) else { return nil }
            let mountPose = resolveMountPose(for: shot, at: mark.time, in: store)
            return .cameraMark(shotID: shot.id, initialMark: mark, mountPose: mountPose)
        }
    }
}

extension ViewportHandles {
    static func gizmoGeometry(
        for target: ViewportHandleTarget,
        mode: ViewportHandleMode,
        camera: EditorCamera,
        size: PixelSize
    ) -> ViewportHandleGizmoGeometry {
        let pivot = target.worldPivot
        let camFrame = camera.cameraFrame(for: size)
        let cameraSpacePivot = camFrame.viewMatrix().transform(pivot)
        let depth = max(-cameraSpacePivot.z, 0.25)
        let height = Double(max(size.height, 1))
        let screenRadius = ViewportHandleGizmoGeometry.targetScreenRadiusPixels
        let worldRadius = screenRadius * (2.0 * depth * tan(camFrame.verticalFOV / 2.0)) / height
        return ViewportHandleGizmoGeometry(
            pivot: pivot,
            heading: target.worldHeading,
            mode: mode,
            isCameraTarget: target.isCameraTarget,
            cameraDepth: depth,
            worldRadius: worldRadius,
            screenRadiusPixels: screenRadius,
            projectedPivot: camera.project(pivot, size: size)
        )
    }

    static func pickHandle(
        at pixel: Point2,
        for target: ViewportHandleTarget,
        mode: ViewportHandleMode,
        camera: EditorCamera,
        size: PixelSize
    ) -> ViewportHandleComponent? {
        let gizmo = gizmoGeometry(for: target, mode: mode, camera: camera, size: size)
        guard let center = gizmo.projectedPivot else { return nil }
        let distToCenter = hypot(pixel.x - center.x, pixel.y - center.y)

        switch mode {
        case .move:
            if distToCenter <= 16.0 {
                return .planeXZ
            }
            let candidates: [(ViewportHandleComponent, Vec3)] = [
                (.axisX, gizmo.axisXTipWorld),
                (.axisY, gizmo.axisYTipWorld),
                (.axisZ, gizmo.axisZTipWorld),
            ]
            var bestComponent: ViewportHandleComponent?
            var bestDistance = 12.0
            for (component, tipWorld) in candidates {
                guard let tipScreen = camera.project(tipWorld, size: size) else { continue }
                let segDist = distanceFromPoint(pixel, toSegmentFrom: center, to: tipScreen)
                if segDist <= bestDistance {
                    bestDistance = segDist
                    bestComponent = component
                }
            }
            if let bestComponent { return bestComponent }
            return distToCenter <= 24.0 ? .planeXZ : nil

        case .rotate:
            if let hit = intersectHorizontalPlane(
                at: pixel,
                planeY: gizmo.pivot.y,
                camera: camera,
                size: size
            ) {
                let radial = hypot(hit.x - gizmo.pivot.x, hit.z - gizmo.pivot.z)
                if radial >= gizmo.worldRadius * 0.12, radial <= gizmo.worldRadius * 1.65 {
                    return target.isCameraTarget ? .rotatePanAndTilt : .rotateY
                }
            }
            if abs(distToCenter - gizmo.screenRadiusPixels) <= 18.0 || distToCenter <= 24.0 {
                return target.isCameraTarget ? .rotatePanAndTilt : .rotateY
            }
            return nil
        }
    }
}

@MainActor
extension ViewportHandles {
    static func beginDrag(
        at startPixel: Point2,
        in store: ShotsStore,
        mode: ViewportHandleMode,
        component explicitComponent: ViewportHandleComponent? = nil,
        camera: EditorCamera,
        size: PixelSize
    ) -> ViewportHandleDragSession? {
        guard !store.isReadOnly,
              store.tool == .select,
              let sceneID = store.currentSceneID,
              let shotID = store.currentShotID,
              let target = resolveTarget(in: store, useCommittedDocument: true),
              let component = explicitComponent ?? pickHandle(
                  at: startPixel,
                  for: target,
                  mode: mode,
                  camera: camera,
                  size: size
              ) else { return nil }

        let pivot = target.worldPivot
        let planeHit = intersectHorizontalPlane(
            at: startPixel,
            planeY: pivot.y,
            camera: camera,
            size: size
        ) ?? pivot
        let axisScalar = closestAxisScalar(
            at: startPixel,
            pivot: pivot,
            axis: axisVector(for: component),
            camera: camera,
            size: size
        )
        let angleY = horizontalAngle(
            at: startPixel,
            pivot: pivot,
            camera: camera,
            size: size
        ) ?? target.worldHeading
        let tiltAngle = verticalTiltAngle(
            at: startPixel,
            pivot: pivot,
            heading: target.worldHeading,
            camera: camera,
            size: size
        )

        return ViewportHandleDragSession(
            baselineDocument: store.document,
            sceneID: sceneID,
            shotID: shotID,
            selection: store.selection,
            target: target,
            component: component,
            startPixel: startPixel,
            startPlaneHit: planeHit,
            startAxisScalar: axisScalar,
            startAngleY: angleY,
            startTiltAngle: tiltAngle,
            latestCommands: []
        )
    }
}

@MainActor
extension ViewportHandles {
    @discardableResult
    static func updateDrag(
        _ drag: inout ViewportHandleDragSession?,
        at pixel: Point2,
        shiftPressed: Bool = false,
        in store: ShotsStore,
        camera: EditorCamera,
        size: PixelSize
    ) -> [ShotsCommand] {
        guard var current = drag else { return [] }
        guard isDragStillValid(current, in: store) else {
            cancelDrag(&drag, in: store)
            return []
        }
        let nextCommands = commands(
            for: current,
            at: pixel,
            shiftPressed: shiftPressed,
            camera: camera,
            size: size
        )
        current.latestCommands = nextCommands
        drag = current
        store.preview = nextCommands
        return nextCommands
    }

    @discardableResult
    static func endDrag(
        _ drag: inout ViewportHandleDragSession?,
        at pixel: Point2? = nil,
        shiftPressed: Bool = false,
        in store: ShotsStore,
        camera: EditorCamera,
        size: PixelSize
    ) -> Bool {
        guard var current = drag else { return false }
        guard isDragStillValid(current, in: store) else {
            cancelDrag(&drag, in: store)
            return false
        }
        if let pixel {
            current.latestCommands = commands(
                for: current,
                at: pixel,
                shiftPressed: shiftPressed,
                camera: camera,
                size: size
            )
        }
        drag = nil
        let finalCommands = current.latestCommands
        if finalCommands.count == 1 {
            store.run(finalCommands[0])
        } else if !finalCommands.isEmpty {
            store.run(finalCommands)
        }
        store.preview = []
        return !finalCommands.isEmpty
    }

    static func cancelDrag(_ drag: inout ViewportHandleDragSession?, in store: ShotsStore) {
        drag = nil
        store.preview = []
    }

    static func isDragStillValid(_ drag: ViewportHandleDragSession, in store: ShotsStore) -> Bool {
        guard !store.isReadOnly,
              store.tool == .select,
              store.currentSceneID == drag.sceneID,
              store.currentShotID == drag.shotID,
              store.selection == drag.selection,
              store.document == drag.baselineDocument,
              drag.target.matchesCommittedTarget(
                  in: store.document,
                  sceneID: drag.sceneID,
                  shotID: drag.shotID
              ),
              drag.latestCommands.isEmpty || !store.preview.isEmpty
        else { return false }
        return true
    }
}
