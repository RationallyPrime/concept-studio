import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import PrevisCore

/// Composes the original plate with flat stand-ins. Set pieces only write depth, leaving the photographed
/// surfaces intact. Composition, layout and mattes use the same projection and depth test.
struct PlateRasterizer {
    let frame: SceneFrame
    let size: PixelSize
    let camera: CameraFrame
    let content: CGRect
    private let view: Mat4
    private let cameraToWorld: Mat4
    private let projectionScale: Double
    private var textures: PlateTextures?
    private let pixels: UnsafeMutablePointer<UInt8>
    private let bytesPerRow: Int
    private var depth: [Float]

    init(frame: SceneFrame, camera: CameraFrame, context: CGContext) {
        self.frame = frame
        self.camera = camera
        size = PixelSize(width: context.width, height: context.height)
        view = camera.viewMatrix()
        cameraToWorld = view.inverse
        let rect = frame.plate?.imageRect(in: size)
        content = rect.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
            ?? CGRect(x: 0, y: 0, width: size.width, height: size.height)
        projectionScale = 2 * tan(camera.verticalFOV / 2) / content.height
        pixels = context.data!.assumingMemoryBound(to: UInt8.self)
        bytesPerRow = context.bytesPerRow
        depth = Array(repeating: .infinity, count: context.width * context.height)
    }

    static func load(_ plate: LocationPlate, root: URL?) throws -> CGImage {
        guard let root else { throw ShotsMediaError("Choose a project folder to load plate “\(plate.name)”.") }
        let url = root.appendingPathComponent(plate.imagePath)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ShotsMediaError("Plate “\(plate.name)” is missing or unreadable. Import it again.")
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientation = properties?[kCGImagePropertyOrientation] as? Int ?? 1
        let image: CGImage? = if orientation == 1 {
            CGImageSourceCreateImageAtIndex(source, 0, nil)
        } else {
            CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(plate.pixelSize.width, plate.pixelSize.height),
            ] as CFDictionary)
        }
        guard let image else {
            throw ShotsMediaError("Plate “\(plate.name)” is missing or unreadable. Import it again.")
        }
        return image
    }

    static func drawBackground(_ image: CGImage, in context: CGContext, rect: CGRect) {
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
        context.saveGState()
        context.interpolationQuality = .high
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }

    static func geometryDepths(frame: SceneFrame, camera: CameraFrame, size: PixelSize) throws -> [Float] {
        var result: [Float] = []
        _ = try PassDrawing.image(size: size) { context in
            var rasterizer = PlateRasterizer(frame: frame, camera: camera, context: context)
            for piece in frame.setPieces {
                rasterizer.box(piece.bounds, color: nil)
            }
            result = rasterizer.depth
        }
        return result
    }

    static func drawUnmapped(in context: CGContext, rect: CGRect) {
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
        context.saveGState()
        context.clip(to: rect)
        for y in stride(from: Int(floor(rect.minY / 24)) * 24, to: Int(ceil(rect.maxY)), by: 24) {
            for x in stride(from: Int(floor(rect.minX / 24)) * 24, to: Int(ceil(rect.maxX)), by: 24) {
                let color = unmappedColor(x: x, y: y)
                context.setFillColor(CGColor(
                    srgbRed: Double((color >> 16) & 255) / 255,
                    green: Double((color >> 8) & 255) / 255,
                    blue: Double(color & 255) / 255,
                    alpha: 1
                ))
                context.fill(CGRect(x: x, y: y, width: 24, height: 24))
            }
        }
        context.restoreGState()
    }

    /// Reconstructs only the shared geometry for which a calibrated photograph supplies visible pixels.
    mutating func drawLocation(using textures: PlateTextures) {
        self.textures = textures
        drawFloor(using: textures)
        let floorDepth = depth
        for piece in frame.setPieces {
            box(piece.bounds, color: nil)
        }
        self.textures = nil
        // A non-occluding marked surface still receives texture, while actors can show through it.
        depth = floorDepth
        for piece in frame.setPieces where piece.occludes {
            box(piece.bounds, color: nil)
        }
    }

    private mutating func drawFloor(using textures: PlateTextures?) {
        let minX = max(0, Int(ceil(content.minX))), maxX = min(size.width, Int(content.maxX))
        let minY = max(0, Int(ceil(content.minY))), maxY = min(size.height, Int(content.maxY))
        for y in minY ..< maxY {
            for x in minX ..< maxX {
                let ray = worldPoint(x: Double(x) + 0.5, y: Double(y) + 0.5, depth: 1)
                let directionY = ray.y - camera.position.y
                guard directionY < -1e-9 else { continue }
                let distance = -camera.position.y / directionY
                guard distance >= CameraFrame.near, distance <= CameraFrame.far else { continue }
                let point = worldPoint(x: Double(x) + 0.5, y: Double(y) + 0.5, depth: distance)
                depth[y * size.width + x] = Float(distance)
                if let textures {
                    write(
                        textures.color(at: point, normal: Vec3(0, 1, 0)) ?? Self.unmappedColor(x: x, y: y),
                        x: x,
                        y: y
                    )
                }
            }
        }
    }

    private func worldPoint(x: Double, y: Double, depth: Double) -> Vec3 {
        let scale = projectionScale * depth
        return cameraToWorld.transform(Vec3((x - content.midX) * scale, (content.midY - y) * scale, -depth))
    }

    private static func unmappedColor(x: Int, y: Int) -> UInt32 {
        (x / 24 + y / 24).isMultiple(of: 2) ? 0x612C59 : 0x242129
    }

    private func write(_ color: UInt32, x: Int, y: Int) {
        let offset = y * bytesPerRow + x * 4
        pixels[offset] = UInt8(color & 0xFF)
        pixels[offset + 1] = UInt8((color >> 8) & 0xFF)
        pixels[offset + 2] = UInt8((color >> 16) & 0xFF)
        pixels[offset + 3] = 255
    }

    mutating func draw(matte: EntityID? = nil, layout: Bool = false) {
        for piece in frame.setPieces where piece.occludes {
            box(piece.bounds, color: nil)
        }
        for (index, entity) in frame.entities.filter({ !layout || $0.isActor }).enumerated() {
            if layout {
                let rgb = PassDrawing.layoutPalette[index % PassDrawing.layoutPalette.count]
                let color = entity.label.map { Self.packed($0.color) }
                    ?? UInt32(rgb.0 << 16 | rgb.1 << 8 | rgb.2)
                box(entity.bounds, color: color)
            } else {
                let color: UInt32? = matte.map { $0 == entity.id ? 0xFFFFFF : 0 }
                for part in entity.parts {
                    let transform = view * part.transform
                    for triangle in PlateGeometry.triangles(part.shape) {
                        let points = triangle.map(transform.transform)
                        rasterize(points, color: color ?? Self.neutral(points))
                    }
                    if matte == nil, part.id == "head", case let .sphere(radius) = part.shape {
                        let front = [
                            Vec3(-radius * 0.5, -radius * 0.3, -radius * 0.92),
                            Vec3(radius * 0.5, -radius * 0.3, -radius * 0.92),
                            Vec3(0, radius * 0.45, -radius * 1.05),
                        ]
                        rasterize(front.map(transform.transform), color: 0x505050)
                    }
                }
            }
        }
    }

    private mutating func box(_ bounds: Box3, color: UInt32?) {
        let size = Vec3(
            bounds.max.x - bounds.min.x,
            bounds.max.y - bounds.min.y,
            bounds.max.z - bounds.min.z
        )
        let center = Vec3(
            (bounds.max.x + bounds.min.x) / 2,
            (bounds.max.y + bounds.min.y) / 2,
            (bounds.max.z + bounds.min.z) / 2
        )
        for triangle in PlateGeometry.box(size) {
            rasterize(triangle.map { point in
                view.transform(Vec3(point.x + center.x, point.y + center.y, point.z + center.z))
            }, color: color)
        }
    }

    private static func packed(_ color: RGB) -> UInt32 {
        UInt32((color.r * 255).rounded()) << 16 | UInt32((color.g * 255).rounded()) << 8
            | UInt32((color.b * 255).rounded())
    }

    private static func neutral(_ points: [Vec3]) -> UInt32 {
        let a = Vec3(points[1].x - points[0].x, points[1].y - points[0].y, points[1].z - points[0].z)
        let b = Vec3(points[2].x - points[0].x, points[2].y - points[0].y, points[2].z - points[0].z)
        let normal = Vec3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
        let length = sqrt(normal.x * normal.x + normal.y * normal.y + normal.z * normal.z)
        let light = length == 0 ? 0 : abs(normal.z / length)
        let value = UInt32(130 + 70 * light)
        return value << 16 | value << 8 | value
    }

    /// Clips triangles against the camera's near plane before perspective division.
    private mutating func rasterize(_ triangle: [Vec3], color: UInt32?) {
        var clipped: [Vec3] = []
        let near = CameraFrame.near
        for index in triangle.indices {
            let a = triangle[index], b = triangle[(index + 1) % triangle.count]
            if a.z <= -near { clipped.append(a) }
            if (a.z <= -near) != (b.z <= -near) {
                let t = (-near - a.z) / (b.z - a.z)
                clipped.append(Vec3(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, -near))
            }
        }
        guard clipped.count >= 3 else { return }
        for index in 1 ..< clipped.count - 1 {
            fill([clipped[0], clipped[index], clipped[index + 1]], color: color)
        }
    }

    private mutating func fill(_ triangle: [Vec3], color: UInt32?) {
        let focal = 1 / tan(camera.verticalFOV / 2)
        let projected = triangle.map { point in
            Point2(
                x: content.midX + point.x / -point.z * focal * content.height / 2,
                y: content.midY - point.y / -point.z * focal * content.height / 2
            )
        }
        let minX = max(Int(content.minX), Int(floor(projected.map(\.x).min()!)))
        let maxX = min(Int(ceil(content.maxX)) - 1, Int(ceil(projected.map(\.x).max()!)))
        let minY = max(Int(content.minY), Int(floor(projected.map(\.y).min()!)))
        let maxY = min(Int(ceil(content.maxY)) - 1, Int(ceil(projected.map(\.y).max()!)))
        guard minX <= maxX, minY <= maxY else { return }
        let a = projected[0], b = projected[1], c = projected[2]
        let area = edge(a, b, c.x, c.y)
        guard abs(area) > 0.000001 else { return }
        let world = triangle.map(cameraToWorld.transform)
        let u = Vec3(world[1].x - world[0].x, world[1].y - world[0].y, world[1].z - world[0].z)
        let v = Vec3(world[2].x - world[0].x, world[2].y - world[0].y, world[2].z - world[0].z)
        let cross = Vec3(u.y * v.z - u.z * v.y, u.z * v.x - u.x * v.z, u.x * v.y - u.y * v.x)
        let length = sqrt(cross.x * cross.x + cross.y * cross.y + cross.z * cross.z)
        let normal = length == 0 ? Vec3(0, 1, 0) : Vec3(cross.x / length, cross.y / length, cross.z / length)
        for y in minY ... maxY {
            for x in minX ... maxX {
                let px = Double(x) + 0.5, py = Double(y) + 0.5
                let u = edge(b, c, px, py) / area
                let v = edge(c, a, px, py) / area
                let w = 1 - u - v
                guard u >= -0.000001, v >= -0.000001, w >= -0.000001 else { continue }
                let z = Float(1 / (u / -triangle[0].z + v / -triangle[1].z + w / -triangle[2].z))
                let index = y * size.width + x
                guard z < depth[index], z <= Float(CameraFrame.far) else { continue }
                depth[index] = z
                if let color {
                    write(color, x: x, y: y)
                } else if let textures {
                    let point = worldPoint(x: px, y: py, depth: Double(z))
                    write(textures.color(at: point, normal: normal) ?? Self.unmappedColor(x: x, y: y), x: x, y: y)
                }
            }
        }
    }

    private func edge(_ a: Point2, _ b: Point2, _ x: Double, _ y: Double) -> Double {
        (x - a.x) * (b.y - a.y) - (y - a.y) * (b.x - a.x)
    }
}
