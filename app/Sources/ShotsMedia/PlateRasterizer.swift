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
    private let pixels: UnsafeMutablePointer<UInt8>
    private let bytesPerRow: Int
    private var depth: [Float]

    init(frame: SceneFrame, camera: CameraFrame, context: CGContext) {
        self.frame = frame
        self.camera = camera
        size = PixelSize(width: context.width, height: context.height)
        view = camera.viewMatrix()
        let rect = frame.plate?.imageRect(in: size)
        content = rect.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
            ?? CGRect(x: 0, y: 0, width: size.width, height: size.height)
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
        let near = 0.05
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
        for y in minY ... maxY {
            for x in minX ... maxX {
                let px = Double(x) + 0.5, py = Double(y) + 0.5
                let u = edge(b, c, px, py) / area
                let v = edge(c, a, px, py) / area
                let w = 1 - u - v
                guard u >= -0.000001, v >= -0.000001, w >= -0.000001 else { continue }
                let z = Float(1 / (u / -triangle[0].z + v / -triangle[1].z + w / -triangle[2].z))
                let index = y * size.width + x
                guard z < depth[index] else { continue }
                depth[index] = z
                guard let color else { continue }
                // Core Graphics' memory rows run top-to-bottom after the drawing context's Y flip.
                let offset = y * bytesPerRow + x * 4
                pixels[offset] = UInt8(color & 0xFF)
                pixels[offset + 1] = UInt8((color >> 8) & 0xFF)
                pixels[offset + 2] = UInt8((color >> 16) & 0xFF)
                pixels[offset + 3] = 255
            }
        }
    }

    private func edge(_ a: Point2, _ b: Point2, _ x: Double, _ y: Double) -> Double {
        (x - a.x) * (b.y - a.y) - (y - a.y) * (b.x - a.x)
    }
}
