import Foundation

// MARK: - Blockout's file shape (only what is read)

/// Blockout's records are read like Shots' own documents (CONTRACTS section 4): unknown keys are ignored and an
/// absent field takes a default. The ids that tie records together (`id`, `assetId`, `entityId`) are required.
struct BlockoutProject: Decodable {
    var version: Int?
    var settings: Settings?
    var scenes: [Scene]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        version = try c.optional("version")
        settings = try c.optional("settings")
        scenes = try c.value("scenes", [])
    }

    struct Settings: Decodable {
        var defaultProfileId: String?

        init(from decoder: Decoder) throws {
            defaultProfileId = try decoder.container(keyedBy: AnyKey.self).optional("defaultProfileId")
        }
    }

    struct Vector: Decodable {
        var x: Double, y: Double, z: Double
        var vec: Vec3 {
            Vec3(x, y, z)
        }

        init() {
            (x, y, z) = (0, 0, 0)
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            (x, y, z) = try (c.value("x", 0), c.value("y", 0), c.value("z", 0))
        }
    }

    struct Label: Decodable {
        var text: String
        var color: String

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            text = try c.value("text", "")
            color = try c.value("color", "#000000")
        }
    }

    struct Transform: Decodable {
        var position: Vector
        var rotationY: Double
        var scale: Double

        init() {
            (position, rotationY, scale) = (Vector(), 0, 1)
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            position = try c.value("position", Vector())
            rotationY = try c.value("rotationY", 0)
            scale = try c.value("scale", 1)
        }
    }

    struct AttachedLocal: Decodable {
        var x: Double, y: Double, z: Double, rotY: Double

        init() {
            (x, y, z, rotY) = (0, 0, 0, 0)
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            (x, y, z, rotY) = try (c.value("x", 0), c.value("y", 0), c.value("z", 0), c.value("rotY", 0))
        }
    }

    /// A parameter that is a number in some files and a string in others; only numbers are used.
    struct Param: Decodable {
        var number: Double?
        init(from decoder: Decoder) throws {
            number = try? decoder.singleValueContainer().decode(Double.self)
        }
    }

    struct Entity: Decodable {
        var id: String
        var assetId: String
        var name: String
        var label: Label?
        var transform: Transform
        var params: [String: Param]?
        var attachedTo: String?
        var attachedLocal: AttachedLocal?
        var excludeFromExport: Bool?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            id = try c.require("id")
            assetId = try c.require("assetId")
            name = try c.value("name", "")
            label = try c.optional("label")
            transform = try c.value("transform", Transform())
            params = try c.optional("params")
            attachedTo = try c.optional("attachedTo")
            attachedLocal = try c.optional("attachedLocal")
            excludeFromExport = try c.optional("excludeFromExport")
        }
    }

    struct Mark: Decodable {
        var id: String
        var time: Double
        var hold: Double
        var easeIn: Double
        var easeOut: Double
        var position: Vector
        var via: [Vector]?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            id = try c.require("id")
            time = try c.value("time", 0)
            hold = try c.value("hold", 0)
            easeIn = try c.value("easeIn", 0)
            easeOut = try c.value("easeOut", 0)
            position = try c.value("position", Vector())
            via = try c.optional("via")
        }
    }

    struct ActorMark: Decodable {
        var base: Mark
        var gait: Gait
        var arriveHeading: Double?
        var joints: [String: Double]?
        var attachTo: String?

        init(from decoder: Decoder) throws {
            base = try Mark(from: decoder)
            let c = try decoder.container(keyedBy: AnyKey.self)
            gait = try c.value("gait", .stand)
            arriveHeading = try c.optional("arriveHeading")
            joints = try c.optional("joints")
            attachTo = try c.optional("attachTo")
        }
    }

    struct CameraMark: Decodable {
        var base: Mark
        var pan: Double, tilt: Double, roll: Double
        var focalLength: Double
        var focusDistance: Double?

        init(from decoder: Decoder) throws {
            base = try Mark(from: decoder)
            let c = try decoder.container(keyedBy: AnyKey.self)
            pan = try c.value("pan", 0)
            tilt = try c.value("tilt", 0)
            roll = try c.value("roll", 0)
            focalLength = try c.value("focalLength", 35)
            focusDistance = try c.optional("focusDistance")
        }
    }

    struct Track: Decodable {
        var entityId: String
        var marks: [ActorMark]

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            entityId = try c.require("entityId")
            marks = try c.value("marks", [])
        }
    }

    struct Take: Decodable {
        var id: String
        var name: String
        var tracks: [Track]

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            id = try c.require("id")
            name = try c.value("name", "")
            tracks = try c.value("tracks", [])
        }
    }

    struct Camera: Decodable {
        var sensorId: String
        var rig: String
        var rigIntensity: Double
        var seed: Double
        var mountEntityId: String?
        var trackEntityId: String?
        var marks: [CameraMark]

        init() {
            (sensorId, rig, rigIntensity, seed, marks) = ("super35", "sticks", 0, 1, [])
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            sensorId = try c.value("sensorId", "super35")
            rig = try c.value("rig", "sticks")
            rigIntensity = try c.value("rigIntensity", 0)
            seed = try c.value("seed", 1)
            mountEntityId = try c.optional("mountEntityId")
            trackEntityId = try c.optional("trackEntityId")
            marks = try c.value("marks", [])
        }
    }

    struct Shot: Decodable {
        var id: String
        var name: String
        var duration: Double? // absent: the default frame count
        var fps: Double?
        var aspect: String
        var blockingTakeId: String?
        var camera: Camera
        var cameraBank: [AnyDecodable]?
        var notes: String?
        var referenceVideo: AnyDecodable?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            id = try c.require("id")
            name = try c.value("name", "")
            duration = try c.optional("duration")
            fps = try c.optional("fps")
            aspect = try c.value("aspect", "9:16")
            blockingTakeId = try c.optional("blockingTakeId")
            camera = try c.value("camera", Camera())
            cameraBank = try c.optional("cameraBank")
            notes = try c.optional("notes")
            referenceVideo = try c.optional("referenceVideo")
        }
    }

    struct Environment: Decodable {
        var lighting: String
        var sunAzimuth: Double?
        var sunElevation: Double?
        var fog: Double?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            lighting = try c.value("lighting", "day")
            sunAzimuth = try c.optional("sunAzimuth")
            sunElevation = try c.optional("sunElevation")
            fog = try c.optional("fog")
        }
    }

    struct Scene: Decodable {
        var id: String
        var name: String
        var environment: Environment?
        var entities: [Entity]
        var scans: [AnyDecodable]?
        var blocking: [Take]
        var shots: [Shot]
        var drafts: [AnyDecodable]?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            id = try c.require("id")
            name = try c.value("name", "")
            environment = try c.optional("environment")
            entities = try c.value("entities", [])
            scans = try c.optional("scans")
            blocking = try c.value("blocking", [])
            shots = try c.value("shots", [])
            drafts = try c.optional("drafts")
        }
    }
}

/// Accepts and ignores any JSON value: for features that are counted but not read.
struct AnyDecodable: Decodable {
    init(from decoder: Decoder) throws {}
}
