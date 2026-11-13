import Foundation
import PrevisCore

/// Low-poly surfaces for the same evaluated primitives used by the live stage.
/// Plate guides deliberately keep these surfaces neutral and featureless.
enum PlateGeometry {
    typealias Triangle = [Vec3]

    static func triangles(_ shape: PartShape) -> [Triangle] {
        switch shape {
        case let .box(size): return box(size)
        case let .wedge(size): return wedge(size)
        case let .sphere(radius):
            return lathe((0 ... 8).map { index in
                let angle = Double(index) * .pi / 8
                return (radius * sin(angle), radius * cos(angle))
            })
        case let .capsule(radius, length):
            let top = (0 ... 4).map { index in
                let angle = Double(index) * .pi / 8
                return (radius * sin(angle), length / 2 + radius * cos(angle))
            }
            let bottom = (4 ... 8).map { index in
                let angle = Double(index) * .pi / 8
                return (radius * sin(angle), -length / 2 + radius * cos(angle))
            }
            return lathe(top + bottom)
        case let .cylinder(radius, height):
            return lathe([(0, height / 2), (radius, height / 2), (radius, -height / 2), (0, -height / 2)])
        case let .cone(radius, height):
            return lathe([(0, height / 2), (radius, -height / 2), (0, -height / 2)])
        }
    }

    static func box(_ size: Vec3) -> [Triangle] {
        let points = (0 ..< 8).map { index in
            Vec3(
                (index & 1 == 0 ? -1 : 1) * size.x / 2,
                (index & 2 == 0 ? -1 : 1) * size.y / 2,
                (index & 4 == 0 ? -1 : 1) * size.z / 2
            )
        }
        let faces = [[0, 1, 3, 2], [4, 6, 7, 5], [0, 4, 5, 1], [2, 3, 7, 6], [0, 2, 6, 4], [1, 5, 7, 3]]
        return faces.flatMap { face in
            [
                [points[face[0]], points[face[1]], points[face[2]]],
                [points[face[0]], points[face[2]], points[face[3]]],
            ]
        }
    }

    private static func wedge(_ size: Vec3) -> [Triangle] {
        let x = size.x / 2, y = size.y / 2, z = size.z / 2
        let points = [
            Vec3(-x, -y, z),
            Vec3(x, -y, z),
            Vec3(x, -y, -z),
            Vec3(-x, -y, -z),
            Vec3(-x, y, -z),
            Vec3(x, y, -z),
        ]
        return [[0, 3, 2], [0, 2, 1], [3, 4, 5], [3, 5, 2], [0, 1, 5], [0, 5, 4], [0, 4, 3], [1, 2, 5]]
            .map { $0.map { points[$0] } }
    }

    private static func lathe(_ profile: [(Double, Double)]) -> [Triangle] {
        let sides = 12
        var triangles: [Triangle] = []
        func point(_ ring: Int, _ side: Int) -> Vec3 {
            let angle = Double(side) * 2 * .pi / Double(sides)
            return Vec3(profile[ring].0 * cos(angle), profile[ring].1, profile[ring].0 * sin(angle))
        }
        for ring in 0 ..< profile.count - 1 {
            for side in 0 ..< sides {
                let a = point(ring, side), b = point(ring, side + 1)
                let c = point(ring + 1, side + 1), d = point(ring + 1, side)
                triangles += [[a, b, c], [a, c, d]]
            }
        }
        return triangles
    }
}
