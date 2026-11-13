import Foundation

// Pieces of the set, CONTRACTS section 5.7: sized grey-box stand-ins for what a location has or a plate shows. A
// table people stand behind, a dais they stand on, a wall. Unlike catalog assets a set piece has its own width,
// height and depth, so it can be fitted to the plate.

public struct SetPiece: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case block, plinth, dais, stairs, table, bench, throne, wall, parapet, arch, column
    }

    public var kind: Kind
    /// Width along the piece's own X, height, and depth along its Z, in metres at scale 1. Its front faces −Z.
    public var size: Vec3
    public var steps: Int // dais: steps down its front; stairs: steps in the flight; otherwise unused
    /// True when the plate already shows this piece. It then hides stand-ins behind it, and guides over the plate
    /// show the plate there. False for a piece the plate lacks, which is drawn as a grey box.
    public var inPlate: Bool

    public init(kind: Kind, size: Vec3, steps: Int, inPlate: Bool) {
        self.kind = kind
        self.size = size
        self.steps = steps
        self.inPlate = inPlate
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        let kind: Kind = try c.value("kind", .block)
        let standard = SetPiece.standard(kind, inPlate: false)
        try self.init(
            kind: kind,
            size: c.value("size", standard.size),
            steps: c.value("steps", standard.steps),
            inPlate: c.value("inPlate", false)
        )
    }

    /// The piece at an everyday size, to be fitted afterwards.
    public static func standard(_ kind: Kind, inPlate: Bool) -> SetPiece {
        let (size, steps): (Vec3, Int) = switch kind {
        case .block: (Vec3(1, 1, 1), 0)
        case .plinth: (Vec3(1.8, 0.3, 1.8), 0)
        case .dais: (Vec3(5, 0.45, 3), 2)
        case .stairs: (Vec3(2, 1.5, 2.7), 9)
        case .table: (Vec3(3.2, 0.78, 0.95), 0)
        case .bench: (Vec3(1.8, 0.46, 0.4), 0)
        case .throne: (Vec3(1.2, 2.3, 1.1), 0)
        case .wall: (Vec3(4, 3, 0.4), 0)
        case .parapet: (Vec3(4, 1.1, 0.6), 0)
        case .arch: (Vec3(3, 4, 0.8), 0)
        case .column: (Vec3(0.7, 4, 0.7), 0)
        }
        return SetPiece(kind: kind, size: size, steps: steps, inPlate: inPlate)
    }

    /// The catalog asset every piece of this kind uses.
    public var assetID: String {
        "set.\(kind.rawValue)"
    }

    /// Whether a person placed over the piece stands on top of it instead of inside it.
    public var isWalkable: Bool {
        switch kind {
        case .block, .plinth, .dais, .stairs: true
        case .table, .bench, .throne, .wall, .parapet, .arch, .column: false
        }
    }

    /// The piece as boxes in its own frame: origin on the ground at its centre, front toward −Z.
    public func parts() -> [PartSpec] {
        var list = PartList(width: max(size.x, 0.02), height: max(size.y, 0.02), depth: max(size.z, 0.02))
        switch kind {
        case .block, .plinth, .wall: list.box("body", Vec3(list.width, list.height, list.depth), y: 0)
        case .column: list.column()
        case .dais: list.dais(steps: max(steps, 0))
        case .stairs: list.stairs(steps: max(steps, 1))
        case .table: list.table()
        case .bench: list.bench()
        case .throne: list.throne()
        case .parapet: list.parapet()
        case .arch: list.arch()
        }
        return list.parts
    }

    static let tread = 0.32
    static let grey = RGB(hex: "#8a8f96")
}

/// Builds a set piece's boxes. Every box stands on `y` and is centred at (`x`, `z`) unless said otherwise.
private struct PartList {
    let width: Double, height: Double, depth: Double
    var parts: [PartSpec] = []

    mutating func box(_ id: String, _ size: Vec3, x: Double = 0, y: Double, z: Double = 0) {
        parts.append(PartSpec(
            id: id, shape: .box(size: size), position: Vec3(x, y + size.y / 2, z), rotation: .zero,
            color: SetPiece.grey
        ))
    }

    mutating func column() {
        parts.append(PartSpec(
            id: "body", shape: .cylinder(radius: width / 2, height: height), position: Vec3(0, height / 2, 0),
            rotation: .zero, color: SetPiece.grey
        ))
    }

    /// A platform with steps down its front, each a slab from the ground up so nothing shows through.
    mutating func dais(steps: Int) {
        box("platform", Vec3(width, height, depth), y: 0)
        for step in stride(from: 1, through: steps, by: 1) {
            let top = height * Double(steps + 1 - step) / Double(steps + 1)
            let z = -(depth / 2 + SetPiece.tread * (Double(step) - 0.5))
            box("step\(step)", Vec3(width, top, SetPiece.tread), y: 0, z: z)
        }
    }

    /// A flight rising toward the back.
    mutating func stairs(steps: Int) {
        let run = depth / Double(steps)
        for step in 1 ... steps {
            let top = height * Double(step) / Double(steps)
            box("step\(step)", Vec3(width, top, run), y: 0, z: -depth / 2 + run * (Double(step) - 0.5))
        }
    }

    /// A top on pedestals with a stretcher, so legs behind the table show between them as they would.
    mutating func table() {
        let top = min(0.09, height * 0.2)
        box("top", Vec3(width, top, depth), y: height - top)
        let inset = min(0.45, width * 0.2)
        var centres = [-(width / 2 - inset), width / 2 - inset]
        if width > 4 { centres.insert(0, at: 1) }
        for (index, x) in centres.enumerated() {
            box("pedestal\(index + 1)", Vec3(0.22, height - top, min(depth * 0.7, 0.55)), x: x, y: 0)
        }
        if width > 1.4 {
            box("stretcher", Vec3(width - 2 * inset, 0.1, 0.1), y: min(0.25, height * 0.3) - 0.05)
        }
    }

    mutating func bench() {
        let top = min(0.06, height * 0.2)
        box("seat", Vec3(width, top, depth), y: height - top)
        for (index, x) in [-(width / 2 - 0.12), width / 2 - 0.12].enumerated() {
            box("support\(index + 1)", Vec3(0.08, height - top, depth * 0.85), x: x, y: 0)
        }
    }

    /// A seat between two arms in front of a tall back.
    mutating func throne() {
        let seatHeight = min(0.52, height * 0.4), seatDepth = depth * 0.78, arm = width * 0.14
        let forward = -(depth - seatDepth) / 2
        box("seat", Vec3(width - 2 * arm, seatHeight, seatDepth), y: 0, z: forward)
        box("back", Vec3(width, height, depth - seatDepth), y: 0, z: seatDepth / 2)
        let armHeight = min(seatHeight + 0.28, height)
        for (index, x) in [-(width - arm) / 2, (width - arm) / 2].enumerated() {
            box("arm\(index + 1)", Vec3(arm, armHeight, seatDepth), x: x, y: 0, z: forward)
        }
    }

    /// A wall with merlons along its top.
    mutating func parapet() {
        box("wall", Vec3(width, height, depth), y: 0)
        let count = max(1, Int((width / 1.4).rounded()))
        let merlon = width / Double(2 * count)
        for index in 0 ..< count {
            box(
                "merlon\(index + 1)",
                Vec3(merlon, 0.5, depth),
                x: -width / 2 + merlon * (2 * Double(index) + 0.5),
                y: height
            )
        }
    }

    /// Two piers and a lintel; the opening is open.
    mutating func arch() {
        let pier = min(max(0.35, width * 0.18), width / 2), lintel = min(max(0.3, height * 0.15), height)
        for (index, x) in [-(width - pier) / 2, (width - pier) / 2].enumerated() {
            box("pier\(index + 1)", Vec3(pier, height - lintel, depth), x: x, y: 0)
        }
        box("lintel", Vec3(width, lintel, depth), y: height - lintel)
    }
}

/// The assets this app adds to Blockout's catalog: one per kind of set piece, and the dragons.
enum StudioAssets {
    static let setCategory = "set"
    static let creatures = "creatures"

    static let all: [AssetSpec] = SetPiece.Kind.allCases.map(setAsset) + Dragons.assets

    private static func setAsset(_ kind: SetPiece.Kind) -> AssetSpec {
        let piece = SetPiece.standard(kind, inPlate: false)
        let (name, noun) = switch kind {
        case .block: ("Block", "a stone block")
        case .plinth: ("Plinth", "a low stone plinth")
        case .dais: ("Dais with steps", "a raised dais with steps")
        case .stairs: ("Stairs", "a flight of stairs")
        case .table: ("Long table", "a long table")
        case .bench: ("Bench", "a bench")
        case .throne: ("Throne", "a throne")
        case .wall: ("Wall", "a wall")
        case .parapet: ("Parapet", "a battlement parapet")
        case .arch: ("Arch", "an archway")
        case .column: ("Column", "a column")
        }
        return AssetSpec(
            id: piece.assetID, name: name, category: setCategory, height: piece.size.y,
            footprint: max(piece.size.x, piece.size.z), speedScale: 1, motion: "static", promptNoun: noun
        )
    }
}

/// The tops of the walkable set pieces in a scene: where the floor is higher than the ground.
struct SetSurfaces: Sendable {
    private struct Slab: Sendable {
        var origin: Vec3, cosine: Double, sine: Double, scale: Double
        var centre: Vec3, half: Vec3
        var walkable: Bool
        var entityID: EntityID
        var partID: String

        /// The point in the slab's own frame, or nil when it is outside the slab's footprint.
        func local(x: Double, z: Double) -> (x: Double, z: Double)? {
            let dx = x - origin.x, dz = z - origin.z
            let lx = (dx * cosine - dz * sine) / scale - centre.x
            let lz = (dx * sine + dz * cosine) / scale - centre.z
            return abs(lx) <= half.x && abs(lz) <= half.z ? (lx, lz) : nil
        }

        var top: Double {
            origin.y + (centre.y + half.y) * scale
        }

        var bottom: Double {
            origin.y + (centre.y - half.y) * scale
        }
    }

    private let slabs: [Slab]

    init(entities: [PrevisEntity]) {
        slabs = entities.flatMap { entity -> [Slab] in
            guard let piece = entity.setPiece else { return [] }
            let placement = entity.placement
            return piece.parts().compactMap { part in
                guard case let .box(size) = part.shape else { return nil }
                return Slab(
                    origin: placement.position, cosine: cos(placement.heading), sine: sin(placement.heading),
                    scale: max(placement.scale, 1e-6), centre: part.position, half: size * 0.5,
                    walkable: piece.isWalkable, entityID: entity.id, partID: part.id
                )
            }
        }
    }

    var isEmpty: Bool {
        slabs.isEmpty
    }

    /// The height of the floor at a point: the highest walkable top there, or the ground.
    func floor(x: Double, z: Double) -> Double {
        slabs.reduce(0) { height, slab in
            slab.walkable && slab.local(x: x, z: z) != nil ? max(height, slab.top) : height
        }
    }

    /// The piece of furniture a person standing at this point is inside, if any: something that isn't walked on,
    /// rises above the feet and starts below head height (an arch's lintel overhead is not in the way).
    func blocker(x: Double, y: Double, z: Double) -> EntityID? {
        slabs.first { slab in
            !slab.walkable && slab.local(x: x, z: z) != nil && slab.top > y + 0.3 && slab.bottom < y + 1.5
        }?.entityID
    }
}
