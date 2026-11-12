import Foundation

/// Local dimensions of a set primitive. A curved wall's width is the length along its centre line.
public struct SetPiece: Codable, Sendable, Equatable {
    public var width: Double
    public var height: Double
    public var depth: Double
    public var wallSweep: Double
    public var crenellated: Bool

    public init(width: Double, height: Double, depth: Double, wallSweep: Double, crenellated: Bool) {
        self.width = width
        self.height = height
        self.depth = depth
        self.wallSweep = wallSweep
        self.crenellated = crenellated
    }

    /// The catalog primitive's dimensions at scale 1, before any editing.
    public static func standard(for asset: AssetSpec) -> SetPiece? {
        guard ["prim.cube", "prim.cylinder", "prim.stairs", "prim.wall"].contains(asset.id),
              let parts = asset.parts, !parts.isEmpty else { return nil }
        let bounds = Bodies.bounds(of: parts.map {
            PosedPart(id: $0.id, shape: $0.shape, transform: .node($0.position, $0.rotation), color: $0.color)
        }, fallback: .zero)
        let size = bounds.max - bounds.min
        return SetPiece(width: size.x, height: size.y, depth: size.z, wallSweep: 0, crenellated: false)
    }

    func isValid(for asset: AssetSpec) -> Bool {
        Self.standard(for: asset) != nil
            && [width, height, depth].allSatisfy { $0.isFinite && $0 > 0 }
            && (0 ... Double.pi).contains(wallSweep)
            && (asset.id == "prim.wall" || (wallSweep == 0 && !crenellated))
    }

    func build(asset: AssetSpec, into builder: inout BodyBuilder) {
        guard let base = Self.standard(for: asset), let parts = asset.parts else { return }
        if wallSweep > 0 || crenellated {
            wall(color: parts[0].color.packed, into: &builder)
            return
        }
        let stretch = Mat4.scale(Vec3(width / base.width, height / base.height, depth / base.depth))
        for part in parts {
            let local = stretch * Mat4.node(part.position, part.rotation)
            builder.add(part.id, part.shape, at: local, color: part.color.packed)
        }
    }

    private func wall(color: UInt32, into builder: inout BodyBuilder) {
        let crownHeight = crenellated ? min(height / 4, 0.6) : 0
        let bodyHeight = height - crownHeight
        let segments = max(1, Int(ceil(wallSweep / (.pi / 24))))
        for index in 0 ..< segments {
            let length = width / Double(segments)
            let centre = (Double(index) + 0.5) * length - width / 2
            let extraDepth = depth * tan(wallSweep / (2 * Double(segments)))
            let shape = PartShape.box(size: Vec3(length + extraDepth, bodyHeight, depth))
            builder.add("wall-\(index)", shape, at: wallPosition(centre, y: bodyHeight / 2), color: color)
        }
        guard crenellated else { return }
        let count = Int(max(2, min(width / 1.5, 40)))
        let period = width / Double(count)
        for index in 0 ..< count {
            let centre = (Double(index) + 0.5) * period - width / 2
            let shape = PartShape.box(size: Vec3(period / 2, crownHeight, depth))
            builder.add("crown-\(index)", shape, at: wallPosition(centre, y: height - crownHeight / 2), color: color)
        }
    }

    private func wallPosition(_ distance: Double, y: Double) -> Mat4 {
        let angle = distance / width * wallSweep
        guard angle != 0 else { return .translation(Vec3(distance, y, 0)) }
        let x = distance * sin(angle) / angle
        let z = x * tan(angle / 2)
        return .translation(Vec3(x, y, z)) * .rotation(.yaw(-angle))
    }
}
