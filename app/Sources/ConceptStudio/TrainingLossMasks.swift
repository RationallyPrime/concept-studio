import ConceptCore
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum TrainingLossMasks {
    private static let sourcePrefix = "ConceptStudio source-sha256:"

    static func url(for imageURL: URL, in project: URL) -> URL {
        ProjectAppState.folder(in: project).appendingPathComponent("training-masks", isDirectory: true)
            .appendingPathComponent(Sources.stem(of: imageURL.lastPathComponent) + ".png")
    }

    /// The source hash is embedded in the mask itself. Edited pixels invalidate a mask;
    /// restoring the original bytes with Undo restores its applicability too.
    static func validURL(for imageURL: URL, in project: URL) throws -> URL? {
        let mask = url(for: imageURL, in: project)
        guard FileManager.default.fileExists(atPath: mask.path), let source = CGImageSourceCreateWithURL(
                  mask as CFURL,
                  nil
              ),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let png = properties[kCGImagePropertyPNGDictionary] as? [CFString: Any],
              let description = png[kCGImagePropertyPNGDescription] as? String,
              try description == sourcePrefix + VisionInspector.contentHash(Data(contentsOf: imageURL))
        else { return nil }
        return mask
    }

    static func save(rectangles: [CGRect], imageURL: URL, project: StudioProject) throws {
        let bytes = try Data(contentsOf: imageURL), image = try MediaEditor.orientedImage(bytes)
        guard !rectangles.isEmpty, rectangles.allSatisfy({
            $0.minX >= 0 && $0.minY >= 0 && $0.maxX <= 1 && $0.maxY <= 1 && $0.width > 0 && $0.height > 0
        }) else { throw StudioError.message("Draw a mask inside the photo before saving.") }
        guard let context = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { throw StudioError.message("The training mask could not be created.") }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.setFillColor(gray: 0, alpha: 1)
        for rectangle in rectangles {
            context.fill(CGRect(
                x: rectangle.minX * Double(image.width), y: (1 - rectangle.maxY) * Double(image.height),
                width: rectangle.width * Double(image.width), height: rectangle.height * Double(image.height)
            ))
        }
        guard let mask = context.makeImage()
        else { throw StudioError.message("The training mask could not be rendered.") }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw StudioError.message("The training mask could not be saved.")
        }
        CGImageDestinationAddImage(destination, mask, [
            kCGImagePropertyPNGDictionary: [
                kCGImagePropertyPNGDescription: sourcePrefix + VisionInspector.contentHash(bytes),
            ],
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination)
        else { throw StudioError.message("The training mask could not be saved.") }
        let target = url(for: imageURL, in: project.directory)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try AtomicFile.write(data as Data, to: target)
    }
}
