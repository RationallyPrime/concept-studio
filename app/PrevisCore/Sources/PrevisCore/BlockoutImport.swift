import Foundation

// A one-way importer for Blockout project files (https://github.com/wassermanproductions/blockout, the
// ProjectDoc in src/engine/types.ts at 3f2d0564). What Shots has no place for is dropped, and each kind of
// drop is reported once in the notes.

public enum BlockoutImport { // notes: what was dropped or changed, in plain sentences
    public static func document(
        fromProjectJSON data: Data,
        catalog: ContentCatalog,
        keepIDs: Bool = false
    ) throws -> (document: ShotsDocument, notes: [String]) {
        let project: BlockoutProject
        do {
            project = try JSONDecoder().decode(BlockoutProject.self, from: data)
        } catch {
            throw ShotsError.importFailed("This is not a Blockout project file the importer can read: \(error)")
        }
        if let version = project.version, version != 1 {
            throw ShotsError
                .importFailed("Blockout project version \(version) is not supported; the importer reads version 1.")
        }
        var converter = Converter(catalog: catalog, keepIDs: keepIDs)
        if project.settings?.defaultProfileId != nil { converter.drop(.profiles) }
        let scenes = project.scenes.map { converter.scene($0) }
        return (ShotsDocument(version: ShotsDocument.currentVersion, scenes: scenes), converter.notes)
    }
}

// MARK: - Blockout's file shape (only what is read)

struct BlockoutProject: Decodable {
    var version: Int?
    var settings: Settings?
    var scenes: [Scene] = []

    struct Settings: Decodable {
        var defaultProfileId: String?
    }

    struct Vector: Decodable {
        var x = 0.0, y = 0.0, z = 0.0
        var vec: Vec3 {
            Vec3(x, y, z)
        }
    }

    struct Label: Decodable {
        var text = ""
        var color = "#000000"
    }

    struct Transform: Decodable {
        var position = Vector()
        var rotationY = 0.0
        var scale = 1.0
    }

    struct AttachedLocal: Decodable {
        var x = 0.0, y = 0.0, z = 0.0, rotY = 0.0
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
        var name = ""
        var label: Label?
        var transform = Transform()
        var params: [String: Param]?
        var attachedTo: String?
        var attachedLocal: AttachedLocal?
        var excludeFromExport: Bool?
    }

    struct Mark: Decodable {
        var id: String
        var time = 0.0
        var hold = 0.0
        var easeIn = 0.0
        var easeOut = 0.0
        var position = Vector()
        var via: [Vector]?
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
        var pan = 0.0, tilt = 0.0, roll = 0.0
        var focalLength = 35.0
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
        var marks: [ActorMark] = []
    }

    struct Take: Decodable {
        var id: String
        var name = ""
        var tracks: [Track] = []
    }

    struct Camera: Decodable {
        var sensorId = "super35"
        var rig = "sticks"
        var rigIntensity = 0.0
        var seed = 1.0
        var mountEntityId: String?
        var trackEntityId: String?
        var marks: [CameraMark] = []
    }

    struct Shot: Decodable {
        var id: String
        var name = ""
        var duration = 5.0
        var fps: Double?
        var aspect = "9:16"
        var blockingTakeId: String?
        var camera = Camera()
        var cameraBank: [AnyDecodable]?
        var notes: String?
        var referenceVideo: AnyDecodable?
    }

    struct Environment: Decodable {
        var lighting = "day"
        var sunAzimuth: Double?
        var sunElevation: Double?
        var fog: Double?
    }

    struct Scene: Decodable {
        var id: String
        var name = ""
        var environment: Environment?
        var entities: [Entity] = []
        var scans: [AnyDecodable]?
        var blocking: [Take] = []
        var shots: [Shot] = []
        var drafts: [AnyDecodable]?
    }
}

/// Accepts and ignores any JSON value: for features that are counted but not read.
struct AnyDecodable: Decodable {
    init(from decoder: Decoder) throws {}
}

// MARK: - Conversion

private struct Converter {
    let catalog: ContentCatalog
    let keepIDs: Bool
    private var counts: [Dropped: Int] = [:]
    private var details: [String] = []

    /// Features Shots has no place for, in the order they are reported.
    enum Dropped: Int, CaseIterable {
        case drafts, cameraBanks, scans, referenceVideos, environment, profiles, exportExclusions

        var phrase: String {
            switch self {
            case .drafts: "draft shot versions"
            case .cameraBanks: "alternate cameras"
            case .scans: "location scans"
            case .referenceVideos: "reference videos"
            case .environment: "sun direction and fog settings"
            case .profiles: "the generator profile setting"
            case .exportExclusions: "per-entity export exclusions"
            }
        }
    }

    init(catalog: ContentCatalog, keepIDs: Bool) {
        self.catalog = catalog
        self.keepIDs = keepIDs
    }

    mutating func drop(_ feature: Dropped, count: Int = 1) {
        counts[feature, default: 0] += count
    }

    var notes: [String] {
        let dropped = Dropped.allCases.compactMap { feature -> String? in
            guard let count = counts[feature], count > 0 else { return nil }
            return "Dropped \(count) of \(feature.phrase): Shots has no place for them."
        }
        return details + dropped
    }

    // MARK: Scene

    mutating func scene(_ source: BlockoutProject.Scene) -> PrevisScene {
        var ids = IDs(keep: keepIDs)
        drop(.drafts, count: source.drafts?.count ?? 0)
        drop(.scans, count: source.scans?.count ?? 0)
        if let env = source.environment, env.sunAzimuth != nil || env.sunElevation != nil || env.fog != nil {
            drop(.environment)
        }

        let entities = importedEntities(source, ids: &ids)
        let kept = Set(entities.map(\.id))
        let take = chosenTake(source, ids: &ids, keptEntities: kept)

        let shots = source.shots.map { shot($0, takeID: take.id, ids: &ids, kept: kept) }
        return PrevisScene(
            id: ids.make(source.id, "scene"),
            name: source.name,
            revision: 0,
            lighting: lighting(source.environment?.lighting, scene: source.name),
            entities: entities.map(\.entity),
            blocking: [take.take],
            shots: shots
        )
    }

    /// Sky presets and `club` have no Shots counterpart; each maps to the nearest of the five.
    private mutating func lighting(_ id: String?, scene: String) -> LightingPreset {
        guard let id else { return .day }
        if let direct = LightingPreset(rawValue: id) { return direct }
        let nearest: LightingPreset = switch id {
        case "middaySky": .day
        case "goldenHourSky": .goldenHour
        case "blueHourSky": .night
        default: .interiorCool // club
        }
        details
            .append(
                "Scene \"\(scene)\" lights with \"\(id)\", which Shots does not have; it became \(nearest.rawValue)."
            )
        return nearest
    }

    // MARK: Entities

    private struct ImportedEntity {
        var entity: PrevisEntity
        var id: EntityID {
            entity.id
        }
    }

    /// Entities whose asset the catalog has, with references to dropped ones cleared.
    private mutating func importedEntities(
        _ source: BlockoutProject.Scene,
        ids: inout IDs
    ) -> [ImportedEntity] {
        let known = source.entities.filter { catalog.asset($0.assetId) != nil }
        let unknown = source.entities.filter { catalog.asset($0.assetId) == nil }
        if !unknown.isEmpty {
            let assets = Set(unknown.map(\.assetId)).sorted().joined(separator: ", ")
            details.append(
                "Dropped \(unknown.count) entities whose assets Shots does not have (\(assets)), with their marks."
            )
        }
        let keptIDs = Set(known.map(\.id))
        return known.map { source in
            let asset = catalog.asset(source.assetId)
            let height = asset?.rig == .person ? (source.params?["height"]?.number).map { min(1.2, max(0.8, $0)) } : nil
            var attachment: EntityAttachment?
            if let parent = source.attachedTo, keptIDs.contains(parent) {
                let local = source.attachedLocal ?? .init()
                attachment = EntityAttachment(
                    parentID: ids.make(parent, "ent"),
                    offset: Vec3(local.x, local.y, local.z),
                    rotation: .yaw(local.rotY)
                )
            }
            if source.excludeFromExport == true { drop(.exportExclusions) }
            return ImportedEntity(
                entity: PrevisEntity(
                    id: ids.make(source.id, "ent"),
                    assetID: source.assetId,
                    name: source.name,
                    label: source.label.map { EntityLabel(text: $0.text, color: RGB(hex: $0.color)) },
                    placement: Placement(
                        position: source.transform.position.vec,
                        heading: source.transform.rotationY,
                        scale: source.transform.scale * (height ?? 1)
                    ),
                    attachment: attachment
                )
            )
        }
    }

    // MARK: Blocking

    /// Shots v1 keeps one take per scene: the first one a shot uses, else the first one.
    private mutating func chosenTake(
        _ source: BlockoutProject.Scene,
        ids: inout IDs,
        keptEntities: Set<EntityID>
    ) -> (id: TakeID, take: BlockingTake) {
        let wanted = source.shots.compactMap(\.blockingTakeId).first
        let chosen = source.blocking.first { $0.id == wanted } ?? source.blocking.first
        if source.blocking.count > 1 {
            details.append(
                "Scene \"\(source.name)\" has \(source.blocking.count) blocking takes; Shots keeps one, "
                    + "\"\(chosen?.name ?? "")\", and every shot uses it."
            )
        }
        let takeID = ids.make(chosen?.id ?? "take", "take")
        let tracks = (chosen?.tracks ?? []).compactMap { track -> Track? in
            let entityID = ids.make(track.entityId, "ent")
            guard keptEntities.contains(entityID) else { return nil }
            return Track(entityID: entityID, marks: track.marks.map { actorMark($0, ids: &ids, kept: keptEntities) })
        }
        return (takeID, BlockingTake(id: takeID, name: chosen?.name ?? "Master", tracks: tracks))
    }

    private func actorMark(_ mark: BlockoutProject.ActorMark, ids: inout IDs, kept: Set<EntityID>) -> ActorMark {
        let joints = (mark.joints ?? [:]).compactMap { name, value in Joint(rawValue: name).map { ($0, value) } }
        let boarded = mark.attachTo.map { ids.make($0, "ent") }
        return ActorMark(
            id: ids.make(mark.base.id, "mark"),
            time: mark.base.time,
            hold: mark.base.hold,
            easeIn: mark.base.easeIn,
            easeOut: mark.base.easeOut,
            position: mark.base.position.vec,
            via: (mark.base.via ?? []).map(\.vec),
            gait: mark.gait,
            arriveHeading: mark.arriveHeading,
            joints: Dictionary(uniqueKeysWithValues: joints),
            boardID: boarded.flatMap { kept.contains($0) ? $0 : nil }
        )
    }

    // MARK: Shots

    private mutating func shot(
        _ source: BlockoutProject.Shot,
        takeID: TakeID,
        ids: inout IDs,
        kept: Set<EntityID>
    ) -> Shot {
        drop(.cameraBanks, count: source.cameraBank?.count ?? 0)
        if source.referenceVideo != nil { drop(.referenceVideos) }
        if let fps = source.fps, fps != Double(FrameGrid.fps) {
            details.append("Shot \"\(source.name)\" runs at \(fps) fps in Blockout; Shots always runs at 24 fps.")
        }
        let camera = source.camera
        let sensor = Sensor(rawValue: camera.sensorId) ?? .super35
        let rig = Rig(rawValue: camera.rig) ?? .sticks
        if Sensor(rawValue: camera.sensorId) == nil || Rig(rawValue: camera.rig) == nil {
            details
                .append("Shot \"\(source.name)\" uses a sensor or rig Shots does not have; it became super35/sticks.")
        }
        let tracked = camera.trackEntityId.map { ids.make($0, "ent") }.flatMap { kept.contains($0) ? $0 : nil }
        let mount = camera.mountEntityId.map { ids.make($0, "ent") }.flatMap { kept.contains($0) ? $0 : nil }
        return Shot(
            id: ids.make(source.id, "shot"),
            name: source.name,
            frameCount: FrameGrid.snapUp(Int((source.duration * Double(FrameGrid.fps)).rounded()) + 1),
            canvas: canvas(aspect: source.aspect, shot: source.name),
            blockingTakeID: takeID,
            camera: ShotCamera(
                sensor: sensor,
                rig: rig,
                rigIntensity: camera.rigIntensity,
                seed: camera.seed,
                mountID: mount,
                trackIDs: tracked.map { [$0] } ?? [],
                marks: camera.marks.map { cameraMark($0, ids: &ids) }
            ),
            notes: ShotNotes(description: source.notes ?? "", sound: "", music: "")
        )
    }

    private mutating func canvas(aspect: String, shot: String) -> ShotCanvas {
        switch aspect {
        case "9:16": return ShotCanvas(width: 640, height: 1152)
        case "16:9": return ShotCanvas(width: 1152, height: 640)
        case "1:1": return ShotCanvas(width: 768, height: 768)
        case "4:3": return ShotCanvas(width: 1024, height: 768)
        case "2.39:1": return ShotCanvas(width: 1536, height: 640)
        default:
            details.append("Shot \"\(shot)\" has the aspect \"\(aspect)\", which Shots does not have; it became 9:16.")
            return .portrait
        }
    }

    private func cameraMark(_ mark: BlockoutProject.CameraMark, ids: inout IDs) -> CameraMark {
        CameraMark(
            id: ids.make(mark.base.id, "mark"),
            time: mark.base.time,
            hold: mark.base.hold,
            easeIn: mark.base.easeIn,
            easeOut: mark.base.easeOut,
            position: mark.base.position.vec,
            via: (mark.base.via ?? []).map(\.vec),
            pan: mark.pan,
            tilt: mark.tilt,
            roll: mark.roll,
            focalLength: mark.focalLength,
            focusDistance: mark.focusDistance
        )
    }
}

/// Keeps Blockout's ids, or mints one new id per old id so references stay consistent within a scene.
private struct IDs {
    let keep: Bool
    private var minted: [String: String] = [:]

    init(keep: Bool) {
        self.keep = keep
    }

    mutating func make(_ old: String, _ prefix: String) -> String {
        if keep { return old }
        let key = prefix + "\u{0}" + old
        if let existing = minted[key] { return existing }
        let fresh = PrevisIDs.make(prefix)
        minted[key] = fresh
        return fresh
    }
}
