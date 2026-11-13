import CoreGraphics
import Foundation
import PrevisCore

/// Original photographed pixels plus the camera and visibility map that make them usable on shared geometry.
struct PlateTextureSource {
    let plate: LocationPlate
    let image: CGImage
    let pixels: [UInt8]
    let bytesPerRow: Int
    let camera: CameraFrame
    let view: Mat4
    let focal: Double
    let depthSize: PixelSize
    let depths: [Float]
    let depthRect: PlateImageRect
    let visibilityPieces: [PlateSetPiece]

    init(plate: LocationPlate, image: CGImage, frame: SceneFrame) throws {
        self.plate = plate
        self.image = image
        visibilityPieces = frame.setPieces.map { piece in
            var solid = piece
            solid.occludes = true
            return solid
        }
        camera = plate.calibration.frame(aspect: plate.pixelSize.aspect)
        view = camera.viewMatrix()
        focal = 1 / tan(camera.verticalFOV / 2)
        let normalized = try PassDrawing.image(size: PixelSize(width: image.width, height: image.height)) { context in
            PlateRasterizer.drawBackground(
                image,
                in: context,
                rect: CGRect(x: 0, y: 0, width: image.width, height: image.height)
            )
        }
        guard let data = normalized.dataProvider?.data else {
            throw ShotsMediaError("Plate “\(plate.name)” could not be decoded for projection.")
        }
        pixels = [UInt8](data as Data)
        bytesPerRow = normalized.bytesPerRow
        let scale = min(1, 512 / Double(max(image.width, image.height)))
        depthSize = PixelSize(
            width: max(1, Int((Double(image.width) * scale).rounded())),
            height: max(1, Int((Double(image.height) * scale).rounded()))
        )
        depthRect = plate.imageRect(in: depthSize)
        var sourceFrame = frame
        sourceFrame.plate = plate
        sourceFrame.entities = []
        depths = try PlateRasterizer.geometryDepths(frame: sourceFrame, camera: camera, size: depthSize)
    }

    /// A visible photographic coordinate and its sampling quality. Surface visibility is checked in source space.
    func coordinate(for point: Vec3, normal: Vec3) -> (u: Double, v: Double, quality: Double)? {
        let local = view.transform(point)
        let distance = -local.z
        guard distance >= CameraFrame.near else { return nil }
        let u = (local.x / distance * focal / plate.pixelSize.aspect + 1) / 2
        let v = (1 - local.y / distance * focal) / 2
        guard u >= 0, u < 1, v >= 0, v < 1 else { return nil }
        let x = min(depthSize.width - 1, Int(depthRect.x + u * depthRect.width))
        let y = min(depthSize.height - 1, Int(depthRect.y + v * depthRect.height))
        let occluder = Double(depths[y * depthSize.width + x])
        guard distance <= occluder + max(0.025, distance * 0.005) else { return nil }
        let dx = camera.position.x - point.x, dy = camera.position.y - point.y, dz = camera.position.z - point.z
        let length = sqrt(dx * dx + dy * dy + dz * dz)
        guard length > 0 else { return nil }
        let facing = abs((normal.x * dx + normal.y * dy + normal.z * dz) / length)
        guard facing > 0.02 else { return nil }
        return (u, v, facing / max(length, 1))
    }

    func canSee(_ point: Vec3) -> Bool {
        if camera.position.y > 0, point.y < -0.001 { return false }
        if camera.position.y < 0, point.y > 0.001 { return false }
        return !PlateSetPiece.occludes(point, camera: camera, pieces: visibilityPieces)
    }

    func color(u: Double, v: Double) -> UInt32 {
        let x = min(Double(image.width - 1), max(0, u * Double(image.width) - 0.5))
        let y = min(Double(image.height - 1), max(0, v * Double(image.height) - 0.5))
        let left = Int(x), top = Int(y)
        let right = min(image.width - 1, left + 1), bottom = min(image.height - 1, top + 1)
        let horizontal = x - Double(left), vertical = y - Double(top)
        func channel(_ offset: Int) -> UInt32 {
            let a = Double(pixels[top * bytesPerRow + left * 4 + offset])
            let b = Double(pixels[top * bytesPerRow + right * 4 + offset])
            let c = Double(pixels[bottom * bytesPerRow + left * 4 + offset])
            let d = Double(pixels[bottom * bytesPerRow + right * 4 + offset])
            return UInt32(((a + (b - a) * horizontal) * (1 - vertical)
                    + (c + (d - c) * horizontal) * vertical).rounded())
        }
        return channel(2) << 16 | channel(1) << 8 | channel(0)
    }
}

/// Camera-independent source cache reused for every frame of a moving-camera shot.
struct PlateTextures {
    let plates: [LocationPlate]
    let setPieces: [PlateSetPiece]
    let root: URL
    let sources: [PlateTextureSource]

    init(frame: SceneFrame, root: URL, images: (LocationPlate) throws -> CGImage) throws {
        let plates = frame.referencePlates.isEmpty ? frame.plate.map { [$0] } ?? [] : frame.referencePlates
        self.plates = plates
        setPieces = frame.setPieces
        self.root = root
        sources = try plates.map { try PlateTextureSource(plate: $0, image: images($0), frame: frame) }
    }

    func matches(frame: SceneFrame, root: URL) -> Bool {
        let plates = frame.referencePlates.isEmpty ? frame.plate.map { [$0] } ?? [] : frame.referencePlates
        return self.root == root && self.plates == plates && setPieces == frame.setPieces
    }

    func exactView(for frame: SceneFrame) -> PlateTextureSource? {
        guard let id = frame.matchedReferencePlate?.id else { return nil }
        return sources.first { $0.plate.id == id }
    }

    func color(at point: Vec3, normal: Vec3) -> UInt32? {
        var bestIndex: Int?
        var bestCoordinate = (u: 0.0, v: 0.0, quality: 0.0)
        for index in sources.indices {
            guard let coordinate = sources[index].coordinate(for: point, normal: normal),
                  coordinate.quality > bestCoordinate.quality,
                  sources[index].canSee(point) else { continue }
            bestIndex = index
            bestCoordinate = coordinate
        }
        guard let bestIndex else { return nil }
        return sources[bestIndex].color(u: bestCoordinate.u, v: bestCoordinate.v)
    }
}
