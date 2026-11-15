import PrevisCore

/// `manifest.json` of a shot package: every file named by the role it plays in an H3 shot.
public struct PackageManifest: Codable, Sendable, Equatable {
    public static let formatName = "conceptstudio.shot-package"
    /// 2 added the composition guides, the staging files, `keyCanvas` and `plate`. A version 1 package is still valid.
    public static let currentFormatVersion = 2
    public static let supportedFormatVersions = 1 ... 2

    public var format: String
    public var formatVersion: Int
    public var createdBy: String
    public var shot: ShotRef
    public var frameRate: Int
    public var frameCount: Int
    public var canvas: ShotCanvas
    public var passes: [PassKind]
    public var files: [PackageFile]
    public var keyCanvas: ShotCanvas? // the size of the composition guides: the key the image model makes
    public var plate: PlateRef? // the plate the shot is blocked over

    public init(
        format: String,
        formatVersion: Int,
        createdBy: String,
        shot: ShotRef,
        frameRate: Int,
        frameCount: Int,
        canvas: ShotCanvas,
        passes: [PassKind] = [],
        files: [PackageFile] = [],
        keyCanvas: ShotCanvas? = nil,
        plate: PlateRef? = nil
    ) {
        self.keyCanvas = keyCanvas
        self.plate = plate
        self.format = format
        self.formatVersion = formatVersion
        self.createdBy = createdBy
        self.shot = shot
        self.frameRate = frameRate
        self.frameCount = frameCount
        self.canvas = canvas
        self.passes = passes
        self.files = files
    }
}

public struct PlateRef: Codable, Sendable, Equatable {
    public var id: PlateID, name: String, file: String
    public var size: PixelSize

    public init(id: PlateID, name: String, file: String, size: PixelSize) {
        self.id = id
        self.name = name
        self.file = file
        self.size = size
    }
}

public struct ShotRef: Codable, Sendable, Equatable {
    public var id: ShotID, name: String, sceneID: SceneID
    public var sceneRevision: Int

    public init(id: ShotID, name: String, sceneID: SceneID, sceneRevision: Int) {
        self.id = id
        self.name = name
        self.sceneID = sceneID
        self.sceneRevision = sceneRevision
    }
}

public struct PackageFile: Codable, Sendable, Equatable {
    public enum Role: String, Codable, Sendable {
        case guide, control, matte, reference, prompt, description, staging
        case promptSections = "prompt-sections"
        case stagingData = "staging-data"
    }

    public enum Position: String, Codable, Sendable { case first, middle, last }
    public enum Variant: String, Codable, Sendable {
        case clean, pose, layout, depth // depth reserved
        case composition // the plate with stand-ins, at the key's size, for the image model
        case compositionLabelled = "composition-labelled" // the same with name tags, for people

        /// Composition guides are the key's size; every other still is the canvas's.
        public var isKeySized: Bool {
            self == .composition || self == .compositionLabelled
        }
    }

    public var role: Role
    public var path: String // relative, "/" separators
    public var position: Position?
    public var variant: Variant?
    public var frame: Int?
    public var frameCount: Int?
    public var entityID: EntityID?
    public var entityName: String?

    public init(
        role: Role,
        path: String,
        position: Position? = nil,
        variant: Variant? = nil,
        frame: Int? = nil,
        frameCount: Int? = nil,
        entityID: EntityID? = nil,
        entityName: String? = nil
    ) {
        self.role = role
        self.path = path
        self.position = position
        self.variant = variant
        self.frame = frame
        self.frameCount = frameCount
        self.entityID = entityID
        self.entityName = entityName
    }
}
