import PrevisCore

/// `manifest.json` of a shot package: every file named by the role it plays in an H3 shot.
public struct PackageManifest: Codable, Sendable, Equatable {
    public static let formatName = "conceptstudio.shot-package"
    public static let currentFormatVersion = 1

    public var format: String
    public var formatVersion: Int
    public var createdBy: String
    public var shot: ShotRef
    public var frameRate: Int
    public var frameCount: Int
    public var canvas: ShotCanvas
    public var passes: [PassKind]
    public var files: [PackageFile]

    public init(
        format: String,
        formatVersion: Int,
        createdBy: String,
        shot: ShotRef,
        frameRate: Int,
        frameCount: Int,
        canvas: ShotCanvas,
        passes: [PassKind] = [],
        files: [PackageFile] = []
    ) {
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
        case guide, control, matte, reference, prompt, description
        case promptSections = "prompt-sections"
    }

    public enum Position: String, Codable, Sendable { case first, middle, last }
    public enum Variant: String, Codable, Sendable { case clean, pose, layout, depth } // depth reserved

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
