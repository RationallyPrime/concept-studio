import AppKit
import PrevisCore
import RealityKit
import SwiftUI

/// Editor-only D2 overlays (spike-tape marks, path ribbons, shot camera body/frustum, and selection boxes)
/// mounted under `viewport.overlayRoot` so editor chrome never leaks into exported passes.
///
/// Reference: Blockout `src/renderer/viewport/builders.ts:6147-6182` and
/// `src/renderer/viewport/SceneManager.ts:84-86, 187, 343-364, 633-760, 1045-1077, 2107-2112`.
@MainActor enum ViewportOverlays {
    static let marksGroupName = "viewport.marksGroup"
    static let pathsGroupName = "viewport.pathsGroup"
    static let cameraBodyName = "viewport.cameraBody"
    static let selectionGroupName = "viewport.selectionGroup"

    static let defaultActorMarkRGB = RGB(hex: "#f5a524")
    static let cameraOverlayRGB = RGB(hex: "#7dd3fc")
    static let cameraHousingRGB = RGB(hex: "#f5f5f7")

    static func nsColor(_ rgb: RGB, alpha: CGFloat = 1.0) -> NSColor {
        NSColor(srgbRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: alpha)
    }

    static func simd(_ vec: Vec3) -> SIMD3<Float> {
        SIMD3<Float>(Float(vec.x), Float(vec.y), Float(vec.z))
    }

    static func simd(_ quat: Quat) -> simd_quatf {
        simd_quatf(ix: Float(quat.x), iy: Float(quat.y), iz: Float(quat.z), r: Float(quat.w))
    }

    /// Classic floor spike-tape `"T"` mark with floating 1-based number badge (`builders.ts:6147-6182`).
    static func makeMarkEntity(name: String, color: RGB, number: Int, position: Vec3) -> Entity {
        let group = Entity()
        group.name = name
        group.position = SIMD3<Float>(Float(position.x), Float(position.y) + 0.01, Float(position.z))

        let material = UnlitMaterial(color: nsColor(color))
        let across = ModelEntity(
            mesh: .generateBox(width: 0.4, height: 0.02, depth: 0.08),
            materials: [material]
        )
        across.name = "mark.across"
        across.position = SIMD3<Float>(0, 0.011, -0.14)
        group.addChild(across)

        let stem = ModelEntity(
            mesh: .generateBox(width: 0.08, height: 0.02, depth: 0.4),
            materials: [material]
        )
        stem.name = "mark.stem"
        stem.position = SIMD3<Float>(0, 0.011, 0.06)
        group.addChild(stem)

        let badge = ModelEntity(
            mesh: .generatePlane(width: 0.35, height: 0.35),
            materials: [badgeMaterial(text: "\(number)")]
        )
        badge.name = "mark.number.\(number)"
        badge.position = SIMD3<Float>(0, 0.3, 0)
        group.addChild(badge)

        ViewportGrid.disableOcclusionCulling(on: group)
        return group
    }

    private static var badgeMaterialCache: [String: UnlitMaterial] = [:]

    static func badgeMaterial(text: String) -> UnlitMaterial {
        if let cached = badgeMaterialCache[text] { return cached }
        var material = UnlitMaterial(color: .white)
        material.blending = .transparent(opacity: .init(floatLiteral: 1.0))
        if let cgImage = renderBadgeCGImage(text: text),
           let texture = try? TextureResource(image: cgImage, options: .init(semantic: .color)) {
            material.color = .init(tint: .white, texture: .init(texture))
        }
        badgeMaterialCache[text] = material
        return material
    }

    private static func renderBadgeCGImage(text: String) -> CGImage? {
        let size = 128
        guard let ctx = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let font = NSFont.monospacedDigitSystemFont(ofSize: 64, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
        ]
        let attrStr = NSAttributedString(string: text, attributes: attrs)
        let textSize = attrStr.size()
        let origin = CGPoint(
            x: (CGFloat(size) - textSize.width) * 0.5,
            y: (CGFloat(size) - textSize.height) * 0.5
        )
        attrStr.draw(at: origin)
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    /// Rebuilds actor and camera spike-tape marks sorted by time (`SceneManager.ts:633-658`).
    static func rebuildMarks(in overlayRoot: Entity, scene: PrevisScene?, shot: Shot?, showMarks: Bool) {
        let group = ensureGroup(named: marksGroupName, in: overlayRoot)
        group.isEnabled = showMarks
        for child in Array(group.children) {
            child.removeFromParent()
        }
        guard let scene, let shot else { return }
        let take = scene.blocking.first { $0.id == shot.blockingTakeID } ?? scene.blocking.first
        for track in take?.tracks ?? [] {
            let entity = scene.entities.first { $0.id == track.entityID }
            let color = entity?.label?.color ?? defaultActorMarkRGB
            let sorted = track.marks.enumerated()
                .sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }
                .map(\.element)
            for (index, mark) in sorted.enumerated() {
                group.addChild(
                    makeMarkEntity(
                        name: "viewport.mark.actor:\(track.entityID):\(mark.id)",
                        color: color,
                        number: index + 1,
                        position: mark.position
                    )
                )
            }
        }
        let sortedCameraMarks = shot.camera.marks.enumerated()
            .sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }
            .map(\.element)
        for (index, mark) in sortedCameraMarks.enumerated() {
            group.addChild(
                makeMarkEntity(
                    name: "viewport.mark.camera:\(mark.id)",
                    color: cameraOverlayRGB,
                    number: index + 1,
                    position: mark.position
                )
            )
        }
    }

    static func ensureGroup(named name: String, in parent: Entity) -> Entity {
        if let existing = parent.children.first(where: { $0.name == name }) {
            return existing
        }
        let created = Entity()
        created.name = name
        ViewportGrid.disableOcclusionCulling(on: created)
        parent.addChild(created)
        return created
    }
}

@MainActor extension ViewportOverlays {
    /// Rebuilds dashed motion-path ribbons (`evaluator.paths()`) and selected-lane decorations
    /// (`SceneManager.ts:660-760`).
    static func rebuildPaths(
        in overlayRoot: Entity,
        scene: PrevisScene?,
        evaluator: ShotEvaluator?,
        selection: ShotsSelection,
        showPaths: Bool
    ) {
        let group = ensureGroup(named: pathsGroupName, in: overlayRoot)
        group.isEnabled = showPaths
        for child in Array(group.children) {
            child.removeFromParent()
        }
        guard let scene, let evaluator else { return }
        let paths = evaluator.paths()
        for path in paths where path.points.count >= 2 {
            let (name, color): (String, RGB) = switch path.subject {
            case .camera:
                ("viewport.path.camera", cameraOverlayRGB)
            case let .entity(entityID):
                (
                    "viewport.path.entity:\(entityID)",
                    scene.entities.first { $0.id == entityID }?.label?.color ?? defaultActorMarkRGB
                )
            }
            if let mesh = try? makeDashedRibbonMesh(name: name, points: path.points) {
                var material = UnlitMaterial(color: nsColor(color))
                material.blending = .transparent(opacity: .init(floatLiteral: 0.8))
                let entity = ModelEntity(mesh: mesh, materials: [material])
                entity.name = name
                group.addChild(entity)
            }
            if isSubjectSelected(path.subject, selection: selection) {
                appendPathDecorations(to: group, path: path, color: color)
            }
        }
    }

    private static func isSubjectSelected(_ subject: MotionPath.Subject, selection: ShotsSelection) -> Bool {
        switch (subject, selection) {
        case (.camera, .camera), (.camera, .cameraMark):
            true
        case let (.entity(id), .entities(ids)):
            ids.last == id
        case let (.entity(id), .actorMark(markEntityID, _)):
            markEntityID == id
        default:
            false
        }
    }

    private static func makeDashedRibbonMesh(name: String, points: [Vec3]) throws -> MeshResource {
        let halfWidth: Float = 0.018
        let dashSize = 0.15
        let gapSize = 0.10
        let period = dashSize + gapSize
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        let up = SIMD3<Float>(0, 1, 0)
        var distanceAlong = 0.0

        func addSegmentQuad(a: Vec3, b: Vec3) {
            let dx = Float(b.x - a.x), dz = Float(b.z - a.z)
            let horizLen = sqrt(dx * dx + dz * dz)
            let perp = horizLen > 1e-5
                ? SIMD3<Float>(-dz / horizLen * halfWidth, 0, dx / horizLen * halfWidth)
                : SIMD3<Float>(halfWidth, 0, 0)
            let pA = SIMD3<Float>(Float(a.x), Float(a.y) + 0.02, Float(a.z))
            let pB = SIMD3<Float>(Float(b.x), Float(b.y) + 0.02, Float(b.z))
            let base = UInt32(positions.count)
            positions.append(contentsOf: [pA - perp, pA + perp, pB + perp, pB - perp])
            normals.append(contentsOf: [up, up, up, up])
            indices.append(contentsOf: [
                base, base + 1, base + 2, base, base + 2, base + 3,
                base, base + 2, base + 1, base, base + 3, base + 2,
            ])
        }

        for i in 0 ..< (points.count - 1) {
            let a = points[i], b = points[i + 1]
            let segLen = Double(simd_length(simd(b) - simd(a)))
            guard segLen > 1e-5 else { continue }
            let phase = (distanceAlong / period - floor(distanceAlong / period)) * period
            if phase < dashSize {
                addSegmentQuad(a: a, b: b)
            }
            distanceAlong += segLen
        }
        if positions.isEmpty, let first = points.first {
            addSegmentQuad(a: first, b: Vec3(first.x + 0.04, first.y, first.z))
        }
        var descriptor = MeshDescriptor(name: name)
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals(normals)
        descriptor.primitives = .triangles(indices)
        return try MeshResource.generate(from: [descriptor])
    }

    private static func appendPathDecorations(to group: Entity, path: MotionPath, color: RGB) {
        let chevronCount = min(10, max(3, path.points.count / 6))
        var chevronMat = UnlitMaterial(color: nsColor(color))
        chevronMat.blending = .transparent(opacity: .init(floatLiteral: 0.9))
        for i in 1 ... chevronCount {
            let t = Double(i) / Double(chevronCount + 1)
            let idx = min(path.points.count - 2, max(0, Int(floor(t * Double(path.points.count - 1)))))
            let a = simd(path.points[idx]), b = simd(path.points[idx + 1])
            let dir = b - a
            guard simd_length(dir) > 1e-4 else { continue }
            let mid = (a + b) * 0.5
            let cone = ModelEntity(mesh: .generateCone(height: 0.24, radius: 0.055), materials: [chevronMat])
            cone.name = "viewport.path.chevron.\(i)"
            cone.position = SIMD3<Float>(mid.x, mid.y + 0.03, mid.z)
            cone.orientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: simd_normalize(dir))
            group.addChild(cone)
        }
        for mark in path.marks {
            let label = ModelEntity(
                mesh: .generatePlane(width: 0.45, height: 0.225),
                materials: [badgeMaterial(text: String(format: "t=%.1fs", mark.time))]
            )
            label.name = "viewport.path.timeLabel:\(mark.id)"
            label.position = SIMD3<Float>(Float(mark.position.x), Float(mark.position.y) + 0.55, Float(mark.position.z))
            group.addChild(label)
        }
    }

    /// Updates or builds the shot camera body + lens + wireframe frustum (`SceneManager.ts:343-364, 2107-2112`).
    static func updateCameraBody(in overlayRoot: Entity, shot: Shot?, frame: SceneFrame?) {
        let cameraBody: Entity
        if let existing = overlayRoot.children.first(where: { $0.name == cameraBodyName }) {
            cameraBody = existing
        } else {
            let created = makeCameraBodyEntity()
            overlayRoot.addChild(created)
            cameraBody = created
        }
        guard shot != nil, let frame else {
            cameraBody.isEnabled = false
            return
        }
        cameraBody.isEnabled = true
        cameraBody.transform = Transform(
            scale: .one,
            rotation: simd(frame.camera.orientation),
            translation: simd(frame.camera.position)
        )
    }

    static func makeCameraBodyEntity() -> Entity {
        let group = Entity()
        group.name = cameraBodyName
        let bodyMat = UnlitMaterial(color: nsColor(cameraHousingRGB))
        let housing = ModelEntity(mesh: .generateBox(width: 0.22, height: 0.24, depth: 0.4), materials: [bodyMat])
        housing.name = "cameraBody.housing"
        group.addChild(housing)

        let lens = ModelEntity(mesh: .generateCylinder(height: 0.18, radius: 0.08), materials: [bodyMat])
        lens.name = "cameraBody.lens"
        lens.position = SIMD3<Float>(0, 0, -0.28)
        lens.orientation = simd_quatf(angle: .pi * 0.5, axis: SIMD3<Float>(1, 0, 0))
        group.addChild(lens)

        let frustum = Entity()
        frustum.name = "cameraBody.frustum"
        var frustumMat = UnlitMaterial(color: nsColor(defaultActorMarkRGB))
        frustumMat.blending = .transparent(opacity: .init(floatLiteral: 0.35))
        let apex = SIMD3<Float>(0, 0, -0.35)
        let corners: [SIMD3<Float>] = [
            SIMD3(-0.35, -0.35, -1.55),
            SIMD3(0.35, -0.35, -1.55),
            SIMD3(0.35, 0.35, -1.55),
            SIMD3(-0.35, 0.35, -1.55),
        ]
        for i in 0 ..< 4 {
            addStrut(to: frustum, from: apex, to: corners[i], thickness: 0.015, material: frustumMat)
            addStrut(to: frustum, from: corners[i], to: corners[(i + 1) % 4], thickness: 0.015, material: frustumMat)
        }
        group.addChild(frustum)
        ViewportGrid.disableOcclusionCulling(on: group)
        return group
    }

    static func addStrut(
        to parent: Entity,
        from a: SIMD3<Float>,
        to b: SIMD3<Float>,
        thickness: Float,
        material: UnlitMaterial
    ) {
        let delta = b - a
        let length = simd_length(delta)
        guard length > 1e-5 else { return }
        let strut = ModelEntity(
            mesh: .generateBox(width: thickness, height: length, depth: thickness),
            materials: [material]
        )
        strut.position = (a + b) * 0.5
        strut.orientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: delta / length)
        parent.addChild(strut)
    }

    /// Rebuilds wireframe selection boxes in the overlay without tinting mapper entities (`SceneManager.ts:1045-1077`).
    static func rebuildSelectionBoxes(
        in overlayRoot: Entity,
        scene: PrevisScene?,
        shot: Shot?,
        frame: SceneFrame?,
        selection: ShotsSelection
    ) {
        let group = ensureGroup(named: selectionGroupName, in: overlayRoot)
        for child in Array(group.children) {
            child.removeFromParent()
        }
        guard let scene else { return }
        switch selection {
        case .none:
            break
        case let .entities(ids):
            for (idx, entityID) in ids.enumerated() {
                guard let bounds = frame?.entities.first(where: { $0.id == entityID })?.bounds else { continue }
                let color = (idx == ids.count - 1) ? defaultActorMarkRGB : cameraOverlayRGB
                group.addChild(makeWireframeBoxEntity(
                    name: "viewport.selectionBox.entity:\(entityID)",
                    bounds: bounds,
                    color: color
                ))
            }
        case .camera:
            guard shot != nil, let frame else { break }
            let box = makeWireframeBoxEntity(
                name: "viewport.selectionBox.camera",
                bounds: Box3(min: Vec3(-0.38, -0.38, -1.58), max: Vec3(0.38, 0.38, 0.24)),
                color: defaultActorMarkRGB
            )
            box.transform = Transform(
                scale: .one,
                rotation: simd(frame.camera.orientation),
                translation: simd(frame.camera.position)
            )
            group.addChild(box)
        case let .actorMark(entityID, markID):
            let take = scene.blocking.first { $0.id == shot?.blockingTakeID } ?? scene.blocking.first
            guard let mark = take?.tracks.first(where: { $0.entityID == entityID })?.marks
                .first(where: { $0.id == markID }) else { break }
            group.addChild(
                makeWireframeBoxEntity(
                    name: "viewport.selectionBox.actorMark:\(entityID):\(markID)",
                    bounds: markBounds(at: mark.position),
                    color: defaultActorMarkRGB
                )
            )
        case let .cameraMark(markID):
            guard let mark = shot?.camera.marks.first(where: { $0.id == markID }) else { break }
            group.addChild(
                makeWireframeBoxEntity(
                    name: "viewport.selectionBox.cameraMark:\(markID)",
                    bounds: markBounds(at: mark.position),
                    color: defaultActorMarkRGB
                )
            )
        }
    }

    private static func markBounds(at p: Vec3) -> Box3 {
        Box3(min: Vec3(p.x - 0.24, p.y, p.z - 0.24), max: Vec3(p.x + 0.24, p.y + 0.42, p.z + 0.28))
    }

    static func makeWireframeBoxEntity(name: String, bounds: Box3, color: RGB) -> Entity {
        let group = Entity()
        group.name = name
        let pad = 0.015
        let lo = SIMD3<Float>(Float(bounds.min.x - pad), Float(bounds.min.y - pad), Float(bounds.min.z - pad))
        let hi = SIMD3<Float>(Float(bounds.max.x + pad), Float(bounds.max.y + pad), Float(bounds.max.z + pad))
        let c: [SIMD3<Float>] = [
            SIMD3(lo.x, lo.y, lo.z), SIMD3(hi.x, lo.y, lo.z), SIMD3(hi.x, lo.y, hi.z), SIMD3(lo.x, lo.y, hi.z),
            SIMD3(lo.x, hi.y, lo.z), SIMD3(hi.x, hi.y, lo.z), SIMD3(hi.x, hi.y, hi.z), SIMD3(lo.x, hi.y, hi.z),
        ]
        let edges: [(Int, Int)] = [
            (0, 1), (1, 2), (2, 3), (3, 0),
            (4, 5), (5, 6), (6, 7), (7, 4),
            (0, 4), (1, 5), (2, 6), (3, 7),
        ]
        let mat = UnlitMaterial(color: nsColor(color))
        for (i, j) in edges {
            addStrut(to: group, from: c[i], to: c[j], thickness: 0.016, material: mat)
        }
        ViewportGrid.disableOcclusionCulling(on: group)
        return group
    }

    static func sync(
        overlayRoot: Entity,
        scene: PrevisScene?,
        shot: Shot?,
        evaluator: ShotEvaluator?,
        frame: SceneFrame?,
        selection: ShotsSelection,
        showMarks: Bool,
        showPaths: Bool
    ) {
        rebuildMarks(in: overlayRoot, scene: scene, shot: shot, showMarks: showMarks)
        rebuildPaths(
            in: overlayRoot,
            scene: scene,
            evaluator: evaluator,
            selection: selection,
            showPaths: showPaths
        )
        updateCameraBody(in: overlayRoot, shot: shot, frame: frame)
        rebuildSelectionBoxes(
            in: overlayRoot,
            scene: scene,
            shot: shot,
            frame: frame,
            selection: selection
        )
    }
}
