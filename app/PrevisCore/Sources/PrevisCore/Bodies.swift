import Foundation

// Posed bodies, CONTRACTS section 5.4: `EntityFrame.parts`, `keypoints`, `bounds` and `isActor`.
//
// People and quadrupeds are built from the rigs in PersonRig.swift and QuadrupedRig.swift. Static assets use the
// `parts` of `parts.v1.json`. Anything else is one grey box, footprint × height.
//
// Rigged shapes are sized for entity scale 1 and the transform carries the entity scale, like static parts, so a
// renderer can cache one mesh per shape. Bob and sway amplitudes are therefore proportional to the scale; Blockout
// keeps them in absolute metres, a difference of a few millimetres.

extension Mat4 {
    /// Euler XYZ as three.js defines it: `Rx · Ry · Rz`.
    static func euler(_ x: Double, _ y: Double, _ z: Double) -> Mat4 {
        rotation(.pitch(x)) * rotation(.yaw(y)) * rotation(.roll(z))
    }

    /// A node of a rig: translate, then rotate (Euler XYZ).
    static func node(_ t: Vec3, _ r: Vec3 = .zero) -> Mat4 {
        translation(t) * euler(r.x, r.y, r.z)
    }
}

/// Collects the posed parts of one entity. `world` is rig space → world: position, heading and entity scale.
struct BodyBuilder {
    let world: Mat4
    private(set) var parts: [PosedPart] = []

    init(position: Vec3, heading: Double, scale: Double) {
        world = Mat4.translation(position) * Mat4.rotation(.yaw(heading)) * Mat4.scale(scale)
    }

    mutating func add(_ id: String, _ shape: PartShape, at local: Mat4, color: UInt32) {
        let rgb = RGB(
            r: Double((color >> 16) & 0xFF) / 255,
            g: Double((color >> 8) & 0xFF) / 255,
            b: Double(color & 0xFF) / 255
        )
        parts.append(PosedPart(id: id, shape: shape, transform: world * local, color: rgb))
    }

    func worldPoint(_ rig: Vec3) -> Vec3 {
        world.transform(rig)
    }
}

enum Bodies {
    /// Parts, keypoints and bounds for an entity at an evaluated pose.
    static func build(_ entity: PrevisEntity, asset: AssetSpec, state: EntityPose) -> (
        parts: [PosedPart], keypoints: [Keypoint], bounds: Box3
    ) {
        var builder = BodyBuilder(position: state.position, heading: state.heading, scale: entity.placement.scale)
        var keypoints: [Keypoint] = []
        switch asset.rig {
        case .person:
            keypoints = PersonRig.build(asset: asset, scale: entity.placement.scale, state: state, into: &builder)
        case .quadruped:
            QuadrupedRig.build(asset: asset, state: state, into: &builder)
        case .bird, .none:
            if let staticParts = asset.parts, !staticParts.isEmpty {
                for part in staticParts {
                    let local = Mat4.node(part.position, part.rotation)
                    builder.add(part.id, part.shape, at: local, color: part.color.packed)
                }
            } else {
                box(asset, into: &builder)
            }
        }
        return (builder.parts, keypoints, bounds(of: builder.parts, fallback: state.position))
    }

    /// One grey box of the catalog footprint and height, standing on the ground.
    private static func box(_ asset: AssetSpec, into builder: inout BodyBuilder) {
        let size = Vec3(asset.footprint, asset.height, asset.footprint)
        builder.add("body", .box(size: size), at: .translation(Vec3(0, asset.height / 2, 0)), color: 0x808080)
    }

    static func bounds(of parts: [PosedPart], fallback: Vec3) -> Box3 {
        var low = Vec3(.infinity, .infinity, .infinity), high = Vec3(-.infinity, -.infinity, -.infinity)
        for part in parts {
            let (lo, hi) = part.shape.worldBounds(part.transform)
            low = Vec3(min(low.x, lo.x), min(low.y, lo.y), min(low.z, lo.z))
            high = Vec3(max(high.x, hi.x), max(high.y, hi.y), max(high.z, hi.z))
        }
        return parts.isEmpty ? Box3(min: fallback, max: fallback) : Box3(min: low, max: high)
    }
}

extension RGB {
    /// 0xRRGGBB.
    var packed: UInt32 {
        func byte(_ v: Double) -> UInt32 {
            UInt32((v * 255).rounded())
        }
        return byte(r) << 16 | byte(g) << 8 | byte(b)
    }
}

extension PartShape {
    /// The axis-aligned bounds of the shape under `transform`: exact for boxes, spheres and capsules, and a safe
    /// outer bound for cylinders, cones and wedges.
    func worldBounds(_ transform: Mat4) -> (Vec3, Vec3) {
        let m = transform.m
        let centre = Vec3(m[12], m[13], m[14])
        // the rotation-and-scale columns, which map local axes into the world
        let cx = Vec3(m[0], m[1], m[2]), cy = Vec3(m[4], m[5], m[6]), cz = Vec3(m[8], m[9], m[10])
        func extent(_ half: Vec3) -> Vec3 {
            Vec3(
                abs(cx.x) * half.x + abs(cy.x) * half.y + abs(cz.x) * half.z,
                abs(cx.y) * half.x + abs(cy.y) * half.y + abs(cz.y) * half.z,
                abs(cx.z) * half.x + abs(cy.z) * half.y + abs(cz.z) * half.z
            )
        }
        switch self {
        case let .box(size), let .wedge(size):
            let e = extent(size * 0.5)
            return (centre - e, centre + e)
        case let .sphere(radius):
            let r = radius * max(cx.length, cy.length, cz.length)
            return (centre - Vec3(r, r, r), centre + Vec3(r, r, r))
        case let .capsule(radius, length):
            // two end spheres on the local Y axis
            let axis = cy * (length / 2)
            let r = radius * max(cx.length, cy.length, cz.length)
            let e = Vec3(abs(axis.x) + r, abs(axis.y) + r, abs(axis.z) + r)
            return (centre - e, centre + e)
        case let .cylinder(radius, height), let .cone(radius, height):
            let e = extent(Vec3(radius, height / 2, radius))
            return (centre - e, centre + e)
        }
    }
}
