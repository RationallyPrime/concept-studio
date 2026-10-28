import AppKit
import Foundation
import PrevisCore

/// Pure CPU picking and tool-action helpers for the 3D blocking viewport (`LANE-D-VIEWPORT.md` D3).
///
/// Reference: Blockout `src/renderer/viewport/SceneManager.ts:828-958` and `src/renderer/store.ts:498-586`.
/// Intentional Swift/RealityKit deviations:
/// - Entity picking intersects `EditorCamera.ray(through:size:)` against `SceneFrame.entities` (`PosedPart`) on the
///   CPU rather than Three.js `Raycaster.intersectObjects` (`LANE-D-VIEWPORT.md` lines 35-37, 107).
enum ViewportPicking {
    struct RayHit: Sendable, Equatable {
        var entityID: EntityID
        var partID: String
        var distance: Double
        var worldPoint: Vec3
    }

    /// Returns the nearest entity hit along the camera ray through `pixel` (top-left origin, `y` down).
    static func pickEntity(
        at pixel: Point2,
        in frame: SceneFrame,
        camera: EditorCamera,
        size: PixelSize
    ) -> EntityID? {
        pickNearestPart(at: pixel, in: frame, camera: camera, size: size)?.entityID
    }

    /// Detailed nearest-part hit for CPU picking diagnostics and tests.
    static func pickNearestPart(
        at pixel: Point2,
        in frame: SceneFrame,
        camera: EditorCamera,
        size: PixelSize
    ) -> RayHit? {
        let ray = camera.ray(through: pixel, size: size)
        var bestHit: RayHit?
        for entity in frame.entities {
            for part in entity.parts {
                guard let t = intersectPart(rayOrigin: ray.origin, rayDirection: ray.direction, part: part) else {
                    continue
                }
                if bestHit == nil || t < bestHit!.distance {
                    let hitPoint = Vec3(
                        ray.origin.x + ray.direction.x * t,
                        ray.origin.y + ray.direction.y * t,
                        ray.origin.z + ray.direction.z * t
                    )
                    bestHit = RayHit(entityID: entity.id, partID: part.id, distance: t, worldPoint: hitPoint)
                }
            }
        }
        return bestHit
    }

    /// Intersects the camera ray through `pixel` with the `y = 0` ground plane from either side
    /// (`abs(direction.y) >= 1e-6`, `t >= 0`), matching Blockout `groundHit` (`SceneManager.ts:953-957`).
    static func intersectGround(
        at pixel: Point2,
        camera: EditorCamera,
        size: PixelSize
    ) -> Vec3? {
        let ray = camera.ray(through: pixel, size: size)
        guard abs(ray.direction.y) >= 1e-6 else { return nil }
        let t = -ray.origin.y / ray.direction.y
        guard t >= 0, t.isFinite else { return nil }
        return Vec3(
            ray.origin.x + ray.direction.x * t,
            0,
            ray.origin.z + ray.direction.z * t
        )
    }
}

extension ViewportPicking {
    static func intersectPart(rayOrigin: Vec3, rayDirection: Vec3, part: PosedPart) -> Double? {
        let inv = part.transform.inverse
        let localOrigin = inv.transform(rayOrigin)
        let worldStep = Vec3(
            rayOrigin.x + rayDirection.x,
            rayOrigin.y + rayDirection.y,
            rayOrigin.z + rayDirection.z
        )
        let localStep = inv.transform(worldStep)
        let localDir = Vec3(
            localStep.x - localOrigin.x,
            localStep.y - localOrigin.y,
            localStep.z - localOrigin.z
        )
        let half = localHalfExtents(for: part.shape)
        return intersectLocalAABB(origin: localOrigin, direction: localDir, halfExtents: half)
    }

    static func localHalfExtents(for shape: PartShape) -> Vec3 {
        switch shape {
        case let .box(size), let .wedge(size):
            Vec3(max(size.x * 0.5, 1e-4), max(size.y * 0.5, 1e-4), max(size.z * 0.5, 1e-4))
        case let .sphere(radius):
            Vec3(max(radius, 1e-4), max(radius, 1e-4), max(radius, 1e-4))
        case let .capsule(radius, length):
            Vec3(max(radius, 1e-4), max(length * 0.5 + radius, 1e-4), max(radius, 1e-4))
        case let .cylinder(radius, height), let .cone(radius, height):
            Vec3(max(radius, 1e-4), max(height * 0.5, 1e-4), max(radius, 1e-4))
        }
    }

    private static func intersectLocalAABB(origin: Vec3, direction: Vec3, halfExtents: Vec3) -> Double? {
        var tEnter = -Double.infinity
        var tExit = Double.infinity
        let origins = [origin.x, origin.y, origin.z]
        let dirs = [direction.x, direction.y, direction.z]
        let extents = [halfExtents.x, halfExtents.y, halfExtents.z]

        for axis in 0 ..< 3 {
            let o = origins[axis]
            let d = dirs[axis]
            let h = extents[axis]
            if abs(d) < 1e-9 {
                if o < -h || o > h { return nil }
            } else {
                let t1 = (-h - o) / d
                let t2 = (h - o) / d
                let tMin = min(t1, t2)
                let tMax = max(t1, t2)
                tEnter = max(tEnter, tMin)
                tExit = min(tExit, tMax)
                if tEnter > tExit { return nil }
            }
        }
        guard tExit > 1e-6 else { return nil }
        let hitDistance = tEnter > 1e-6 ? tEnter : tExit
        return hitDistance.isFinite && hitDistance > 1e-6 ? hitDistance : nil
    }
}

extension ViewportPicking {
    /// Converts an AppKit view point (`y` up from bottom-left when unflipped, or top-left when `isFlipped == true`)
    /// into top-left viewport pixel coordinates (`CONTRACTS.md` section 4).
    static func viewportPixel(
        fromViewPoint point: CGPoint,
        viewBounds: CGRect,
        isFlipped: Bool = true
    ) -> (pixel: Point2, size: PixelSize) {
        let width = max(Int(viewBounds.width.rounded()), 1)
        let height = max(Int(viewBounds.height.rounded()), 1)
        let px = Double(point.x - viewBounds.minX)
        let localY = Double(point.y - viewBounds.minY)
        let py = isFlipped ? localY : Double(height) - localY
        return (Point2(x: px, y: py), PixelSize(width: width, height: height))
    }

    /// Updates `store.selection` for a primary or Shift-modified entity click (`LANE-D-VIEWPORT.md` line 108).
    /// Primary click selects `[hitID]` (or `.none` on empty space). Shift-click adds `hitID` to `.entities`
    /// without duplicates and preserves existing selection on empty space.
    @MainActor
    static func applyEntityClick(
        hitEntityID: EntityID?,
        shiftPressed: Bool,
        to store: ShotsStore
    ) {
        if let hitID = hitEntityID {
            if shiftPressed {
                switch store.selection {
                case let .entities(existing):
                    if !existing.contains(hitID) {
                        store.selection = .entities(existing + [hitID])
                    }
                case let .actorMark(existingID, _):
                    store.selection = existingID == hitID ? .entities([existingID]) : .entities([existingID, hitID])
                default:
                    store.selection = .entities([hitID])
                }
            } else {
                store.selection = .entities([hitID])
            }
        } else if !shiftPressed {
            store.selection = .none
        }
    }

    /// Handles `M` (drop-marks tool) and `Esc` (return to `.select`) key commands (`LANE-D-VIEWPORT.md` lines 110-112).
    @MainActor
    @discardableResult
    static func handleKeyDown(
        charactersIgnoringModifiers: String?,
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags = [],
        in store: ShotsStore
    ) -> Bool {
        if keyCode == 53 {
            store.tool = .select
            return true
        }
        let disallowedModifiers: NSEvent.ModifierFlags = [.command, .control, .option]
        guard modifiers.isDisjoint(with: disallowedModifiers),
              let chars = charactersIgnoringModifiers?.lowercased() else {
            return false
        }
        if chars == "m" {
            guard !store.isReadOnly, store.currentShot != nil else { return false }
            store.tool = store.tool == .dropMarks ? .select : .dropMarks
            return true
        }
        return false
    }
}

extension ViewportPicking {
    /// Routes a primary viewport click according to `store.tool` and `store.isReadOnly`.
    @MainActor
    static func handleClick(
        at pixel: Point2,
        in store: ShotsStore,
        camera: EditorCamera,
        size: PixelSize,
        shiftPressed: Bool = false,
        optionPressed: Bool = false
    ) {
        if !store.isReadOnly {
            switch store.tool {
            case let .place(assetID):
                _ = placeEntity(
                    assetID: assetID,
                    at: pixel,
                    in: store,
                    camera: camera,
                    size: size,
                    optionPressed: optionPressed
                )
                return
            case .dropMarks:
                _ = dropMark(at: pixel, in: store, camera: camera, size: size)
                return
            case .select:
                break
            }
        }
        let hitID = store.frame.flatMap { pickEntity(at: pixel, in: $0, camera: camera, size: size) }
        applyEntityClick(hitEntityID: hitID, shiftPressed: shiftPressed, to: store)
    }

    /// Places `assetID` at the ray-ground (`y = 0`) intersection and selects it (`LANE-D-VIEWPORT.md` lines 109-110).
    /// Holding `⌥` (`optionPressed == true`) keeps `store.tool == .place(assetID:)`; otherwise resets to `.select`.
    @MainActor
    @discardableResult
    static func placeEntity(
        assetID: String,
        at pixel: Point2,
        in store: ShotsStore,
        camera: EditorCamera,
        size: PixelSize,
        optionPressed: Bool = false
    ) -> EntityID? {
        guard !store.isReadOnly,
              let scene = store.currentScene,
              store.currentShot != nil,
              let asset = store.catalog.asset(assetID),
              let groundHit = intersectGround(at: pixel, camera: camera, size: size)
        else { return nil }

        let entityID = store.newID("entity")
        let name = nextEntityName(for: asset, in: scene)
        let entity = PrevisEntity(
            id: entityID,
            assetID: assetID,
            name: name,
            label: nil,
            placement: Placement(position: Vec3(groundHit.x, 0, groundHit.z), heading: 0, scale: 1)
        )
        store.run(.addEntity(scene.id, entity))
        if store.currentScene?.entities.contains(where: { $0.id == entityID }) == true {
            store.selection = .entities([entityID])
            if !optionPressed {
                store.tool = .select
            }
            return entityID
        }
        return nil
    }

    /// Drops an `ActorMark` (when an entity or actor mark is selected) or a `CameraMark` aimed at the subject
    /// (when `.camera` or `.cameraMark` is selected) at the playhead time (`LANE-D-VIEWPORT.md` lines 111-112, 117).
    @MainActor
    @discardableResult
    static func dropMark(
        at pixel: Point2,
        in store: ShotsStore,
        camera: EditorCamera,
        size: PixelSize
    ) -> MarkID? {
        guard !store.isReadOnly,
              let scene = store.currentScene,
              let shot = store.currentShot,
              let groundHit = intersectGround(at: pixel, camera: camera, size: size)
        else { return nil }

        let playheadTime = FrameGrid.time(ofFrame: store.playhead)
        switch store.selection {
        case let .entities(ids):
            guard let entityID = ids.first else { return nil }
            return dropActorMark(
                for: entityID,
                atGroundPoint: groundHit,
                time: playheadTime,
                scene: scene,
                shot: shot,
                in: store
            )
        case let .actorMark(entityID, _):
            return dropActorMark(
                for: entityID,
                atGroundPoint: groundHit,
                time: playheadTime,
                scene: scene,
                shot: shot,
                in: store
            )
        case .camera, .cameraMark:
            return dropCameraMark(
                atGroundPoint: groundHit,
                time: playheadTime,
                scene: scene,
                shot: shot,
                in: store
            )
        case .none:
            return nil
        }
    }

    @MainActor
    private static func dropActorMark(
        for entityID: EntityID,
        atGroundPoint groundHit: Vec3,
        time: Double,
        scene: PrevisScene,
        shot: Shot,
        in store: ShotsStore
    ) -> MarkID? {
        guard scene.entities.contains(where: { $0.id == entityID }) else { return nil }
        let markID = store.newID("mark")
        let mark = ActorMark(
            id: markID,
            time: time,
            hold: 0,
            easeIn: 0.25,
            easeOut: 0.25,
            position: Vec3(groundHit.x, 0, groundHit.z),
            gait: .walk
        )
        store.run(.addActorMark(shot.id, entityID, mark))
        let updatedTake = store.currentScene?.blocking.first { $0.id == shot.blockingTakeID }
            ?? store.currentScene?.blocking.first
        let didAdd = updatedTake?.tracks.first { $0.entityID == entityID }?.marks.contains { $0.id == markID } == true
        return didAdd ? markID : nil
    }

    @MainActor
    private static func dropCameraMark(
        atGroundPoint groundHit: Vec3,
        time: Double,
        scene: PrevisScene,
        shot: Shot,
        in store: ShotsStore
    ) -> MarkID? {
        let currentCam = store.frame?.camera
        let worldPosition = Vec3(groundHit.x, currentCam?.position.y ?? 1.6, groundHit.z)
        let (worldPan, worldTilt) = cameraMarkAim(
            from: worldPosition,
            scene: scene,
            shot: shot,
            frame: store.frame,
            catalog: store.catalog
        )
        let (markPosition, markPan) = resolveCameraMarkTransform(
            worldPosition: worldPosition,
            worldPan: worldPan,
            shot: shot,
            frame: store.frame
        )
        let markID = store.newID("mark")
        let mark = CameraMark(
            id: markID,
            time: time,
            hold: 0,
            easeIn: 0.3,
            easeOut: 0.3,
            position: markPosition,
            pan: markPan,
            tilt: worldTilt,
            roll: 0,
            focalLength: currentCam?.focalLength ?? shot.camera.marks.last?.focalLength ?? 35
        )
        store.run(.addCameraMark(shot.id, mark))
        let didAdd = store.currentShot?.camera.marks.contains { $0.id == markID } == true
        return didAdd ? markID : nil
    }

    private static func cameraMarkAim(
        from worldPosition: Vec3,
        scene: PrevisScene,
        shot: Shot,
        frame: SceneFrame?,
        catalog: ContentCatalog
    ) -> (pan: Double, tilt: Double) {
        let fallbackPan = frame?.camera.pan ?? shot.camera.marks.last?.pan ?? 0
        let fallbackTilt = frame?.camera.tilt ?? shot.camera.marks.last?.tilt ?? 0
        guard let frame, !frame.entities.isEmpty else {
            return (fallbackPan, fallbackTilt)
        }
        let tracked = shot.camera.trackIDs.compactMap { id in
            frame.entities.first { $0.id == id }
        }
        let subjects: [EntityFrame] = if !tracked.isEmpty {
            tracked
        } else if let primaryActor = frame.entities.first(where: \.isActor) {
            [primaryActor]
        } else {
            [frame.entities[0]]
        }
        let count = Double(subjects.count)
        let meanX = subjects.reduce(0.0) { $0 + $1.position.x } / count
        let meanY = subjects.reduce(0.0) { $0 + $1.position.y } / count
        let meanZ = subjects.reduce(0.0) { $0 + $1.position.z } / count
        let maxHeight = subjects.map { subject -> Double in
            let scale = scene.entities.first { $0.id == subject.id }?.placement.scale ?? 1.0
            let baseHeight = catalog.asset(subject.assetID)?.height
                ?? max(subject.bounds.max.y - subject.bounds.min.y, 1.75)
            return baseHeight * scale
        }.max() ?? 1.75
        let dx = meanX - worldPosition.x
        let dy = (meanY + maxHeight * 0.8) - worldPosition.y
        let dz = meanZ - worldPosition.z
        let flat = hypot(dx, dz)
        guard flat > 1e-4 || abs(dy) > 1e-4 else {
            return (fallbackPan, fallbackTilt)
        }
        return (atan2(-dx, -dz), atan2(dy, max(flat, 1e-4)))
    }

    private static func resolveCameraMarkTransform(
        worldPosition: Vec3,
        worldPan: Double,
        shot: Shot,
        frame: SceneFrame?
    ) -> (position: Vec3, pan: Double) {
        guard shot.camera.rig == .carMount,
              let mountID = shot.camera.mountID,
              let mount = frame?.entities.first(where: { $0.id == mountID })
        else {
            return (worldPosition, worldPan)
        }
        let dx = worldPosition.x - mount.position.x
        let dz = worldPosition.z - mount.position.z
        let c = cos(mount.heading)
        let s = sin(mount.heading)
        let localPos = Vec3(dx * c - dz * s, worldPosition.y - mount.position.y, dx * s + dz * c)
        return (localPos, worldPan - mount.heading)
    }

    private static func nextEntityName(for asset: AssetSpec, in scene: PrevisScene) -> String {
        let existingCount = scene.entities.filter { $0.assetID == asset.id }.count
        var index = existingCount + 1
        var candidate = existingCount == 0 ? asset.name : "\(asset.name) \(index)"
        let existingNames = Set(scene.entities.map(\.name))
        while existingNames.contains(candidate) {
            index += 1
            candidate = "\(asset.name) \(index)"
        }
        return candidate
    }
}
