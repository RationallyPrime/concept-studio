import AppKit
import ConceptCore
import ImageIO
import UniformTypeIdentifiers

struct MappingTile: Decodable, Sendable {
    let tile: Int
    let description: String
    let locators: [MappingLocator]
    static let schema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "tile": .object(["type": .string("integer")]),
            "description": .object(["type": .string("string")]),
            "locators": .object(["type": .string("array"), "items": MappingLocator.schema]),
        ]),
        "required": .array(["tile", "description", "locators"].map(JSONValue.string)),
        "additionalProperties": .bool(false),
    ])
}

struct MappingSheetDraft: Decodable, Sendable {
    let tiles: [MappingTile]
    static let schema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object(["tiles": .object(["type": .string("array"), "items": MappingTile.schema])]),
        "required": .array([.string("tiles")]), "additionalProperties": .bool(false),
    ])
}

struct MappingSuggestion: Sendable {
    let mapping: Job.Mapping
    let description: String
}

struct MappingBatchResult: Sendable {
    var suggestions: [String: MappingSuggestion] = [:]
    var failures: [String] = []
}

enum MappingRequests {
    /// Preserve input order, and keep videos as individual requests with actual temporal evidence.
    static func batches(_ images: [ProjectImage], size: Int) -> [[ProjectImage]] {
        let size = [1, 4, 9].contains(size) ? size : 1
        var batches: [[ProjectImage]] = []
        var stills: [ProjectImage] = []
        for image in images {
            if Sources.isVideo(Sources.suffix(of: image.id)) {
                if !stills.isEmpty { batches.append(stills); stills = [] }
                batches.append([image])
            } else {
                stills.append(image)
                if stills.count == size { batches.append(stills); stills = [] }
            }
        }
        if !stills.isEmpty { batches.append(stills) }
        return batches
    }

    static func isTransient(_ error: any Error) -> Bool {
        if let error = error as? ModelError {
            switch error {
            case .transport: return true
            case let .http(status, _): return status == 408 || status == 429 || (500 ... 599).contains(status)
            default: return false
            }
        }
        if let error = error as? URLError {
            return [
                .timedOut,
                .networkConnectionLost,
                .cannotConnectToHost,
                .cannotFindHost,
                .notConnectedToInternet,
                .dnsLookupFailed,
            ].contains(error.code)
        }
        return false
    }

    /// 768px retains more face detail in full-body photographs than 512px; layouts remain explicit
    /// until a confirmed-data benchmark establishes the best choice for the user's model.
    static let tilePixels = 768

    static func contactSheet(_ images: [ProjectImage]) throws -> UserContent {
        guard !images.isEmpty,
              images.count <= 9 else { throw StudioError.message("Choose one to nine mapping photos.") }
        let columns = images.count <= 1 ? 1 : images.count <= 4 ? 2 : 3
        let rows = (images.count + columns - 1) / columns
        let size = tilePixels
        guard let context = CGContext(
            data: nil,
            width: columns * size,
            height: rows * size,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        else { throw StudioError.message("The mapping contact sheet could not be prepared.") }
        context.setFillColor(CGColor(gray: 0.15, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: columns * size, height: rows * size))
        for (index, image) in images.enumerated() {
            guard let source = CGImageSourceCreateWithURL(image.url as CFURL, nil),
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceThumbnailMaxPixelSize: size,
                  ] as CFDictionary) else { throw StudioError.message("\(image.id) could not be read.") }
            let x = (index % columns) * size
            let y = (rows - 1 - index / columns) * size
            let scale = min(Double(size) / Double(thumbnail.width), Double(size - 68) / Double(thumbnail.height))
            let width = Double(thumbnail.width) * scale
            let height = Double(thumbnail.height) * scale
            context.draw(thumbnail, in: CGRect(
                x: Double(x) + (Double(size) - width) / 2,
                y: Double(y) + (Double(size - 68) - height) / 2,
                width: width,
                height: height
            ))
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(CGRect(x: x, y: y + size - 68, width: size, height: 68))
            let label = NSAttributedString(string: "\(index + 1)", attributes: [
                .font: NSFont.boldSystemFont(ofSize: 48), .foregroundColor: NSColor.white,
            ])
            let line = CTLineCreateWithAttributedString(label)
            context.textPosition = CGPoint(x: x + 18, y: y + size - 52)
            CTLineDraw(line, context)
        }
        let output = NSMutableData()
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw StudioError.message("The mapping contact sheet could not be encoded.") }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination)
        else { throw StudioError.message("The mapping contact sheet could not be encoded.") }
        return .image(data: output as Data, mediaType: "image/jpeg")
    }
}

extension StudioAssistant {
    func proposeMappingSheet(
        images: [ProjectImage],
        references: [String: URL],
        concepts: [Concept]
    ) async throws -> [String: MappingSuggestion] {
        if demo {
            return Dictionary(uniqueKeysWithValues: images.map { ($0.id, MappingSuggestion(
                mapping: Job.Mapping(concepts.map { ($0.trigger, "the person in the demo photograph") }),
                description: "Prepared demo assignment"
            )) })
        }
        if images.count == 1, let image = images.first, Sources.isVideo(Sources.suffix(of: image.id)) {
            return try await [image.id: MappingSuggestion(
                mapping: proposeMapping(image: image.url, references: references, concepts: concepts),
                description: "Video target"
            )]
        }
        let stage = StructuredStage<MappingSheetDraft>(
            name: "mapping contact sheet",
            endpoint: endpoint,
            schemaName: "MappingSheetDraft",
            schema: MappingSheetDraft.schema
        )
        var content: [UserContent] =
            [.text("Concept definitions: " + JSONValue.array(concepts.map(\.jsonValue)).pythonDumps())]
        for (trigger, url) in references.sorted(by: { $0.key < $1.key }) {
            try content += [
                .text("Reference photo for \(trigger); this is NOT a numbered target tile:"),
                Self.thumbnail(url, maxPixels: MappingRequests.tilePixels),
            ]
        }
        try content += [
            .text(
                "Numbered target contact sheet: \(images.count) tiles. "
                    + "Each large number labels the photo directly BELOW it."
            ),
            MappingRequests.contactSheet(images),
        ]
        let expected = Set(1 ... images.count)
        let reply = try await stage.run(
            instructions: "Locate each configured concept separately in each numbered tile. "
                + "Use reference appearance for identity, never names or biography. "
                + "Return exactly one entry per numbered tile. Describe the visible scene in a few words "
                + "so the user can detect swapped tile answers. Locators describe position within that tile. "
                + "Omit absent or uncertain concepts from locators, but still return the tile and description. "
                + "Do not confuse the separate reference photos with target tiles.",
            messages: [.user(content)], validate: { output in
                output.tiles.count == expected
                    .count && Set(output.tiles.map(\.tile)) == expected ? [] :
                    ["Return each tile number exactly once: \(expected.sorted())"]
            }
        )
        let allowed = Set(concepts.map(\.trigger))
        return Dictionary(uniqueKeysWithValues: reply.output.tiles.map { tile in
            (
                images[tile.tile - 1].id,
                MappingSuggestion(
                    mapping: MappingDraft(locators: tile.locators).mapping(allowed: allowed),
                    description: tile.description
                )
            )
        })
    }

    /// A transient sheet failure retries each member independently, preserving successful siblings.
    func mappingResult(
        images: [ProjectImage],
        references: [String: URL],
        concepts: [Concept]
    ) async -> MappingBatchResult {
        do {
            return try await MappingBatchResult(suggestions: proposeMappingSheet(
                images: images,
                references: references,
                concepts: concepts
            ))
        } catch {
            guard MappingRequests.isTransient(error), !Task.isCancelled else {
                return MappingBatchResult(failures: images.map(\.id))
            }
        }
        var result = MappingBatchResult()
        for image in images {
            var saved = false
            for attempt in 1 ... 2 {
                do {
                    try await Task.sleep(for: .seconds(attempt))
                    let suggestion = try await proposeMappingSheet(
                        images: [image],
                        references: references,
                        concepts: concepts
                    )
                    result.suggestions.merge(suggestion) { _, new in new }
                    saved = true
                    break
                } catch { if !MappingRequests.isTransient(error) || Task.isCancelled { break } }
            }
            if !saved { result.failures.append(image.id) }
        }
        return result
    }
}
