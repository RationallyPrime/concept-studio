import AppKit
import ImageIO
import UniformTypeIdentifiers

/// The same concrete numbered tiles for Mapping photos and a single clip's chronological frames.
enum NumberedContactSheet {
    static let tilePixels = 768

    static func jpeg(_ tiles: [(image: CGImage, label: String)], columns: Int) throws -> Data {
        let rows = (tiles.count + columns - 1) / columns
        let size = tilePixels
        guard let context = CGContext(
            data: nil, width: columns * size, height: rows * size,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw StudioError.message("The contact sheet could not be prepared.") }
        context.setFillColor(CGColor(gray: 0.15, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: columns * size, height: rows * size))
        for (index, tile) in tiles.enumerated() {
            let x = (index % columns) * size
            let y = (rows - 1 - index / columns) * size
            let scale = min(Double(size) / Double(tile.image.width), Double(size - 68) / Double(tile.image.height))
            let width = Double(tile.image.width) * scale
            let height = Double(tile.image.height) * scale
            context.draw(tile.image, in: CGRect(
                x: Double(x) + (Double(size) - width) / 2,
                y: Double(y) + (Double(size - 68) - height) / 2,
                width: width, height: height
            ))
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(CGRect(x: x, y: y + size - 68, width: size, height: 68))
            let label = NSAttributedString(string: tile.label, attributes: [
                .font: NSFont.boldSystemFont(ofSize: 48), .foregroundColor: NSColor.white,
            ])
            let line = CTLineCreateWithAttributedString(label)
            context.textPosition = CGPoint(x: x + 18, y: y + size - 52)
            CTLineDraw(line, context)
        }
        let output = NSMutableData()
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw StudioError.message("The contact sheet could not be encoded.") }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination)
        else { throw StudioError.message("The contact sheet could not be encoded.") }
        return output as Data
    }
}
