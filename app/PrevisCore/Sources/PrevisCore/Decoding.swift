import Foundation

// Tolerant readers (CONTRACTS section 4): unknown keys are ignored and absent fields take a default.
//
// Identity fields (`id`, `assetID`, `entityID`, `parentID`) are the exception: a missing one is an error that
// names it, because a default would make two different things look the same. Everything else defaults to what
// the factories use (`Shot.make`, `Placement` scale 1, an empty collection, zero). Encoding is synthesised and
// writes every field.

struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? {
        nil
    }

    init(_ name: String) {
        stringValue = name
    }

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        nil
    }
}

extension KeyedDecodingContainer where K == AnyKey {
    func require<T: Decodable>(_ name: String) throws -> T {
        try decode(T.self, forKey: AnyKey(name))
    }

    func optional<T: Decodable>(_ name: String) throws -> T? {
        try decodeIfPresent(T.self, forKey: AnyKey(name))
    }

    func value<T: Decodable>(_ name: String, _ fallback: @autoclosure () -> T) throws -> T {
        try decodeIfPresent(T.self, forKey: AnyKey(name)) ?? fallback()
    }

    /// Pose overrides keyed by joint name. A name this reader does not know is skipped, not an error.
    func joints(_ name: String) throws -> [Joint: Double] {
        let raw = try decodeIfPresent([String: Double].self, forKey: AnyKey(name)) ?? [:]
        return Dictionary(uniqueKeysWithValues: raw.compactMap { key, value in
            Joint(rawValue: key).map { ($0, value) }
        })
    }
}

public extension Vec3 {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        try self.init(c.value("x", 0), c.value("y", 0), c.value("z", 0))
    }
}

public extension Point2 {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        try self.init(x: c.value("x", 0), y: c.value("y", 0))
    }
}

public extension Quat {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        try self.init(x: c.value("x", 0), y: c.value("y", 0), z: c.value("z", 0), w: c.value("w", 1))
    }
}

public extension ShotCanvas {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        try self.init(width: c.value("width", Self.portrait.width), height: c.value("height", Self.portrait.height))
    }
}

public extension ShotsDocument {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        try self.init(version: c.value("version", Self.currentVersion), scenes: c.value("scenes", []))
    }
}

public extension PrevisScene {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        try self.init(
            id: c.require("id"),
            name: c.value("name", ""),
            revision: c.value("revision", 0),
            lighting: c.value("lighting", .day),
            entities: c.value("entities", []),
            blocking: c.value("blocking", []),
            shots: c.value("shots", [])
        )
    }
}

public extension PrevisEntity {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        try self.init(
            id: c.require("id"),
            assetID: c.require("assetID"),
            name: c.value("name", ""),
            label: c.optional("label"),
            placement: c.value("placement", Placement(position: .zero, heading: 0, scale: 1)),
            attachment: c.optional("attachment")
        )
    }
}

public extension Placement {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        try self.init(position: c.value("position", .zero), heading: c.value("heading", 0), scale: c.value("scale", 1))
    }
}

public extension EntityLabel {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        try self.init(text: c.value("text", ""), color: c.value("color", RGB(r: 0, g: 0, b: 0)))
    }
}

public extension EntityAttachment {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        try self.init(
            parentID: c.require("parentID"),
            offset: c.value("offset", .zero),
            rotation: c.value("rotation", .identity)
        )
    }
}

public extension BlockingTake {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        try self.init(id: c.require("id"), name: c.value("name", ""), tracks: c.value("tracks", []))
    }
}

public extension Track {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        try self.init(entityID: c.require("entityID"), marks: c.value("marks", []))
    }
}

public extension ActorMark {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        try self.init(
            id: c.require("id"),
            time: c.value("time", 0),
            hold: c.value("hold", 0),
            easeIn: c.value("easeIn", 0),
            easeOut: c.value("easeOut", 0),
            position: c.value("position", .zero),
            via: c.value("via", []),
            gait: c.value("gait", .stand),
            arriveHeading: c.optional("arriveHeading"),
            joints: c.joints("joints"),
            boardID: c.optional("boardID")
        )
    }
}

public extension Shot {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        try self.init(
            id: c.require("id"),
            name: c.value("name", ""),
            frameCount: c.value("frameCount", FrameGrid.defaultFrameCount),
            canvas: c.value("canvas", .portrait),
            blockingTakeID: c.value("blockingTakeID", ""),
            camera: c.value("camera", ShotCamera(sensor: .super35, rig: .sticks, rigIntensity: 0, seed: 1)),
            guideFrames: c.value("guideFrames", []),
            notes: c.value("notes", ShotNotes(description: "", sound: "", music: "")),
            prompt: c.optional("prompt"),
            results: c.value("results", [])
        )
    }
}

public extension ShotCamera {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        try self.init(
            sensor: c.value("sensor", .super35),
            rig: c.value("rig", .sticks),
            rigIntensity: c.value("rigIntensity", 0),
            seed: c.value("seed", 1),
            mountID: c.optional("mountID"),
            trackIDs: c.value("trackIDs", []),
            marks: c.value("marks", [])
        )
    }
}

public extension CameraMark {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        try self.init(
            id: c.require("id"),
            time: c.value("time", 0),
            hold: c.value("hold", 0),
            easeIn: c.value("easeIn", 0),
            easeOut: c.value("easeOut", 0),
            position: c.value("position", Vec3(0, 1.6, 6)),
            via: c.value("via", []),
            pan: c.value("pan", 0),
            tilt: c.value("tilt", 0),
            roll: c.value("roll", 0),
            focalLength: c.value("focalLength", 35),
            focusDistance: c.optional("focusDistance")
        )
    }
}

public extension ShotNotes {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        try self.init(
            description: c.value("description", ""),
            characters: c.value("characters", []),
            sound: c.value("sound", ""),
            music: c.value("music", "")
        )
    }
}

public extension CharacterNote {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        try self.init(entityID: c.require("entityID"), appearance: c.value("appearance", ""))
    }
}

public extension ShotPrompt {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        try self.init(
            sections: c.value("sections", []),
            text: c.value("text", ""),
            sceneRevision: c.value("sceneRevision", 0),
            writtenBy: c.value("writtenBy", "")
        )
    }
}

public extension PromptSection {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        try self.init(key: c.value("key", ""), text: c.value("text", ""))
    }
}

public extension ShotResult {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        try self.init(
            id: c.require("id"),
            kind: c.value("kind", ""),
            path: c.value("path", ""),
            sceneRevision: c.value("sceneRevision", 0)
        )
    }
}
