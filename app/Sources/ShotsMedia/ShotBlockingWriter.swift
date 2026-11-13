import ConceptCore
import Foundation
import PrevisCore

/// Reads a shot's written description into a blocking brief with a language model, under the bundled
/// `shot-blocking-brief` skill. `BlockingReader` is the offline reader of the same thing.
public enum ShotBlockingWriter {
    public static func read(
        _ text: String,
        scene: PrevisScene,
        endpoint: ResolvedEndpoint
    ) async throws -> BlockingBrief {
        guard let directory = Bundle.module.url(
            forResource: "shot-blocking-brief", withExtension: nil, subdirectory: "Resources/Skills"
        ) else { throw ShotsMediaError("The bundled shot-blocking-brief skill is missing from this build.") }
        let facts = SceneNames(
            characters: scene.entities.filter { $0.setPiece == nil }.map(\.name),
            setPieces: scene.entities.filter { $0.setPiece != nil }.map(\.name),
            plates: scene.plates.map(\.name)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let factsJSON = try String(bytes: encoder.encode(facts), encoding: .utf8) else {
            throw ShotsMediaError("The scene's names couldn't be written as JSON.")
        }
        let stage = StructuredStage<BlockingBrief>(
            name: "blocking brief", endpoint: endpoint, schemaName: "BlockingBrief", schema: schema
        )
        let pieces = Set(facts.setPieces)
        let run = try await stage.run(
            instructions: Skills.load(directory).instructions(),
            messages: [.user("The description:\n\n\(text)\n\nThe scene's facts:\n\n\(factsJSON)")],
            validate: { brief in problems(in: brief, setPieces: pieces) }
        )
        return run.output
    }

    /// What a brief gets wrong that the solver can't place: nobody in it, half a placement, or a set piece the
    /// scene doesn't have.
    static func problems(in brief: BlockingBrief, setPieces: Set<String>) -> [String] {
        var out: [String] = []
        if brief.characters.isEmpty { out.append("characters is empty; list each character the description frames.") }
        for character in brief.characters {
            if character.name.trimmingCharacters(in: .whitespaces).isEmpty {
                out.append("A character has no name.")
            }
            if (character.relation == nil) != (character.piece == nil) {
                out.append("\(character.name): give relation and piece together, or neither.")
            }
            if let piece = character.piece, !setPieces.contains(piece) {
                out
                    .append(
                        "\(character.name): \"\(piece)\" is not one of setPieces; use a listed name or leave both out."
                    )
            }
            if let x = character.frameX, !(0 ... 1).contains(x) {
                out.append("\(character.name): frameX is \(x); it runs from 0 to 1.")
            }
        }
        return out
    }

    private struct SceneNames: Encodable {
        var characters: [String], setPieces: [String], plates: [String]
    }

    static let schema: JSONValue = .object([
        "type": .string("object"),
        "title": .string("BlockingBrief"),
        "properties": .object([
            "shot": .object(["type": .string("string"), "description": .string("The shot's code or name.")]),
            "plate": .object(["type": .string("string"), "description": .string("A plate of the scene, by name.")]),
            "characters": .object([
                "type": .string("array"),
                "items": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "name": .object(["type": .string("string")]),
                        "asset": .object(["type": .string("string")]),
                        "frameX": .object([
                            "type": .string("number"),
                            "description": .string("0 at the frame's left edge to 1 at its right."),
                        ]),
                        "show": .object([
                            "type": .string("string"),
                            "enum": .array(BodyExtent.allCases.map { .string($0.rawValue) }),
                        ]),
                        "relation": .object([
                            "type": .string("string"),
                            "enum": .array([.string("on"), .string("behind"), .string("inFrontOf")]),
                        ]),
                        "piece": .object(["type": .string("string")]),
                        "facing": .object([
                            "type": .string("string"),
                            "description": .string("camera, away, frameLeft, frameRight or toward:<name>."),
                        ]),
                    ]),
                    "required": .array([.string("name")]),
                    "additionalProperties": .bool(false),
                ]),
            ]),
        ]),
        "required": .array([.string("shot"), .string("characters")]),
        "additionalProperties": .bool(false),
    ])
}
