import CoreGraphics
import Foundation
import PrevisCore
import simd

/// Reprojects only the floor and surfaces actually marked as present in the photographs.
enum PlateReprojection {
    @concurrent static func image(
        for frame: SceneFrame, size: PixelSize, sources: [(plate: LocationPlate, image: CGImage)]
    ) async throws -> CGImage {
        try Task.checkCancellation()
        let faces = try frame.entities.filter(\.isInPlate).flatMap { entity in
            try entity.parts.flatMap(PlateFace.faces)
        }
        let target = PlateView(camera: frame.camera, size: size)
        let targetMap = try PlateSurfaceMap(view: target, faces: faces)
        let photographs = try sources.compactMap { plate, image -> PlatePhotograph? in
            guard let match = plate.match else { return nil }
            return try PlatePhotograph(plate: plate, match: match, image: image, faces: faces)
        }
        return try PassDrawing.image(size: size) { context in
            // Each photograph owns the CFData backing its borrowed pixel pointer.
            defer { withExtendedLifetime(photographs) {} }
            let pixels = context.data!.assumingMemoryBound(to: UInt32.self)
            let stride = context.bytesPerRow / MemoryLayout<UInt32>.stride
            for y in 0 ..< size.height {
                try Task.checkCancellation()
                let firstRay = target.firstRay + Double(y) * target.stepY
                for x in 0 ..< size.width {
                    let index = y * size.width + x
                    let face = targetMap.ids[index]
                    var color: UInt32 = (x / 24 + y / 24).isMultiple(of: 2) ? 0xFF61_2C59 : 0xFF24_2129
                    if face >= 0 {
                        let ray = firstRay + Double(x) * target.stepX
                        let point = target.origin + Double(targetMap.depths[index]) * ray
                        let normal = face == 0 ? SIMD3<Double>(0, 1, 0) : faces[Int(face) - 1].normal
                        let visibleNormal = simd_dot(ray, normal) < 0 ? normal : -normal
                        var quality = 0.0
                        for photo in photographs {
                            if let sample = photo
                                .sample(point, normal: visibleNormal, face: face, betterThan: quality) {
                                color = sample.color
                                quality = sample.quality
                            }
                        }
                    }
                    pixels[y * stride + x] = color
                }
            }
        }
    }
}

/// Pixels are measured from the top-left edge. A ray has camera-space z = −1 so its multiplier is linear depth.
private struct PlateView {
    let size: PixelSize
    let origin: SIMD3<Double>
    let firstRay: SIMD3<Double>
    let stepX: SIMD3<Double>, stepY: SIMD3<Double>
    let focal: Double
    private let right: SIMD3<Double>, up: SIMD3<Double>, back: SIMD3<Double>

    init(camera: CameraFrame, size: PixelSize) {
        self.size = size
        let m = camera.viewMatrix().m
        right = SIMD3(m[0], m[4], m[8])
        up = SIMD3(m[1], m[5], m[9])
        back = SIMD3(m[2], m[6], m[10])
        origin = camera.position.vector
        focal = Double(size.height) / (2 * tan(camera.verticalFOV / 2))
        stepX = right / focal
        stepY = -up / focal
        firstRay = -back + (0.5 - Double(size.width) / 2) * stepX + (0.5 - Double(size.height) / 2) * stepY
    }

    func local(_ point: SIMD3<Double>) -> SIMD3<Double> {
        let offset = point - origin
        return SIMD3(simd_dot(offset, right), simd_dot(offset, up), simd_dot(offset, back))
    }

    func pixel(_ local: SIMD3<Double>) -> SIMD2<Double> {
        let scale = focal / -local.z
        return SIMD2(Double(size.width) / 2 + local.x * scale, Double(size.height) / 2 - local.y * scale)
    }
}

private extension Vec3 {
    var vector: SIMD3<Double> {
        SIMD3(x, y, z)
    }
}

/// One ID per planar face. Identical IDs in two views mean that both cameras see the same photographed surface.
private struct PlateFace {
    let vertices: [SIMD3<Double>]
    let normal: SIMD3<Double>

    static func faces(_ part: PosedPart) throws -> [PlateFace] {
        let polygons: [[Vec3]]
        switch part.shape {
        case let .box(size):
            let corners = (0 ..< 8).map { i in
                Vec3(
                    (i & 1 == 0 ? -0.5 : 0.5) * size.x,
                    (i & 2 == 0 ? -0.5 : 0.5) * size.y,
                    (i & 4 == 0 ? -0.5 : 0.5) * size.z
                )
            }
            polygons = [[0, 1, 3, 2], [4, 6, 7, 5], [0, 4, 5, 1], [2, 3, 7, 6], [0, 2, 6, 4], [1, 5, 7, 3]]
                .map { $0.map { corners[$0] } }
        case let .cylinder(radius, height):
            let sides = 48
            let top = (0 ..< sides).map { i in
                let angle = Double(i) * 2 * .pi / Double(sides)
                return Vec3(radius * cos(angle), height / 2, radius * sin(angle))
            }
            let bottom = top.map { Vec3($0.x, -$0.y, $0.z) }
            polygons = [top, bottom] + top.indices.map { i in
                let next = (i + 1) % sides
                return [top[i], top[next], bottom[next], bottom[i]]
            }
        default:
            throw ShotsMediaError("The photographed set piece contains an unsupported surface: \(part.id).")
        }
        return polygons.map { polygon in
            let points = polygon.map { part.transform.transform($0).vector }
            let normal = simd_normalize(simd_cross(points[1] - points[0], points[2] - points[0]))
            return PlateFace(vertices: points, normal: normal)
        }
    }
}

/// A z-buffer for photographed geometry. A negative ID means no mapped surface, zero is the world's floor.
private struct PlateSurfaceMap {
    var ids: [Int32]
    var depths: [Float]

    init(view: PlateView, faces: [PlateFace]) throws {
        let size = view.size
        depths = Array(repeating: .infinity, count: size.width * size.height)
        ids = Array(repeating: -1, count: depths.count)
        for y in 0 ..< size.height {
            try Task.checkCancellation()
            let firstY = view.firstRay.y + Double(y) * view.stepY.y
            for x in 0 ..< size.width {
                let directionY = firstY + Double(x) * view.stepX.y
                let depth = -view.origin.y / directionY
                if depth >= CameraFrame.near, depth <= CameraFrame.far {
                    let i = y * size.width + x
                    ids[i] = 0
                    depths[i] = Float(depth)
                }
            }
        }
        for (index, face) in faces.enumerated() {
            let polygon = clipToNear(face.vertices.map(view.local))
            guard polygon.count >= 3 else { continue }
            let projected = polygon.map(view.pixel)
            for i in 1 ..< polygon.count - 1 {
                try fill(
                    projected[0],
                    projected[i],
                    projected[i + 1],
                    inverseDepth: SIMD3(-1 / polygon[0].z, -1 / polygon[i].z, -1 / polygon[i + 1].z),
                    face: Int32(index + 1),
                    size: size
                )
            }
        }
    }

    private func clipToNear(_ polygon: [SIMD3<Double>]) -> [SIMD3<Double>] {
        var clipped: [SIMD3<Double>] = []
        for i in polygon.indices {
            let a = polygon[i], b = polygon[(i + 1) % polygon.count]
            let inside = a.z <= -CameraFrame.near
            if inside { clipped.append(a) }
            if inside != (b.z <= -CameraFrame.near) {
                let t = (-CameraFrame.near - a.z) / (b.z - a.z)
                clipped.append(a + t * (b - a))
            }
        }
        return clipped
    }

    private mutating func fill(
        _ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>,
        inverseDepth: SIMD3<Double>, face: Int32, size: PixelSize
    ) throws {
        let minX = Int(max(0, min(Double(size.width), floor(min(a.x, b.x, c.x)))))
        let maxX = Int(min(Double(size.width - 1), max(-1, ceil(max(a.x, b.x, c.x)))))
        let minY = Int(max(0, min(Double(size.height), floor(min(a.y, b.y, c.y)))))
        let maxY = Int(min(Double(size.height - 1), max(-1, ceil(max(a.y, b.y, c.y)))))
        guard minX <= maxX, minY <= maxY else { return }
        let area = edge(a, b, c)
        guard abs(area) > 1e-9 else { return }
        let du = (c.y - b.y) / area, dv = (a.y - c.y) / area
        for y in minY ... maxY {
            try Task.checkCancellation()
            let p = SIMD2(Double(minX) + 0.5, Double(y) + 0.5)
            var u = edge(b, c, p) / area, v = edge(c, a, p) / area
            for x in minX ... maxX {
                let w = 1 - u - v
                if min(u, v, w) >= -1e-9 {
                    let depth = Float(1 / (u * inverseDepth.x + v * inverseDepth.y + w * inverseDepth.z))
                    let i = y * size.width + x
                    if depth < depths[i], depth <= Float(CameraFrame.far) {
                        depths[i] = depth
                        ids[i] = face
                    }
                }
                u += du
                v += dv
            }
        }
    }

    private func edge(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ point: SIMD2<Double>) -> Double {
        (point.x - a.x) * (b.y - a.y) - (point.y - a.y) * (b.x - a.x)
    }
}

private struct PlatePhotograph {
    let view: PlateView
    let ids: [Int32]
    let data: CFData
    let pixels: UnsafePointer<UInt8>
    let bytesPerRow: Int

    init(plate: LocationPlate, match: PlateMatch, image: CGImage, faces: [PlateFace]) throws {
        let size = PixelSize(width: image.width, height: image.height)
        view = PlateView(camera: match.camera(aspect: plate.aspect), size: size)
        ids = try PlateSurfaceMap(view: view, faces: faces).ids
        let normalized = try PassDrawing.image(size: size) { context in
            // PassDrawing gives callers a top-left coordinate system. Undo it when drawing a CGImage.
            context.translateBy(x: 0, y: CGFloat(size.height))
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        }
        guard let data = normalized.dataProvider?.data, let pixels = CFDataGetBytePtr(data) else {
            throw ShotsMediaError("Plate “\(plate.name)” could not be decoded for projection.")
        }
        self.data = data
        self.pixels = pixels
        bytesPerRow = normalized.bytesPerRow
    }

    func sample(
        _ point: SIMD3<Double>, normal: SIMD3<Double>, face: Int32, betterThan minimum: Double
    ) -> (color: UInt32, quality: Double)? {
        let local = view.local(point)
        guard -local.z >= CameraFrame.near, -local.z <= CameraFrame.far else { return nil }
        let p = view.pixel(local)
        let size = view.size
        guard p.x >= 0, p.x < Double(size.width), p.y >= 0, p.y < Double(size.height) else { return nil }
        let x = Int(p.x), y = Int(p.y)
        guard ids[y * size.width + x] == face else { return nil }
        let towardCamera = view.origin - point
        // Prefer a large, front-on photographic footprint. The first plate wins a tie.
        let quality = view.focal * simd_dot(normal, towardCamera) / simd_length_squared(towardCamera)
        guard quality > minimum else { return nil }

        let px = max(0, min(Double(size.width - 1), p.x - 0.5))
        let py = max(0, min(Double(size.height - 1), p.y - 0.5))
        let left = Int(px), top = Int(py)
        let right = min(left + 1, size.width - 1), bottom = min(top + 1, size.height - 1)
        let color: UInt32
        if ids[top * size.width + left] == face, ids[top * size.width + right] == face,
           ids[bottom * size.width + left] == face, ids[bottom * size.width + right] == face {
            let h = px - Double(left), v = py - Double(top)
            func channel(_ n: Int) -> UInt32 {
                let a = Double(pixels[top * bytesPerRow + left * 4 + n])
                let b = Double(pixels[top * bytesPerRow + right * 4 + n])
                let c = Double(pixels[bottom * bytesPerRow + left * 4 + n])
                let d = Double(pixels[bottom * bytesPerRow + right * 4 + n])
                return UInt32(((a + h * (b - a)) * (1 - v) + (c + h * (d - c)) * v).rounded())
            }
            color = 0xFF00_0000 | channel(2) << 16 | channel(1) << 8 | channel(0)
        } else {
            // Filtering across a silhouette would import pixels from an occluder or its background.
            let i = y * bytesPerRow + x * 4
            color = 0xFF00_0000 | UInt32(pixels[i + 2]) << 16 | UInt32(pixels[i + 1]) << 8 | UInt32(pixels[i])
        }
        return (color, quality)
    }
}
