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
        let scenes = try project.scenes.map { try converter.scene($0) }
        return (ShotsDocument(version: ShotsDocument.currentVersion, scenes: scenes), converter.notes)
    }
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

    mutating func scene(_ source: BlockoutProject.Scene) throws -> PrevisScene {
        var ids = IDs(keep: keepIDs)
        drop(.drafts, count: source.drafts?.count ?? 0)
        drop(.scans, count: source.scans?.count ?? 0)
        if let env = source.environment, env.sunAzimuth != nil || env.sunElevation != nil || env.fog != nil {
            drop(.environment)
        }

        let entities = importedEntities(source, ids: &ids)
        let kept = Set(entities.map(\.id))
        let take = chosenTake(source, ids: &ids, keptEntities: kept)

        var shots: [Shot] = []
        for source in source.shots {
            try shots.append(shot(source, takeID: take.id, ids: &ids, kept: kept))
        }
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
            let height = asset?.rig == .person ? heightMultiplier(source) : nil
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
    ) throws -> Shot {
        let frameCount = try frameCount(of: source)
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
            frameCount: frameCount,
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

    /// `duration · 24 + 1` frames, rounded up onto the grid. A duration that is not finite and non-negative, or whose
    /// frame count would not leave headroom to add one and round up, is bad data and fails the import.
    private func frameCount(of shot: BlockoutProject.Shot) throws -> Int {
        guard let duration = shot.duration else { return FrameGrid.defaultFrameCount }
        let frames = duration * Double(FrameGrid.fps)
        guard duration.isFinite, duration >= 0, frames <= Double(Self.maxFrames) else {
            throw ShotsError.importFailed(
                "Shot \"\(shot.name)\" has the duration \(duration) s, which cannot be a frame count; "
                    + "fix the duration in the Blockout project."
            )
        }
        return FrameGrid.snapUp(Int(frames.rounded()) + 1)
    }

    /// Far past any real shot, and far enough below `Int.max` that adding one and rounding up cannot overflow.
    private static let maxFrames = Int.max / 64

    /// `params.height` on a person multiplies the scale, as supplied. A value that cannot be a scale is ignored.
    private mutating func heightMultiplier(_ entity: BlockoutProject.Entity) -> Double? {
        guard let height = entity.params?["height"]?.number else { return nil }
        guard height.isFinite, height > 0 else {
            details.append("\"\(entity.name)\" has the height \(height), which cannot scale a person; it was ignored.")
            return nil
        }
        return height
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
