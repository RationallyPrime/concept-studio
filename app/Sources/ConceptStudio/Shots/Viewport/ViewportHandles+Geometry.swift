import Foundation
import PrevisCore
import RealityKit

extension ViewportHandles {
    static func intersectHorizontalPlane(
        at pixel: Point2,
        planeY: Double,
        camera: EditorCamera,
        size: PixelSize
    ) -> Vec3? {
        let ray = camera.ray(through: pixel, size: size)
        guard abs(ray.direction.y) >= 1e-6 else { return nil }
        let t = (planeY - ray.origin.y) / ray.direction.y
        guard t >= 0, t.isFinite else { return nil }
        return Vec3(
            ray.origin.x + ray.direction.x * t,
            planeY,
            ray.origin.z + ray.direction.z * t
        )
    }

    static func closestAxisScalar(
        at pixel: Point2,
        pivot: Vec3,
        axis: Vec3,
        camera: EditorCamera,
        size: PixelSize
    ) -> Double {
        let ray = camera.ray(through: pixel, size: size)
        let dirLen = (
            ray.direction.x * ray.direction.x
                + ray.direction.y * ray.direction.y
                + ray.direction.z * ray.direction.z
        ).squareRoot()
        guard dirLen > 1e-9 else { return 0 }
        let dRay = Vec3(ray.direction.x / dirLen, ray.direction.y / dirLen, ray.direction.z / dirLen)
        let w0 = Vec3(pivot.x - ray.origin.x, pivot.y - ray.origin.y, pivot.z - ray.origin.z)
        let b = axis.x * dRay.x + axis.y * dRay.y + axis.z * dRay.z
        let d = axis.x * w0.x + axis.y * w0.y + axis.z * w0.z
        let e = dRay.x * w0.x + dRay.y * w0.y + dRay.z * w0.z
        let denom = 1.0 - b * b
        guard denom > 1e-6 else { return 0 }
        return (b * e - d) / denom
    }

    static func horizontalAngle(
        at pixel: Point2,
        pivot: Vec3,
        camera: EditorCamera,
        size: PixelSize
    ) -> Double? {
        if let hit = intersectHorizontalPlane(at: pixel, planeY: pivot.y, camera: camera, size: size) {
            let dx = hit.x - pivot.x
            let dz = hit.z - pivot.z
            if hypot(dx, dz) > 1e-5 {
                return atan2(-dx, -dz)
            }
        }
        guard let center = camera.project(pivot, size: size) else { return nil }
        let sx = pixel.x - center.x
        let sy = pixel.y - center.y
        guard hypot(sx, sy) > 1e-4 else { return nil }
        return atan2(-sx, sy) + camera.yaw
    }
}

extension ViewportHandles {
    static func verticalTiltAngle(
        at pixel: Point2,
        pivot: Vec3,
        heading: Double,
        camera: EditorCamera,
        size: PixelSize
    ) -> Double {
        let ray = camera.ray(through: pixel, size: size)
        let right = Vec3(cos(heading), 0, -sin(heading))
        let forward = Vec3(-sin(heading), 0, -cos(heading))
        let dotRight = ray.direction.x * right.x + ray.direction.z * right.z
        if abs(dotRight) >= 0.08 {
            let diff = Vec3(pivot.x - ray.origin.x, pivot.y - ray.origin.y, pivot.z - ray.origin.z)
            let t = (diff.x * right.x + diff.z * right.z) / dotRight
            if t > 0, t.isFinite {
                let hit = Vec3(
                    ray.origin.x + ray.direction.x * t,
                    ray.origin.y + ray.direction.y * t,
                    ray.origin.z + ray.direction.z * t
                )
                let rel = Vec3(hit.x - pivot.x, hit.y - pivot.y, hit.z - pivot.z)
                let fwdComp = rel.x * forward.x + rel.z * forward.z
                return atan2(rel.y, max(abs(fwdComp), 1e-4))
            }
        }
        let camNormal = Vec3(sin(camera.yaw), 0, cos(camera.yaw))
        let denom = ray.direction.x * camNormal.x + ray.direction.z * camNormal.z
        guard abs(denom) >= 1e-6 else { return 0 }
        let diff = Vec3(pivot.x - ray.origin.x, pivot.y - ray.origin.y, pivot.z - ray.origin.z)
        let t = (diff.x * camNormal.x + diff.z * camNormal.z) / denom
        guard t > 0, t.isFinite else { return 0 }
        let hitY = ray.origin.y + ray.direction.y * t
        return atan2(hitY - pivot.y, 1.0)
    }

    static func panAndTiltDelta(
        for drag: ViewportHandleDragSession,
        at pixel: Point2,
        camera: EditorCamera,
        size: PixelSize
    ) -> (deltaPan: Double, deltaTilt: Double) {
        let pivot = drag.target.worldPivot
        let r0 = max(
            hypot(drag.startPlaneHit.x - pivot.x, drag.startPlaneHit.z - pivot.z),
            0.25
        )
        let currentPanAngle = horizontalAngle(
            at: pixel,
            pivot: pivot,
            camera: camera,
            size: size
        ) ?? drag.startAngleY
        let deltaPan = normalizeAngle(currentPanAngle - drag.startAngleY)

        if let horizHit = intersectHorizontalPlane(at: pixel, planeY: pivot.y, camera: camera, size: size) {
            let rHoriz = hypot(horizHit.x - pivot.x, horizHit.z - pivot.z)
            if abs(rHoriz - r0) <= r0 * 0.02 {
                return (deltaPan, 0)
            }
        }

        let ray = camera.ray(through: pixel, size: size)
        let camNormal = Vec3(sin(camera.yaw), 0, cos(camera.yaw))
        let denom = ray.direction.x * camNormal.x + ray.direction.z * camNormal.z
        guard abs(denom) >= 1e-6 else { return (deltaPan, 0) }
        let anchor = drag.startPlaneHit
        let diff = Vec3(anchor.x - ray.origin.x, anchor.y - ray.origin.y, anchor.z - ray.origin.z)
        let t = (diff.x * camNormal.x + diff.z * camNormal.z) / denom
        guard t > 0, t.isFinite else { return (deltaPan, 0) }
        let hitY = ray.origin.y + ray.direction.y * t
        let deltaTilt = atan2(hitY - pivot.y, r0)
        return (deltaPan, deltaTilt)
    }
}

extension ViewportHandles {
    static func normalizeAngle(_ angle: Double) -> Double {
        var wrapped = (angle + .pi).truncatingRemainder(dividingBy: 2.0 * .pi)
        if wrapped < 0 {
            wrapped += 2.0 * .pi
        }
        return wrapped - .pi
    }

    static func axisVector(for component: ViewportHandleComponent) -> Vec3 {
        switch component {
        case .axisX: Vec3(1, 0, 0)
        case .axisY: Vec3(0, 1, 0)
        case .axisZ: Vec3(0, 0, 1)
        default: Vec3(1, 0, 0)
        }
    }

    static func distanceFromPoint(_ p: Point2, toSegmentFrom a: Point2, to b: Point2) -> Double {
        let abx = b.x - a.x
        let aby = b.y - a.y
        let lenSq = abx * abx + aby * aby
        guard lenSq > 1e-6 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = min(max(((p.x - a.x) * abx + (p.y - a.y) * aby) / lenSq, 0.0), 1.0)
        let projX = a.x + t * abx
        let projY = a.y + t * aby
        return hypot(p.x - projX, p.y - projY)
    }

    static func activeCameraMark(in shot: Shot, at time: Double) -> CameraMark? {
        guard !shot.camera.marks.isEmpty else { return nil }
        return shot.camera.marks.min { lhs, rhs in
            abs(lhs.time - time) < abs(rhs.time - time)
        }
    }

    @MainActor
    static func resolveMountPose(
        for shot: Shot,
        at time: Double,
        in store: ShotsStore
    ) -> ViewportHandleTarget.MountPose? {
        guard shot.camera.rig == .carMount,
              let mountID = shot.camera.mountID
        else { return nil }
        let frameAtMark = store.evaluator?.frame(at: time) ?? store.frame
        guard let mountEntity = frameAtMark?.entities.first(where: { $0.id == mountID }) else { return nil }
        return ViewportHandleTarget.MountPose(position: mountEntity.position, heading: mountEntity.heading)
    }

    @MainActor
    static func evaluatedEntityHeading(
        entityID: EntityID,
        at time: Double,
        in store: ShotsStore
    ) -> Double? {
        let frameAtMark = store.evaluator?.frame(at: time) ?? store.frame
        return frameAtMark?.entities.first(where: { $0.id == entityID })?.heading
    }
}

@MainActor
extension ViewportHandles {
    static func syncOverlay(
        in overlayRoot: Entity,
        store: ShotsStore,
        mode: ViewportHandleMode,
        camera: EditorCamera,
        size: PixelSize
    ) {
        let handlesEntity: Entity
        if let existing = overlayRoot.children.first(where: { $0.name == rootEntityName }) {
            handlesEntity = existing
        } else {
            let created = makeHandlesEntity()
            overlayRoot.addChild(created)
            handlesEntity = created
        }

        guard let target = resolveTarget(in: store, useCommittedDocument: false) else {
            handlesEntity.isEnabled = false
            return
        }

        let geometry = gizmoGeometry(for: target, mode: mode, camera: camera, size: size)
        handlesEntity.isEnabled = true
        handlesEntity.position = SIMD3<Float>(
            Float(geometry.pivot.x),
            Float(geometry.pivot.y),
            Float(geometry.pivot.z)
        )
        let scale = Float(max(geometry.worldRadius, 0.05))
        handlesEntity.scale = SIMD3<Float>(repeating: scale)

        handlesEntity.findEntity(named: "viewport.handles.moveGroup")?.isEnabled = (mode == .move)
        handlesEntity.findEntity(named: "viewport.handles.rotateGroup")?.isEnabled = (mode == .rotate)
        handlesEntity.findEntity(named: "viewport.handles.rotateTilt")?.isEnabled = (
            mode == .rotate && geometry.isCameraTarget
        )
    }

    private static func makeHandlesEntity() -> Entity {
        let root = Entity()
        root.name = rootEntityName
        root.isEnabled = false

        let moveGroup = Entity()
        moveGroup.name = "viewport.handles.moveGroup"
        let planeMesh = MeshResource.generateBox(width: 0.28, height: 0.015, depth: 0.28)
        let planeEntity = ModelEntity(mesh: planeMesh, materials: [UnlitMaterial(color: .systemYellow)])
        planeEntity.name = "viewport.handles.planeXZ"
        moveGroup.addChild(planeEntity)

        let axisX = ModelEntity(
            mesh: MeshResource.generateBox(width: 1.0, height: 0.04, depth: 0.04),
            materials: [UnlitMaterial(color: .systemRed)]
        )
        axisX.name = "viewport.handles.axisX"
        axisX.position = SIMD3<Float>(0.5, 0, 0)
        moveGroup.addChild(axisX)

        let axisY = ModelEntity(
            mesh: MeshResource.generateBox(width: 0.04, height: 1.0, depth: 0.04),
            materials: [UnlitMaterial(color: .systemGreen)]
        )
        axisY.name = "viewport.handles.axisY"
        axisY.position = SIMD3<Float>(0, 0.5, 0)
        moveGroup.addChild(axisY)

        let axisZ = ModelEntity(
            mesh: MeshResource.generateBox(width: 0.04, height: 0.04, depth: 1.0),
            materials: [UnlitMaterial(color: .systemBlue)]
        )
        axisZ.name = "viewport.handles.axisZ"
        axisZ.position = SIMD3<Float>(0, 0, 0.5)
        moveGroup.addChild(axisZ)
        root.addChild(moveGroup)

        let rotateGroup = Entity()
        rotateGroup.name = "viewport.handles.rotateGroup"
        let ringY = ModelEntity(
            mesh: MeshResource.generateCylinder(height: 0.02, radius: 1.0),
            materials: [UnlitMaterial(color: .systemOrange)]
        )
        ringY.name = "viewport.handles.rotateY"
        rotateGroup.addChild(ringY)

        let ringTilt = ModelEntity(
            mesh: MeshResource.generateBox(width: 0.03, height: 1.0, depth: 1.0),
            materials: [UnlitMaterial(color: .systemCyan)]
        )
        ringTilt.name = "viewport.handles.rotateTilt"
        rotateGroup.addChild(ringTilt)
        root.addChild(rotateGroup)

        ViewportGrid.disableOcclusionCulling(on: root)
        return root
    }
}
