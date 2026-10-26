import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import PrevisCore
import UniformTypeIdentifiers

/// The passes drawn in 2D from evaluated frames: pose skeletons and layout boxes (CONTRACTS section 8.3).
enum PassDrawing {
    /// OpenPose's COCO-18 colours, in keypoint order. Limb i takes colour i too.
    static let openPoseColors: [(Int, Int, Int)] = [
        (255, 0, 0), (255, 85, 0), (255, 170, 0), (255, 255, 0), (170, 255, 0), (85, 255, 0), (0, 255, 0),
        (0, 255, 85), (0, 255, 170), (0, 255, 255), (0, 170, 255), (0, 85, 255), (0, 0, 255), (85, 0, 255),
        (170, 0, 255), (255, 0, 255), (255, 0, 170), (255, 0, 85),
    ]

    /// OpenPose's limbs, in drawing order.
    static let limbs: [(KeypointName, KeypointName)] = [
        (.neck, .rightShoulder), (.neck, .leftShoulder), (.rightShoulder, .rightElbow), (.rightElbow, .rightWrist),
        (.leftShoulder, .leftElbow), (.leftElbow, .leftWrist), (.neck, .rightHip), (.rightHip, .rightKnee),
        (.rightKnee, .rightAnkle), (.neck, .leftHip), (.leftHip, .leftKnee), (.leftKnee, .leftAnkle),
        (.neck, .nose), (.nose, .rightEye), (.rightEye, .rightEar), (.nose, .leftEye), (.leftEye, .leftEar),
    ]

    /// Layout colours for actors without a label, in actor order.
    static let layoutPalette: [(Int, Int, Int)] = [
        (230, 25, 75), (60, 180, 75), (0, 130, 200), (245, 130, 48), (145, 30, 180), (70, 240, 240),
        (240, 50, 230), (210, 245, 60),
    ]

    /// Drawn the way ComfyUI's DWPose preprocessor draws: on black, limbs at 60 % of their colour, then joints at full
    /// colour on top, without antialiasing, so a keypoint's pixel carries its exact colour. A keypoint behind the
    /// camera is left out, with its limbs.
    static func drawPose(_ frame: SceneFrame, in context: CGContext) {
        let size = frame.canvas.pixelSize
        context.setShouldAntialias(false)
        context.setFillColor(color((0, 0, 0)))
        context.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height))
        // OpenPose's stickwidth: the limb's half-width and the joint radius, 4 px on a 640 px canvas.
        let stick = max(1, Double(size.width) / 160)
        let people = frame.entities.map { entity in
            Dictionary(entity.keypoints.compactMap { keypoint in
                frame.camera.project(keypoint.position, size: size).map { (keypoint.name, $0) }
            }, uniquingKeysWith: { first, _ in first })
        }
        for pixels in people {
            for (index, limb) in limbs.enumerated() {
                guard let start = pixels[limb.0], let end = pixels[limb.1] else { continue }
                let (red, green, blue) = openPoseColors[index]
                context.setFillColor(color((red * 3 / 5, green * 3 / 5, blue * 3 / 5)))
                context.saveGState()
                context.translateBy(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
                context.rotate(by: atan2(end.y - start.y, end.x - start.x))
                let length = hypot(end.x - start.x, end.y - start.y)
                context.fillEllipse(in: CGRect(x: -length / 2, y: -stick, width: length, height: 2 * stick))
                context.restoreGState()
            }
        }
        for pixels in people {
            for (name, pixel) in pixels.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                context.setFillColor(color(openPoseColors[name.rawValue]))
                context.fillEllipse(in: CGRect(
                    x: pixel.x - stick,
                    y: pixel.y - stick,
                    width: 2 * stick,
                    height: 2 * stick
                ))
            }
        }
    }

    /// On white, one filled box per actor covering its projected bounds, in entity order. The colour is the label's,
    /// or else the palette's in actor order.
    static func drawLayout(_ frame: SceneFrame, in context: CGContext) {
        let size = frame.canvas.pixelSize
        context.setShouldAntialias(false)
        context.setFillColor(color((255, 255, 255)))
        context.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height))
        for (index, entity) in frame.entities.filter(\.isActor).enumerated() {
            guard let box = projectedBounds(entity.bounds, camera: frame.camera, size: size) else { continue }
            if let label = entity.label {
                context.setFillColor(CGColor(
                    srgbRed: label.color.r,
                    green: label.color.g,
                    blue: label.color.b,
                    alpha: 1
                ))
            } else {
                context.setFillColor(color(layoutPalette[index % layoutPalette.count]))
            }
            context.fill(box)
        }
    }

    /// The pixel rectangle covering a box's corners in front of the camera, clipped to the canvas; nil when nothing
    /// is left.
    static func projectedBounds(_ box: Box3, camera: CameraFrame, size: PixelSize) -> CGRect? {
        let corners = [box.min.x, box.max.x].flatMap { x in
            [box.min.y, box.max.y].flatMap { y in [box.min.z, box.max.z].map { z in Vec3(x, y, z) } }
        }
        let pixels = corners.compactMap { camera.project($0, size: size) }
        guard let minX = pixels.map(\.x).min(), let maxX = pixels.map(\.x).max(),
              let minY = pixels.map(\.y).min(), let maxY = pixels.map(\.y).max()
        else { return nil }
        let clipped = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            .intersection(CGRect(x: 0, y: 0, width: size.width, height: size.height))
        return clipped.isNull || clipped.isEmpty ? nil : clipped
    }

    static func pose(_ frame: SceneFrame, into buffer: CVPixelBuffer) throws {
        try draw(into: buffer) { drawPose(frame, in: $0) }
    }

    static func layout(_ frame: SceneFrame, into buffer: CVPixelBuffer) throws {
        try draw(into: buffer) { drawLayout(frame, in: $0) }
    }

    /// Runs `draw` on a context over `buffer`'s pixels, with the origin at the top left and y down.
    static func draw(into buffer: CVPixelBuffer, _ draw: (CGContext) -> Void) throws {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = context(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: CVPixelBufferGetWidth(buffer),
            height: CVPixelBufferGetHeight(buffer),
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer)
        ) else { throw ShotsMediaError("Shots couldn't draw into a frame buffer.") }
        draw(context)
    }

    /// An image of `size` made by `draw`, in the renderer's pixel format.
    static func image(size: PixelSize, _ draw: (CGContext) -> Void) throws -> CGImage {
        guard let context = context(data: nil, width: size.width, height: size.height, bytesPerRow: 0) else {
            throw ShotsMediaError("Shots couldn't draw a \(size.width) × \(size.height) image.")
        }
        draw(context)
        guard let image = context.makeImage() else { throw ShotsMediaError("Shots couldn't finish a drawn image.") }
        return image
    }

    private static func context(
        data: UnsafeMutableRawPointer?,
        width: Int,
        height: Int,
        bytesPerRow: Int
    ) -> CGContext? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: data,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: bytesPerRow,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              )
        else { return nil }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        return context
    }

    private static func color(_ rgb: (Int, Int, Int)) -> CGColor {
        CGColor(srgbRed: Double(rgb.0) / 255, green: Double(rgb.1) / 255, blue: Double(rgb.2) / 255, alpha: 1)
    }
}

/// Stills as external tools expect them: 8-bit RGB PNG in sRGB, with no alpha, exactly the image's size.
enum StillWriter {
    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: image.width,
                  height: image.height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              )
        else { throw ShotsMediaError("Shots couldn't prepare \(url.lastPathComponent).") }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let rgb = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw ShotsMediaError("Shots couldn't write \(url.lastPathComponent).") }
        CGImageDestinationAddImage(destination, rgb, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ShotsMediaError("Shots couldn't finish writing \(url.lastPathComponent).")
        }
    }
}
