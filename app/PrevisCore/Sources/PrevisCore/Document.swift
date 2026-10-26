import Foundation

// The document, CONTRACTS section 5.2. Every public struct has a public memberwise initialiser in property
// order: optionals default to nil, arrays and dictionaries to empty, everything else is required.

public typealias SceneID = String
public typealias ShotID = String
public typealias EntityID = String
public typealias MarkID = String
public typealias TakeID = String

public struct ShotsDocument: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    public var version: Int
    public var scenes: [PrevisScene]

    public init(version: Int, scenes: [PrevisScene] = []) {
        self.version = version
        self.scenes = scenes
    }
}

public struct PrevisScene: Codable, Sendable, Equatable, Identifiable {
    public var id: SceneID
    public var name: String
    public var revision: Int // bumped by the store on every edit except setPrompt
    public var lighting: LightingPreset
    public var entities: [PrevisEntity]
    public var blocking: [BlockingTake] // v1: exactly one take, shared by the scene's shots
    public var shots: [Shot]

    public init(
        id: SceneID,
        name: String,
        revision: Int,
        lighting: LightingPreset,
        entities: [PrevisEntity] = [],
        blocking: [BlockingTake] = [],
        shots: [Shot] = []
    ) {
        self.id = id
        self.name = name
        self.revision = revision
        self.lighting = lighting
        self.entities = entities
        self.blocking = blocking
        self.shots = shots
    }

    /// One take, "Master", and one shot, "1A".
    public static func make(
        id: SceneID,
        name: String,
        takeID: TakeID,
        shotID: ShotID,
        cameraMarkID: MarkID
    ) -> PrevisScene {
        PrevisScene(
            id: id,
            name: name,
            revision: 0,
            lighting: .day,
            blocking: [BlockingTake(id: takeID, name: "Master")],
            shots: [Shot.make(id: shotID, name: "1A", takeID: takeID, cameraMarkID: cameraMarkID)]
        )
    }
}

public enum LightingPreset: String, Codable, Sendable, CaseIterable {
    case day, goldenHour, night, interiorWarm, interiorCool
}

public struct PrevisEntity: Codable, Sendable, Equatable, Identifiable {
    public var id: EntityID
    public var assetID: String // fixed once placed
    public var name: String
    public var label: EntityLabel?
    public var placement: Placement // pose before the first mark, and always if there are none
    public var attachment: EntityAttachment? // rides the parent until its own first mark

    public init(
        id: EntityID,
        assetID: String,
        name: String,
        label: EntityLabel? = nil,
        placement: Placement,
        attachment: EntityAttachment? = nil
    ) {
        self.id = id
        self.assetID = assetID
        self.name = name
        self.label = label
        self.placement = placement
        self.attachment = attachment
    }
}

public struct Placement: Codable, Sendable, Equatable {
    public var position: Vec3
    public var heading: Double
    public var scale: Double // uniform; also scales gait stride

    public init(position: Vec3, heading: Double, scale: Double) {
        self.position = position
        self.heading = heading
        self.scale = scale
    }
}

public struct EntityLabel: Codable, Sendable, Equatable {
    public var text: String
    public var color: RGB

    public init(text: String, color: RGB) {
        self.text = text
        self.color = color
    }
}

public struct EntityAttachment: Codable, Sendable, Equatable {
    public var parentID: EntityID
    public var offset: Vec3 // in the parent's frame
    public var rotation: Quat // relative to the parent: a full transform, not yaw only

    public init(parentID: EntityID, offset: Vec3, rotation: Quat) {
        self.parentID = parentID
        self.offset = offset
        self.rotation = rotation
    }
}

public struct BlockingTake: Codable, Sendable, Equatable, Identifiable {
    public var id: TakeID
    public var name: String
    public var tracks: [Track]

    public init(id: TakeID, name: String, tracks: [Track] = []) {
        self.id = id
        self.name = name
        self.tracks = tracks
    }
}

public struct Track: Codable, Sendable, Equatable {
    public var entityID: EntityID
    public var marks: [ActorMark]

    public init(entityID: EntityID, marks: [ActorMark] = []) {
        self.entityID = entityID
        self.marks = marks
    }
}

public struct ActorMark: Codable, Sendable, Equatable, Identifiable {
    public var id: MarkID
    public var time: Double // seconds from the first frame
    public var hold: Double // seconds to stay before leaving for the next mark
    public var easeIn: Double, easeOut: Double
    public var position: Vec3
    public var via: [Vec3] // waypoints between the previous mark and this one
    public var gait: Gait
    public var arriveHeading: Double? // facing at this mark; nil = along travel
    public var joints: [Joint: Double] // pose overrides, radians; JSON object keyed by joint name
    public var boardID: EntityID? // from this mark on, ride that entity

    public init(
        id: MarkID,
        time: Double,
        hold: Double,
        easeIn: Double,
        easeOut: Double,
        position: Vec3,
        via: [Vec3] = [],
        gait: Gait,
        arriveHeading: Double? = nil,
        joints: [Joint: Double] = [:],
        boardID: EntityID? = nil
    ) {
        self.id = id
        self.time = time
        self.hold = hold
        self.easeIn = easeIn
        self.easeOut = easeOut
        self.position = position
        self.via = via
        self.gait = gait
        self.arriveHeading = arriveHeading
        self.joints = joints
        self.boardID = boardID
    }
}

public enum Gait: String, Codable, Sendable, CaseIterable {
    case stand, walk, jog, run, sit, lie, crouch, gesture, fall
}

public enum Joint: String, Codable, CodingKeyRepresentable, Sendable, CaseIterable {
    case shoulderLX, shoulderLZ, shoulderRX, shoulderRZ, elbowL, elbowR
    case hipLX, hipLZ, hipRX, hipRZ, kneeL, kneeR
    case torsoX, torsoY, torsoZ, headX, headY, headZ
}

public struct Shot: Codable, Sendable, Equatable, Identifiable {
    public var id: ShotID
    public var name: String
    public var frameCount: Int // on the grid
    public var canvas: ShotCanvas
    public var blockingTakeID: TakeID
    public var camera: ShotCamera
    public var guideFrames: [Int] // extra middle guides: sorted, unique, within 1...frameCount-2
    public var notes: ShotNotes
    public var prompt: ShotPrompt?
    public var results: [ShotResult] // reserved for later destinations; empty in v1
    public var duration: Double {
        Double(frameCount - 1) / Double(FrameGrid.fps)
    }

    public init(
        id: ShotID,
        name: String,
        frameCount: Int,
        canvas: ShotCanvas,
        blockingTakeID: TakeID,
        camera: ShotCamera,
        guideFrames: [Int] = [],
        notes: ShotNotes,
        prompt: ShotPrompt? = nil,
        results: [ShotResult] = []
    ) {
        self.id = id
        self.name = name
        self.frameCount = frameCount
        self.canvas = canvas
        self.blockingTakeID = blockingTakeID
        self.camera = camera
        self.guideFrames = guideFrames
        self.notes = notes
        self.prompt = prompt
        self.results = results
    }

    /// 124 frames, 640 × 1152, super35, sticks at intensity 0, seed 1, and one camera mark at (0, 1.6, 6) with a
    /// 35 mm lens.
    public static func make(id: ShotID, name: String, takeID: TakeID, cameraMarkID: MarkID) -> Shot {
        let mark = CameraMark(
            id: cameraMarkID,
            time: 0,
            hold: 0,
            easeIn: 0,
            easeOut: 0,
            position: Vec3(0, 1.6, 6),
            pan: 0,
            tilt: 0,
            roll: 0,
            focalLength: 35
        )
        return Shot(
            id: id,
            name: name,
            frameCount: FrameGrid.defaultFrameCount,
            canvas: .portrait,
            blockingTakeID: takeID,
            camera: ShotCamera(
                sensor: .super35,
                rig: .sticks,
                rigIntensity: 0,
                seed: 1,
                marks: [mark]
            ),
            notes: ShotNotes(description: "", sound: "", music: "")
        )
    }
}

public struct ShotCamera: Codable, Sendable, Equatable {
    public var sensor: Sensor
    public var rig: Rig
    public var rigIntensity: Double // 0...1
    public var seed: Double // rig-noise seed; Double for Blockout parity
    public var mountID: EntityID? // car mount: marks are relative to this entity
    public var trackIDs: [EntityID] // aim lock: none, one entity, or the midpoint of several
    public var marks: [CameraMark]

    public init(
        sensor: Sensor,
        rig: Rig,
        rigIntensity: Double,
        seed: Double,
        mountID: EntityID? = nil,
        trackIDs: [EntityID] = [],
        marks: [CameraMark] = []
    ) {
        self.sensor = sensor
        self.rig = rig
        self.rigIntensity = rigIntensity
        self.seed = seed
        self.mountID = mountID
        self.trackIDs = trackIDs
        self.marks = marks
    }
}

public enum Sensor: String, Codable, Sendable, CaseIterable {
    case super16, super35, fullFrame, imax65

    /// Gate width and height in millimetres.
    var gate: (width: Double, height: Double) {
        switch self {
        case .super16: (12.52, 7.41)
        case .super35: (24.89, 18.66)
        case .fullFrame: (36, 24)
        case .imax65: (52.63, 23.01)
        }
    }
}

public enum Rig: String, Codable, Sendable, CaseIterable {
    case sticks, dolly, steadicam, handheld, crane, drone, carMount
}

public struct CameraMark: Codable, Sendable, Equatable, Identifiable {
    public var id: MarkID
    public var time: Double, hold: Double, easeIn: Double, easeOut: Double
    public var position: Vec3
    public var via: [Vec3]
    public var pan: Double, tilt: Double, roll: Double
    public var focalLength: Double // millimetres
    public var focusDistance: Double? // metres; nil = deep focus

    public init(
        id: MarkID,
        time: Double,
        hold: Double,
        easeIn: Double,
        easeOut: Double,
        position: Vec3,
        via: [Vec3] = [],
        pan: Double,
        tilt: Double,
        roll: Double,
        focalLength: Double,
        focusDistance: Double? = nil
    ) {
        self.id = id
        self.time = time
        self.hold = hold
        self.easeIn = easeIn
        self.easeOut = easeOut
        self.position = position
        self.via = via
        self.pan = pan
        self.tilt = tilt
        self.roll = roll
        self.focalLength = focalLength
        self.focusDistance = focusDistance
    }
}

public struct ShotNotes: Codable, Sendable, Equatable { // v1 choice; may change after Phase 0
    public var description: String // setting and action in the user's words
    public var characters: [CharacterNote]
    public var sound: String
    public var music: String

    public init(description: String, characters: [CharacterNote] = [], sound: String, music: String) {
        self.description = description
        self.characters = characters
        self.sound = sound
        self.music = music
    }
}

public struct CharacterNote: Codable, Sendable, Equatable {
    public var entityID: EntityID
    public var appearance: String

    public init(entityID: EntityID, appearance: String) {
        self.entityID = entityID
        self.appearance = appearance
    }
}

public struct ShotPrompt: Codable, Sendable, Equatable {
    public var sections: [PromptSection] // in prompt order
    public var text: String // the full prompt, exactly as pasted into the graph
    public var sceneRevision: Int // revision it was written from; behind the scene = stale
    public var writtenBy: String // "template" or the model name

    public init(sections: [PromptSection] = [], text: String, sceneRevision: Int, writtenBy: String) {
        self.sections = sections
        self.text = text
        self.sceneRevision = sceneRevision
        self.writtenBy = writtenBy
    }
}

public struct PromptSection: Codable, Sendable, Equatable {
    public var key: String
    public var text: String

    public init(key: String, text: String) {
        self.key = key
        self.text = text
    }
}

public struct ShotResult: Codable, Sendable, Equatable, Identifiable {
    public var id: String, kind: String, path: String
    public var sceneRevision: Int

    public init(id: String, kind: String, path: String, sceneRevision: Int) {
        self.id = id
        self.kind = kind
        self.path = path
        self.sceneRevision = sceneRevision
    }
}
