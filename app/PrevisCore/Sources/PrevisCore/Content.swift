import Foundation

// Content, CONTRACTS section 5.3.

public struct ContentCatalog: Sendable {
    public let motions: [MotionPreset]
    public let assets: [AssetSpec] // environment kits are not loaded
    public let cameraMoves: [CatalogItem]
    public let actionPaths: [CatalogItem]
    public let starter: StarterSet

    private let assetsByID: [String: AssetSpec]
    private let motionsByID: [String: MotionPreset]

    init(
        motions: [MotionPreset],
        assets: [AssetSpec],
        cameraMoves: [CatalogItem],
        actionPaths: [CatalogItem],
        starter: StarterSet
    ) {
        self.motions = motions
        self.assets = assets
        self.cameraMoves = cameraMoves
        self.actionPaths = actionPaths
        self.starter = starter
        assetsByID = Dictionary(assets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        motionsByID = Dictionary(motions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Reads `Resources/*.v1.json`. Errors name the missing or unreadable file, or the starter id that does not
    /// resolve.
    public static func bundled() throws -> ContentCatalog {
        let starter: StarterSet = try load("starter.v1.json")
        let catalog = try ContentCatalog(
            motions: load("motions.v1.json", as: MotionsFile.self).motions,
            assets: load("assets.v1.json", as: AssetsFile.self).assets,
            cameraMoves: load("camera-moves.catalog.v1.json", as: MovesFile.self).moves,
            actionPaths: load("action-presets.catalog.v1.json", as: PathsFile.self).paths,
            starter: starter
        )
        try catalog.checkStarterResolves()
        return catalog
    }

    /// Every id the starter set names must exist, so a stale starter file fails here and not in a picker.
    private func checkStarterResolves() throws {
        let groups: [(kind: String, wanted: [String], known: Set<String>)] = [
            ("asset", starter.assets, Set(assets.map(\.id))),
            ("motion", starter.motions, Set(motions.map(\.id))),
            ("camera move", starter.cameraMoves, Set(cameraMoves.map(\.id))),
            ("action path", starter.actionPaths, Set(actionPaths.map(\.id))),
        ]
        for group in groups {
            if let missing = group.wanted.first(where: { !group.known.contains($0) }) {
                throw ShotsError.unknownContent(
                    "starter.v1.json names the \(group.kind) \"\(missing)\", which the bundled catalog does not have."
                )
            }
        }
    }

    private static func load<T: Decodable>(_ name: String, as type: T.Type = T.self) throws -> T {
        let data = try resource(name)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ShotsError.unknownContent("\(name) in the PrevisCore bundle is unreadable: \(error)")
        }
    }

    private struct MotionsFile: Decodable {
        var motions: [MotionPreset]
    }

    private struct MovesFile: Decodable {
        var moves: [CatalogItem]
    }

    private struct PathsFile: Decodable {
        var paths: [CatalogItem]
    }

    public func motion(_ id: String) -> MotionPreset? {
        motionsByID[id]
    }

    public func asset(_ id: String) -> AssetSpec? {
        assetsByID[id]
    }

    private struct AssetsFile: Decodable {
        var assets: [AssetSpec]
    }

    static func resource(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Resources") else {
            throw ShotsError.unknownContent("\(name) is missing from the PrevisCore bundle; rebuild the package.")
        }
        return try Data(contentsOf: url)
    }
}

public struct StarterSet: Codable, Sendable, Equatable {
    public var assets: [String], motions: [String], cameraMoves: [String], actionPaths: [String]

    public init(assets: [String], motions: [String], cameraMoves: [String], actionPaths: [String]) {
        self.assets = assets
        self.motions = motions
        self.cameraMoves = cameraMoves
        self.actionPaths = actionPaths
    }
}

public struct CatalogItem: Codable, Sendable, Equatable, Identifiable {
    public var id: String, name: String, category: String, description: String
    public var track: Bool? // camera moves: aim-locks the subject

    public init(id: String, name: String, category: String, description: String, track: Bool? = nil) {
        self.id = id
        self.name = name
        self.category = category
        self.description = description
        self.track = track
    }
}

public struct MotionPreset: Codable, Sendable, Equatable, Identifiable {
    public var id: String, name: String, category: String
    public var duration: Double
    public var loop: Bool
    public var keyframes: [MotionKeyframe]

    /// Touches no hip or knee joint.
    public var upperBodyOnly: Bool {
        let lower: Set<Joint> = [.hipLX, .hipLZ, .hipRX, .hipRZ, .kneeL, .kneeR]
        return !keyframes.contains { !lower.isDisjoint(with: $0.joints.keys) }
    }

    public init(
        id: String,
        name: String,
        category: String,
        duration: Double,
        loop: Bool,
        keyframes: [MotionKeyframe] = []
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.duration = duration
        self.loop = loop
        self.keyframes = keyframes
    }
}

public struct MotionKeyframe: Codable, Sendable, Equatable {
    public var t: Double
    public var joints: [Joint: Double]
    public var move: RootMove?

    public init(t: Double, joints: [Joint: Double] = [:], move: RootMove? = nil) {
        self.t = t
        self.joints = joints
        self.move = move
    }
}

public struct RootMove: Codable, Sendable, Equatable {
    public var forward: Double // 0 when absent in the data
    public var up: Double // 0 when absent in the data

    public init(forward: Double, up: Double) {
        self.forward = forward
        self.up = up
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        forward = try container.decodeIfPresent(Double.self, forKey: .forward) ?? 0
        up = try container.decodeIfPresent(Double.self, forKey: .up) ?? 0
    }
}

public struct AssetSpec: Codable, Sendable, Equatable, Identifiable {
    public var id: String, name: String, category: String
    public var height: Double // metres at scale 1
    public var footprint: Double // metres, largest horizontal extent
    public var speedScale: Double
    public var motion: String // biped, quadruped, wheeled, rail, flying, static
    public var promptNoun: String
    public var parts: [PartSpec]? // from parts.v1.json; nil = generic box

    /// person for biped, quadruped for quadruped, bird for animal.bird, else none.
    public var rig: AssetRig {
        if id == "animal.bird" { return .bird }
        switch motion {
        case "biped": return .person
        case "quadruped": return .quadruped
        default: return .none
        }
    }

    public init(
        id: String,
        name: String,
        category: String,
        height: Double,
        footprint: Double,
        speedScale: Double,
        motion: String,
        promptNoun: String,
        parts: [PartSpec]? = nil
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.height = height
        self.footprint = footprint
        self.speedScale = speedScale
        self.motion = motion
        self.promptNoun = promptNoun
        self.parts = parts
    }
}

public enum AssetRig: String, Sendable { case none, person, quadruped, bird }

public struct PartSpec: Codable, Sendable, Equatable {
    public var id: String
    public var shape: PartShape
    public var position: Vec3 // asset frame, origin on the ground
    public var rotation: Vec3 // Euler XYZ, radians
    public var color: RGB

    public init(id: String, shape: PartShape, position: Vec3, rotation: Vec3, color: RGB) {
        self.id = id
        self.shape = shape
        self.position = position
        self.rotation = rotation
        self.color = color
    }
}

public enum PartShape: Codable, Hashable, Sendable { // centred on the local origin, axis +Y
    case box(size: Vec3)
    case cylinder(radius: Double, height: Double)
    case sphere(radius: Double)
    case capsule(radius: Double, length: Double) // straight part; total height length + 2·radius
    case cone(radius: Double, height: Double)
    case wedge(size: Vec3) // ramp rising toward −Z
}
