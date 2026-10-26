import Foundation

// Problems, errors, validation, import, samples and attribution, CONTRACTS section 5.6.

public struct ShotsProblem: Sendable, Hashable {
    public enum Severity: Sendable, Hashable { case error, warning }
    public var severity: Severity
    public var message: String    // shown to the user as is
    public var sceneID: SceneID?, shotID: ShotID?, entityID: EntityID?, markID: MarkID?

    public init(
        severity: Severity,
        message: String,
        sceneID: SceneID? = nil,
        shotID: ShotID? = nil,
        entityID: EntityID? = nil,
        markID: MarkID? = nil
    ) {
        self.severity = severity
        self.message = message
        self.sceneID = sceneID
        self.shotID = shotID
        self.entityID = entityID
        self.markID = markID
    }
}

public enum ShotsError: Error, LocalizedError, Sendable {
    case invalid([ShotsProblem])
    case unknownContent(String)    // an asset, motion, move or path id
    case unsupportedVersion(Int)
    case importFailed(String)
    case notImplemented(String)    // skeleton placeholder

    public var errorDescription: String? {
        switch self {
        case .invalid(let problems):
            problems.map(\.message).joined(separator: " ")
        case .unknownContent(let message), .importFailed(let message):
            message
        case .unsupportedVersion(let version):
            "This Shots file is version \(version), newer than this app understands; update the app to open it."
        case .notImplemented(let what):
            "\(what) is not implemented yet."
        }
    }
}

public enum ShotsValidation {
    /// Skeleton: reports nothing until A5.
    public static func problems(in document: ShotsDocument, catalog: ContentCatalog) -> [ShotsProblem] { [] }
}

public enum BlockoutImport {    // notes: what was dropped or changed, in plain sentences
    public static func document(
        fromProjectJSON data: Data,
        catalog: ContentCatalog,
        keepIDs: Bool = false
    ) throws -> (document: ShotsDocument, notes: [String]) {
        throw ShotsError.notImplemented("BlockoutImport.document")
    }
}

public enum ShotsSamples {
    /// A man and a woman walk toward each other and turn, with a chair and a wall behind them; two camera marks
    /// make a push-in, and one middle guide. Fixed ids. Full: 124 frames, 640 × 1152, guide frame 61. Small: the
    /// same action in 22 frames at 320 × 576, guide frame 11.
    public static func twoPersonWalk(small: Bool = false) -> ShotsDocument {
        let frameCount = small ? 22 : 124
        let duration = Double(frameCount - 1) / Double(FrameGrid.fps)
        let meet = duration * 0.68
        let man = "ent_000000000001", woman = "ent_000000000002"
        let chair = "ent_000000000003", wall = "ent_000000000004"

        func mark(_ n: Int, _ time: Double, _ x: Double, _ gait: Gait, heading: Double? = nil) -> ActorMark {
            ActorMark(
                id: "mark_00000000000\(n)",
                time: time,
                hold: 0,
                easeIn: 0.2,
                easeOut: 0.2,
                position: Vec3(x, 0, 0),
                gait: gait,
                arriveHeading: heading
            )
        }

        var shot = Shot.make(
            id: "shot_000000000001",
            name: "1A",
            takeID: "take_000000000001",
            cameraMarkID: "cam_000000000001"
        )
        shot.frameCount = frameCount
        shot.canvas = small ? ShotCanvas(width: 320, height: 576) : .portrait
        shot.guideFrames = [frameCount / 2]
        shot.camera.marks = [
            CameraMark(
                id: "cam_000000000001",
                time: 0,
                hold: 0,
                easeIn: 0,
                easeOut: 0,
                position: Vec3(0, 1.6, 6),
                pan: 0,
                tilt: 0,
                roll: 0,
                focalLength: 20
            ),
            CameraMark(
                id: "cam_000000000002",
                time: duration,
                hold: 0,
                easeIn: 0,
                easeOut: 0,
                position: Vec3(0, 1.5, 4.5),
                pan: 0,
                tilt: 0,
                roll: 0,
                focalLength: 20
            ),
        ]
        shot.notes = ShotNotes(
            description: "Two people walk toward each other in a bare room and turn to face the camera.",
            sound: "Footsteps.",
            music: "None."
        )

        let scene = PrevisScene(
            id: "scene_000000000001",
            name: "Two-person walk",
            revision: 0,
            lighting: .day,
            entities: [
                PrevisEntity(
                    id: man,
                    assetID: "person.man",
                    name: "Man",
                    placement: Placement(position: Vec3(-1.3, 0, 0), heading: -.pi / 2, scale: 1)
                ),
                PrevisEntity(
                    id: woman,
                    assetID: "person.woman",
                    name: "Woman",
                    placement: Placement(position: Vec3(1.3, 0, 0), heading: .pi / 2, scale: 1)
                ),
                PrevisEntity(
                    id: chair,
                    assetID: "furniture.chair",
                    name: "Chair",
                    placement: Placement(position: Vec3(0.9, 0, -1), heading: 0, scale: 1)
                ),
                PrevisEntity(
                    id: wall,
                    assetID: "prim.wall",
                    name: "Wall",
                    placement: Placement(position: Vec3(0, 0, -2.5), heading: 0, scale: 1)
                ),
            ],
            blocking: [
                BlockingTake(
                    id: "take_000000000001",
                    name: "Master",
                    tracks: [
                        Track(
                            entityID: man,
                            marks: [
                                mark(1, 0, -1.3, .walk),
                                mark(2, meet, -0.35, .walk),
                                mark(3, duration, -0.35, .stand, heading: .pi),
                            ]
                        ),
                        Track(
                            entityID: woman,
                            marks: [
                                mark(4, 0, 1.3, .walk),
                                mark(5, meet, 0.35, .walk),
                                mark(6, duration, 0.35, .stand, heading: .pi),
                            ]
                        ),
                    ]
                ),
            ],
            shots: [shot]
        )
        return ShotsDocument(version: ShotsDocument.currentVersion, scenes: [scene])
    }

    /// A small Blockout-format project for import tests. Empty until A1.
    public static func blockoutProjectJSON() -> Data { Data() }
}

public enum PrevisCoreAttribution {    // the bundled Apache-2.0 texts, for the app's credits
    public static func notice() -> String { text("NOTICE") }
    public static func license() -> String { text("LICENSE") }

    private static func text(_ name: String) -> String {
        guard let data = try? ContentCatalog.resource(name) else {
            return "\(name) is missing from the PrevisCore bundle; rebuild the package."
        }
        return String(decoding: data, as: UTF8.self)
    }
}
