import CoreGraphics
import CoreText
import CoreVideo
import Foundation
import ImageIO
import PrevisCore

/// The plate images of a project, read from its `Shots/Plates` folder and kept while they don't change.
@MainActor public final class PlateImages {
    public let folder: URL
    private var cache: [String: (modified: Date?, image: CGImage)] = [:]

    public init(folder: URL) {
        self.folder = folder
    }

    /// `<project>/Shots/Plates`, where a project keeps the plates its shots are blocked over.
    public nonisolated static func folder(inProject project: URL) -> URL {
        project.appendingPathComponent("Shots", isDirectory: true).appendingPathComponent("Plates", isDirectory: true)
    }

    public func image(for plate: LocationPlate) throws -> CGImage {
        let url = folder.appendingPathComponent(plate.file)
        let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        if let cached = cache[plate.file], cached.modified == modified { return cached.image }
        let image = try Self.read(url, name: plate.name)
        cache[plate.file] = (modified, image)
        return image
    }

    /// Reads an image file as it is, without resampling or colour changes.
    public nonisolated static func read(_ url: URL, name: String) throws -> CGImage {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ShotsMediaError(
                "The image of the plate \"\(name)\" is missing: \(url.lastPathComponent) is not in the project's "
                    + "Shots/Plates folder. Add the plate again."
            )
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw ShotsMediaError("\(url.lastPathComponent) isn't an image Shots can read. Use a PNG or JPEG plate.")
        }
        return image
    }

    /// The pixel size of an image file, read from its header.
    public nonisolated static func pixelSize(of url: URL) -> PixelSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        // A sideways orientation tag swaps the stored width and height.
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        return orientation >= 5 ? PixelSize(width: height, height: width) : PixelSize(width: width, height: height)
    }
}

/// How stand-ins are drawn over a plate.
public struct StandInOptions: Sendable, Equatable {
    /// Each actor in its own flat stand-in colour (`StandInPalette`), not the mannequin's greys.
    public var colored: Bool
    /// A name tag over each actor. Off for the picture an image model composes from, which copies visible text.
    public var labels: Bool
    /// How strongly the set pieces the plate already shows are drawn over it, 0 to 1. At 0 they only hide what is
    /// behind them; above 0 they show through, for fitting them to the plate.
    public var setPieceOpacity: Double

    public init(colored: Bool, labels: Bool, setPieceOpacity: Double) {
        self.colored = colored
        self.labels = labels
        self.setPieceOpacity = setPieceOpacity
    }

    /// The composition guide: coloured stand-ins, no text, the plate untouched where nobody stands.
    public static let guide = StandInOptions(colored: true, labels: false, setPieceOpacity: 0)
    /// The same with name tags, for people to read.
    public static let labelledGuide = StandInOptions(colored: true, labels: true, setPieceOpacity: 0)
    /// For blocking: set pieces show faintly so they can be fitted to the plate.
    public static let blocking = StandInOptions(colored: true, labels: true, setPieceOpacity: 0.45)
}

public extension ShotFrameRenderer {
    /// The colour of a set piece shown over its plate for fitting.
    internal static let fittingTint = RGB(hex: "#22d3ee")

    /// The frame's stand-ins over a plate. The plate keeps its shape and its pixels: it is placed as the frame's
    /// camera sees it (`PlateFit`) and only covered where a stand-in is. A set piece the plate already shows
    /// hides the stand-ins behind it, so the plate shows there. `size` nil is the frame's canvas.
    func image(
        of frame: SceneFrame,
        over plate: CGImage,
        look: PrevisLook,
        options: StandInOptions,
        sensor: Sensor,
        size: PixelSize? = nil
    ) async throws -> CGImage {
        let size = size ?? frame.canvas.pixelSize
        guard size.width > 0, size.height > 0 else {
            throw ShotsMediaError("Shots can't render a \(size.width) × \(size.height) image.")
        }
        var sized = frame
        sized.canvas = ShotCanvas(width: size.width, height: size.height)
        let actors = frame.entities.filter(\.isActor)
        var tints: [EntityID: RGB] = [:]
        if options.colored {
            for (index, actor) in actors.enumerated() {
                tints[actor.id] = StandInPalette.standIn(index).color
            }
        }
        // Each person gets a nose and a dark visor, so the picture shows which way they face.
        var marked = sized
        for visor in actors.compactMap(StandInFace.visor) {
            marked.entities.append(visor)
            tints[visor.id] = StandInFace.visorColor
        }
        marked.entities = marked.entities.map(StandInFace.withNose)
        let drawn = Set(marked.entities.filter { !$0.isInPlate }.map(\.id))
        let inPlate = Set(frame.entities.filter(\.isInPlate).map(\.id))
        if options.setPieceOpacity > 0 {
            // A colour no plate is likely to have, so a faint set piece reads against wood and stone.
            for id in inPlate {
                tints[id] = Self.fittingTint
            }
        }
        let color = try pixelBuffer(size), alpha = try pixelBuffer(size)
        try await render(marked, look: look, matte: nil, softMatte: false, tints: tints, into: color)
        try await render(marked, look: look, matte: drawn, softMatte: true, tints: [:], into: alpha)
        var ghost: CVPixelBuffer?
        if options.setPieceOpacity > 0, !inPlate.isEmpty {
            let buffer = try pixelBuffer(size)
            try await render(marked, look: look, matte: inPlate, softMatte: true, tints: [:], into: buffer)
            ghost = buffer
        }
        let image = try PlateComposite.blend(
            plate: plate, color: color, alpha: alpha, ghost: ghost, ghostOpacity: options.setPieceOpacity,
            background: look.palette.background, size: size, sensor: sensor
        )
        guard options.labels else { return image }
        return try PlateComposite.labelled(image, frame: sized)
    }
}

/// What a stand-in's head carries in a guide so its facing reads: a nose, and a dark band across the eyes. The
/// grey-box figure's head is a plain sphere, which looks the same from every side.
enum StandInFace {
    static let visorColor = RGB(hex: "#14161a")

    /// The head's centre, radius and axes from the rig's face keypoints; nil for anything without a face.
    private static func head(of entity: EntityFrame) -> (centre: Vec3, radius: Double, axes: (Vec3, Vec3, Vec3))? {
        let points = Dictionary(
            entity.keypoints.map { ($0.name, $0.position) },
            uniquingKeysWith: { first, _ in first }
        )
        guard let nose = points[.nose], let earL = points[.leftEar], let earR = points[.rightEar] else { return nil }
        let centre = Vec3((earL.x + earR.x) / 2, (earL.y + earR.y) / 2, (earL.z + earR.z) / 2)
        let across = Vec3(earR.x - earL.x, earR.y - earL.y, earR.z - earL.z)
        let radius = (across.x * across.x + across.y * across.y + across.z * across.z).squareRoot() / 2
        guard radius > 1e-6 else { return nil }
        let right = Vec3(across.x / (2 * radius), across.y / (2 * radius), across.z / (2 * radius))
        var forward = Vec3(nose.x - centre.x, nose.y - centre.y, nose.z - centre.z)
        // Square the forward direction to the ear line, then build the third axis.
        let along = forward.x * right.x + forward.y * right.y + forward.z * right.z
        forward = Vec3(forward.x - right.x * along, forward.y - right.y * along, forward.z - right.z * along)
        let length = (forward.x * forward.x + forward.y * forward.y + forward.z * forward.z).squareRoot()
        guard length > 1e-6 else { return nil }
        let back = Vec3(-forward.x / length, -forward.y / length, -forward.z / length)
        let up = Vec3(
            back.y * right.z - back.z * right.y, back.z * right.x - back.x * right.z,
            back.x * right.y - back.y * right.x
        )
        return (centre, radius, (right, up, back))
    }

    /// A box-to-world matrix with the head's axes, centred `forward` head-radii in front of the head's centre and
    /// `up` above it.
    private static func place(
        _ head: (centre: Vec3, radius: Double, axes: (Vec3, Vec3, Vec3)), forward: Double, up: Double
    ) -> Mat4 {
        let (right, upward, back) = head.axes
        let reach = head.radius * forward, lift = head.radius * up
        var matrix = Mat4.identity
        matrix.m = [
            right.x, right.y, right.z, 0, upward.x, upward.y, upward.z, 0, back.x, back.y, back.z, 0,
            head.centre.x - back.x * reach + upward.x * lift, head.centre.y - back.y * reach + upward.y * lift,
            head.centre.z - back.z * reach + upward.z * lift, 1,
        ]
        return matrix
    }

    /// The entity with a nose on its head, in its own colour.
    static func withNose(_ entity: EntityFrame) -> EntityFrame {
        guard let head = head(of: entity) else { return entity }
        var entity = entity
        let r = head.radius
        entity.parts.append(PosedPart(
            id: "standInNose", shape: .box(size: Vec3(0.36 * r, 0.4 * r, 0.6 * r)),
            transform: place(head, forward: 1.12, up: -0.12), color: entity.parts.first?.color ?? visorColor
        ))
        return entity
    }

    /// A dark band across the eyes, as an entity of its own so it keeps its colour beside the stand-in's.
    static func visor(_ entity: EntityFrame) -> EntityFrame? {
        guard let head = head(of: entity) else { return nil }
        let r = head.radius
        let part = PosedPart(
            id: "standInVisor", shape: .box(size: Vec3(1.7 * r, 0.34 * r, 0.9 * r)),
            transform: place(head, forward: 0.62, up: 0.24), color: visorColor
        )
        return EntityFrame(
            id: entity.id + "#visor", assetID: entity.assetID, name: entity.name, isActor: false,
            position: entity.position, heading: entity.heading, gait: entity.gait, speed: 0, distanceTravelled: 0,
            parts: [part], bounds: entity.bounds
        )
    }
}

/// The 2D half of drawing stand-ins over a plate.
enum PlateComposite {
    /// `plate` where the mattes are black, the rendered colour where they are white. All buffers are BGRA of `size`.
    static func blend(
        plate: CGImage,
        color: CVPixelBuffer,
        alpha: CVPixelBuffer,
        ghost: CVPixelBuffer?,
        ghostOpacity: Double,
        background: RGB,
        size: PixelSize,
        sensor: Sensor
    ) throws -> CGImage {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: size.width, height: size.height, bitsPerComponent: 8,
                  bytesPerRow: size.width * 4, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              ),
              let output = context.data
        else { throw ShotsMediaError("Shots couldn't prepare a \(size.width) × \(size.height) image.") }
        context.setFillColor(background.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height))
        let fit = PlateFit.rect(
            plate: PixelSize(width: plate.width, height: plate.height), canvas: size, sensor: sensor
        )
        context.interpolationQuality = .high
        // The context's origin is at the bottom left; the fit is centred, so it reads the same either way up.
        context.draw(plate, in: CGRect(x: fit.x, y: fit.y, width: fit.width, height: fit.height))

        let buffers = [color, alpha] + (ghost.map { [$0] } ?? [])
        for buffer in buffers {
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
        }
        defer {
            for buffer in buffers {
                CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            }
        }
        guard let colorBase = CVPixelBufferGetBaseAddress(color), let alphaBase = CVPixelBufferGetBaseAddress(alpha)
        else { throw ShotsMediaError("Shots couldn't read back a rendered frame.") }
        let colorRow = CVPixelBufferGetBytesPerRow(color), alphaRow = CVPixelBufferGetBytesPerRow(alpha)
        let ghostBase = ghost.flatMap { CVPixelBufferGetBaseAddress($0) }
        let ghostRow = ghost.map { CVPixelBufferGetBytesPerRow($0) } ?? 0
        let outputRow = context.bytesPerRow
        let ghostWeight = Int((min(max(ghostOpacity, 0), 1) * 256).rounded())
        for y in 0 ..< size.height {
            let out = output.advanced(by: y * outputRow).assumingMemoryBound(to: UInt8.self)
            let source = colorBase.advanced(by: y * colorRow).assumingMemoryBound(to: UInt8.self)
            let matte = alphaBase.advanced(by: y * alphaRow).assumingMemoryBound(to: UInt8.self)
            let faint = ghostBase?.advanced(by: y * ghostRow).assumingMemoryBound(to: UInt8.self)
            for x in 0 ..< size.width {
                let offset = x * 4
                // Green of the matte is its coverage, 0 to 255; a faint set piece adds a share of its own.
                var weight = Int(matte[offset + 1])
                if let faint { weight += Int(faint[offset + 1]) * ghostWeight / 256 }
                guard weight > 0 else { continue }
                weight = min(weight, 255)
                for channel in 0 ..< 3 {
                    let under = Int(out[offset + channel]), over = Int(source[offset + channel])
                    out[offset + channel] = UInt8(under + (over - under) * weight / 255)
                }
            }
        }
        guard let image = context.makeImage() else { throw ShotsMediaError("Shots couldn't finish a plate image.") }
        return image
    }

    /// The image with a name tag over each actor that shows, in the actor's stand-in colour.
    static func labelled(_ image: CGImage, frame: SceneFrame) throws -> CGImage {
        let size = PixelSize(width: image.width, height: image.height)
        let staged = StagingAnalysis.characters(in: frame)
        return try PassDrawing.image(size: size) { context in
            // PassDrawing's context has its origin at the top left; images and text are drawn flipped back.
            context.saveGState()
            context.translateBy(x: 0, y: CGFloat(size.height))
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
            context.restoreGState()
            let fontSize = max(11, Double(size.height) / 52)
            let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
            for (index, character) in staged.enumerated() where character.isVisible {
                guard let box = character.box else { continue }
                let tint = StandInPalette.standIn(index).color
                let text = NSAttributedString(string: character.name, attributes: [
                    kCTFontAttributeName as NSAttributedString.Key: font,
                    kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(gray: 1, alpha: 1),
                ])
                let line = CTLineCreateWithAttributedString(text)
                let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
                let pad = fontSize * 0.45
                let width = bounds.width + 2 * pad, height = fontSize * 1.5
                let centre = (box.x + box.width / 2) * Double(size.width)
                let x = min(max(2, centre - width / 2), Double(size.width) - width - 2)
                let top = box.y * Double(size.height)
                let y = top - height - 4 >= 2 ? top - height - 4 : min(top + 4, Double(size.height) - height - 2)
                let tag = CGRect(x: x, y: y, width: width, height: height)
                context.setFillColor(tint.cgColor)
                context.addPath(CGPath(
                    roundedRect: tag,
                    cornerWidth: height / 4,
                    cornerHeight: height / 4,
                    transform: nil
                ))
                context.fillPath()
                context.saveGState()
                context.translateBy(x: 0, y: tag.maxY)
                context.scaleBy(x: 1, y: -1)
                context.textPosition = CGPoint(x: tag.minX + pad - bounds.minX, y: (height - fontSize * 0.72) / 2)
                CTLineDraw(line, context)
                context.restoreGState()
            }
        }
    }
}
