import Foundation

// Dragons, CONTRACTS section 5.7: stand-ins for large winged dragons at their true size beside people, so a shot
// with one can be staged and framed. They are static grey-box bodies, built here because Blockout has no creature
// larger than a horse.
//
// A dragon's size is its standing head height: from the ground to the top of its skull, horns not counted. At
// scale 1 that is 10 m, so the entity's scale is the height in metres over ten: 1.5 for a dragon that stands
// 15 m, 0.76 for one of 7.6 m. At scale 1 the skull is about 1.4 m deep and 3 m long, and the spread wings
// about 32 m from tip to tip.

enum Dragons {
    static let standing = "creature.dragon"
    static let wingsSpread = "creature.dragon.spread"

    static let assets: [AssetSpec] = [
        AssetSpec(
            id: standing, name: "Dragon, wings folded", category: StudioAssets.creatures, height: headHeight,
            footprint: 27,
            speedScale: 1, motion: "static", promptNoun: "a huge winged dragon", parts: parts(spread: false)
        ),
        AssetSpec(
            id: wingsSpread, name: "Dragon, wings spread", category: StudioAssets.creatures, height: headHeight,
            footprint: 32.5, speedScale: 1, motion: "static", promptNoun: "a huge winged dragon with its wings spread",
            parts: parts(spread: true)
        ),
    ]

    /// Ground to the top of the skull at scale 1, in metres.
    static let headHeight = 10.0
    /// The body below is drawn with its skull top at 9.55; this brings it to `headHeight`.
    private static let unit = headHeight / 9.55

    private static let hide = RGB(hex: "#3d4047")
    private static let membrane = RGB(hex: "#555962")

    /// The dragon in its own frame: standing on the ground, its head toward −Z. A capsule or cone lies along +Y
    /// before `rotation` (Euler XYZ); a rotation of `x` about X tips that axis toward +Z.
    private static func parts(spread: Bool) -> [PartSpec] {
        var out: [PartSpec] = []
        func add(_ id: String, _ shape: PartShape, _ position: Vec3, _ rotation: Vec3 = .zero, wing: Bool = false) {
            out.append(PartSpec(
                id: id, shape: sized(shape), position: position * unit, rotation: rotation,
                color: wing ? membrane : hide
            ))
        }
        add("body", .capsule(radius: 1.9, length: 6), Vec3(0, 4.6, 0), Vec3(.pi / 2, 0, 0))
        add("chest", .sphere(radius: 2.2), Vec3(0, 4.9, -3))
        add("haunch", .sphere(radius: 2.0), Vec3(0, 4.5, 3))
        add("neck", .capsule(radius: 0.95, length: 4.6), Vec3(0, 7.0, -5.3), Vec3(-0.8, 0, 0))
        add("head", .box(size: Vec3(1.25, 1.3, 2.9)), Vec3(0, 8.9, -7.9))
        for (index, x) in [-0.42, 0.42].enumerated() {
            add("horn\(index + 1)", .cone(radius: 0.2, height: 1.3), Vec3(x, 9.9, -6.6), Vec3(0.75, 0, 0))
        }
        for (index, leg) in [(-2.0, -2.9), (2.0, -2.9), (-2.0, 2.9), (2.0, 2.9)].enumerated() {
            add("leg\(index + 1)", .capsule(radius: 0.7, length: 3.0), Vec3(leg.0, 2.3, leg.1))
            add("foot\(index + 1)", .box(size: Vec3(1.4, 0.5, 2.1)), Vec3(leg.0, 0.25, leg.1 - 0.5))
        }
        add("tail1", .capsule(radius: 1.1, length: 4), Vec3(0, 3.7, 6.7), Vec3(1.8, 0, 0))
        add("tail2", .capsule(radius: 0.7, length: 4), Vec3(0, 2.6, 10.9), Vec3(1.8, 0, 0))
        add("tail3", .capsule(radius: 0.42, length: 4), Vec3(0, 1.6, 15.0), Vec3(1.8, 0, 0))
        add("tailTip", .sphere(radius: 0.8), Vec3(0, 1.2, 17.4))
        for (index, side) in [-1.0, 1.0].enumerated() {
            if spread {
                add("wingArm\(index + 1)", .capsule(radius: 0.4, length: 13), Vec3(side * 8.4, 7.9, -1.6), Vec3(
                    0, 0, .pi / 2 - side * 0.12
                ))
                add("wing\(index + 1)", .box(size: Vec3(13.4, 0.2, 6.4)), Vec3(side * 8.6, 7.7, 1.2), Vec3(
                    0, 0, side * 0.12
                ), wing: true)
            } else {
                add("wing\(index + 1)", .box(size: Vec3(0.4, 4.6, 8.2)), Vec3(side * 2.5, 6.7, 0.8), Vec3(
                    0, 0, -side * 0.22
                ), wing: true)
            }
        }
        return out
    }

    private static func sized(_ shape: PartShape) -> PartShape {
        switch shape {
        case let .box(size): .box(size: size * unit)
        case let .cylinder(radius, height): .cylinder(radius: radius * unit, height: height * unit)
        case let .sphere(radius): .sphere(radius: radius * unit)
        case let .capsule(radius, length): .capsule(radius: radius * unit, length: length * unit)
        case let .cone(radius, height): .cone(radius: radius * unit, height: height * unit)
        case let .wedge(size): .wedge(size: size * unit)
        }
    }
}
