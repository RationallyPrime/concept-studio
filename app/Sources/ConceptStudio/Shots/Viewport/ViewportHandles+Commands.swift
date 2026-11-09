import Foundation
import PrevisCore

/// The commands a D4 handle drag previews and commits (`LANE-D-VIEWPORT.md` D4, `CONTRACTS.md` section 7).
/// Reference: Blockout `src/renderer/viewport/SceneManager.ts:1171-1277` (`commitGizmo`).
extension ViewportHandles {
    static func commands(
        for drag: ViewportHandleDragSession,
        at pixel: Point2,
        shiftPressed: Bool = false,
        camera: EditorCamera,
        size: PixelSize
    ) -> [ShotsCommand] {
        let pivot = drag.target.worldPivot
        switch drag.component {
        case .planeXZ:
            let currentHit = intersectHorizontalPlane(
                at: pixel,
                planeY: pivot.y,
                camera: camera,
                size: size
            ) ?? drag.startPlaneHit
            let rawDelta = Vec3(
                currentHit.x - drag.startPlaneHit.x,
                0,
                currentHit.z - drag.startPlaneHit.z
            )
            let delta: Vec3 = if !shiftPressed {
                rawDelta
            } else if abs(rawDelta.x) >= abs(rawDelta.z) {
                Vec3(rawDelta.x, 0, 0)
            } else {
                Vec3(0, 0, rawDelta.z)
            }
            return applyMove(delta: delta, for: drag)

        case .axisX, .axisY, .axisZ:
            let axis = axisVector(for: drag.component)
            let currentScalar = closestAxisScalar(
                at: pixel,
                pivot: pivot,
                axis: axis,
                camera: camera,
                size: size
            )
            let step = currentScalar - drag.startAxisScalar
            let delta = Vec3(axis.x * step, axis.y * step, axis.z * step)
            return applyMove(delta: delta, for: drag)

        case .rotateY:
            let currentAngle = horizontalAngle(
                at: pixel,
                pivot: pivot,
                camera: camera,
                size: size
            ) ?? drag.startAngleY
            let deltaHeading = normalizeAngle(currentAngle - drag.startAngleY)
            return applyRotation(deltaHeading: deltaHeading, deltaTilt: 0, for: drag)

        case .rotateTilt:
            let currentTilt = verticalTiltAngle(
                at: pixel,
                pivot: pivot,
                heading: drag.target.worldHeading,
                camera: camera,
                size: size
            )
            let deltaTilt = currentTilt - drag.startTiltAngle
            return applyRotation(deltaHeading: 0, deltaTilt: deltaTilt, for: drag)

        case .rotatePanAndTilt:
            let (deltaPan, deltaTilt) = panAndTiltDelta(
                for: drag,
                at: pixel,
                camera: camera,
                size: size
            )
            return applyRotation(deltaHeading: deltaPan, deltaTilt: deltaTilt, for: drag)
        }
    }
}

extension ViewportHandles {
    /// An entity with marks moves as the arrow-key nudge moves it, and turns about its drawn body: the placement,
    /// every mark and every `via` waypoint in the shot's take, as one batch (Blockout `SceneManager.ts:1250-1270`).
    private static func blockedEntityCommands(
        _ id: EntityID,
        for drag: ViewportHandleDragSession,
        by delta: Vec3,
        turning turn: (pivot: Vec3, angle: Double)?
    ) -> [ShotsCommand] {
        guard let scene = drag.baselineDocument.scenes.first(where: { $0.id == drag.sceneID }) else { return [] }
        return ViewportKeyboard.entityNudgeCommands(
            for: [id],
            by: delta,
            turning: turn,
            in: scene,
            currentShot: scene.shots.first { $0.id == drag.shotID }
        )
    }

    private static func applyMove(delta: Vec3, for drag: ViewportHandleDragSession) -> [ShotsCommand] {
        if case let .entity(id, _, body) = drag.target, body != nil {
            return blockedEntityCommands(id, for: drag, by: delta, turning: nil)
        }
        return [applyMove(delta: delta, to: drag.target)]
    }

    private static func applyRotation(
        deltaHeading: Double,
        deltaTilt: Double,
        for drag: ViewportHandleDragSession
    ) -> [ShotsCommand] {
        if case let .entity(id, _, body?) = drag.target {
            // No turn at all when the ring has not moved, so a click commits nothing (turning by 0 is not exact).
            let turn = abs(deltaHeading) > 1e-9 ? (pivot: body.position, angle: deltaHeading) : nil
            return blockedEntityCommands(id, for: drag, by: .zero, turning: turn)
        }
        return [applyRotation(deltaHeading: deltaHeading, deltaTilt: deltaTilt, to: drag.target)]
    }

    private static func applyMove(delta: Vec3, to target: ViewportHandleTarget) -> ShotsCommand {
        switch target {
        case let .entity(id, initialPlacement, _):
            var updated = initialPlacement
            updated.position = Vec3(
                initialPlacement.position.x + delta.x,
                initialPlacement.position.y + delta.y,
                initialPlacement.position.z + delta.z
            )
            return .setPlacement(id, updated)

        case let .actorMark(shotID, entityID, initialMark, _):
            var updated = initialMark
            updated.position = Vec3(
                initialMark.position.x + delta.x,
                initialMark.position.y + delta.y,
                initialMark.position.z + delta.z
            )
            return .updateActorMark(shotID, entityID, updated)

        case let .cameraMark(shotID, initialMark, mountPose):
            var updated = initialMark
            let newWorldPos = Vec3(
                target.worldPivot.x + delta.x,
                target.worldPivot.y + delta.y,
                target.worldPivot.z + delta.z
            )
            if let mount = mountPose {
                let dx = newWorldPos.x - mount.position.x
                let dz = newWorldPos.z - mount.position.z
                let c = cos(mount.heading)
                let s = sin(mount.heading)
                updated.position = Vec3(
                    dx * c - dz * s,
                    newWorldPos.y - mount.position.y,
                    dx * s + dz * c
                )
            } else {
                updated.position = newWorldPos
            }
            return .updateCameraMark(shotID, updated)
        }
    }

    private static func applyRotation(
        deltaHeading: Double,
        deltaTilt: Double,
        to target: ViewportHandleTarget
    ) -> ShotsCommand {
        switch target {
        case let .entity(id, initialPlacement, _):
            guard abs(deltaHeading) > 1e-9 else { return .setPlacement(id, initialPlacement) }
            var updated = initialPlacement
            updated.heading = normalizeAngle(initialPlacement.heading + deltaHeading)
            return .setPlacement(id, updated)

        case let .actorMark(shotID, entityID, initialMark, initialHeading):
            guard abs(deltaHeading) > 1e-9 else { return .updateActorMark(shotID, entityID, initialMark) }
            var updated = initialMark
            updated.arriveHeading = normalizeAngle(initialHeading + deltaHeading)
            return .updateActorMark(shotID, entityID, updated)

        case let .cameraMark(shotID, initialMark, _):
            guard abs(deltaHeading) > 1e-9 || abs(deltaTilt) > 1e-9 else {
                return .updateCameraMark(shotID, initialMark)
            }
            var updated = initialMark
            updated.pan = normalizeAngle(initialMark.pan + deltaHeading)
            updated.tilt = min(max(initialMark.tilt + deltaTilt, -maxTiltRadians), maxTiltRadians)
            return .updateCameraMark(shotID, updated)
        }
    }
}
