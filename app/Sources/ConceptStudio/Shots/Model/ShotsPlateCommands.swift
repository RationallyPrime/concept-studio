import Foundation
import PrevisCore
import ShotsMedia

/// The edits behind blocking over a plate (CONTRACTS section 7): plates, which plate a shot is blocked over, the
/// key's size, what the shot asks to show, and a set piece's size.
enum ShotsPlateCommands {
    static func apply(_ command: ShotsCommand, to document: inout ShotsDocument) throws -> Bool {
        try applyPlate(command, to: &document) || applyShot(command, to: &document)
    }

    private static func applyPlate(_ command: ShotsCommand, to document: inout ShotsDocument) throws -> Bool {
        switch command {
        case let .addPlate(sceneID, plate):
            let scene = try sceneIndex(sceneID, in: document)
            guard !document.scenes[scene].plates.contains(where: { $0.id == plate.id }) else {
                throw ShotsEditingError.duplicate(plate.id)
            }
            document.scenes[scene].plates.append(plate)
        case let .updatePlate(sceneID, plate):
            let scene = try sceneIndex(sceneID, in: document)
            guard let index = document.scenes[scene].plates.firstIndex(where: { $0.id == plate.id }) else {
                throw ShotsEditingError.missing("plate")
            }
            document.scenes[scene].plates[index] = plate
            // A match is made once per plate: every shot on the plate starts from its camera.
            for shot in document.scenes[scene].shots.indices
                where document.scenes[scene].shots[shot].plateID == plate.id {
                sync(&document.scenes[scene].shots[shot], to: plate)
            }
        case let .deletePlate(sceneID, plateID):
            let scene = try sceneIndex(sceneID, in: document)
            document.scenes[scene].plates.removeAll { $0.id == plateID }
            for shot in document.scenes[scene].shots.indices
                where document.scenes[scene].shots[shot].plateID == plateID {
                document.scenes[scene].shots[shot].plateID = nil
            }
        default:
            return false
        }
        return true
    }

    private static func applyShot(_ command: ShotsCommand, to document: inout ShotsDocument) throws -> Bool {
        switch command {
        case let .setShotPlate(shotID, plateID):
            let index = try shotIndex(shotID, in: document)
            guard let plateID else {
                document.scenes[index.scene].shots[index.shot].plateID = nil
                break
            }
            guard let plate = document.scenes[index.scene].plates.first(where: { $0.id == plateID }) else {
                throw ShotsEditingError.missing("plate")
            }
            sync(&document.scenes[index.scene].shots[index.shot], to: plate)
        case let .setKeyCanvas(shotID, canvas):
            let index = try shotIndex(shotID, in: document)
            document.scenes[index.scene].shots[index.shot].keyCanvas = canvas
        case let .setAsks(shotID, asks):
            let index = try shotIndex(shotID, in: document)
            document.scenes[index.scene].shots[index.shot].asks = asks
        case let .setSetPiece(entityID, piece):
            for scene in document.scenes.indices {
                guard let entity = document.scenes[scene].entities.firstIndex(where: { $0.id == entityID }) else {
                    continue
                }
                guard document.scenes[scene].entities[entity].setPiece != nil else {
                    throw ShotsEditingError.missing("set piece")
                }
                var piece = piece
                // The kind is the asset's, fixed once placed.
                piece.kind = document.scenes[scene].entities[entity].setPiece?.kind ?? piece.kind
                document.scenes[scene].entities[entity].setPiece = piece
                return true
            }
            throw ShotsEditingError.missing("set piece")
        case let .giveOwnBlocking(shotID, takeID):
            let index = try shotIndex(shotID, in: document)
            guard !document.scenes.contains(where: { $0.blocking.contains { $0.id == takeID } }) else {
                throw ShotsEditingError.duplicate(takeID)
            }
            document.scenes[index.scene].giveOwnBlocking(to: shotID, takeID: takeID)
        case let .replaceScene(scene):
            let index = try sceneIndex(scene.id, in: document)
            document.scenes[index] = scene
        default:
            return false
        }
        return true
    }

    /// Puts a shot on a plate's camera (PrevisCore `Shot.block(over:)`).
    static func sync(_ shot: inout Shot, to plate: LocationPlate) {
        shot.block(over: plate)
    }

    /// A set piece added from the library gets its standard size. In a scene with plates it starts as something
    /// the plate already shows.
    ///
    /// Over a matched plate, something added at the stage's centre with no facing starts four metres in front of
    /// the plate's camera and turned toward it: at the centre it would stand under the camera, out of sight. A
    /// set piece turns in quarter turns, so it stays square to the set the plate's lines were drawn along.
    static func completed(_ entity: PrevisEntity, in scene: PrevisScene) -> PrevisEntity {
        var entity = entity
        if entity.setPiece == nil, entity.assetID.hasPrefix("set."),
           let kind = SetPiece.Kind(rawValue: String(entity.assetID.dropFirst(4))) {
            entity.setPiece = .standard(kind, inPlate: !scene.plates.isEmpty)
        }
        guard let match = scene.plates.lazy.compactMap(\.match).first, entity.placement.heading == 0 else {
            return entity
        }
        if entity.placement.position == .zero {
            entity.placement.position = Vec3(
                match.position.x - 4 * sin(match.pan), 0, match.position.z - 4 * cos(match.pan)
            )
        }
        let dx = match.position.x - entity.placement.position.x, dz = match.position.z - entity.placement.position.z
        guard hypot(dx, dz) > 1e-6 else { return entity }
        var heading = atan2(-dx, -dz)
        if entity.setPiece != nil { heading = (heading / (.pi / 2)).rounded() * (.pi / 2) }
        entity.placement.heading = heading
        return entity
    }

    private static func sceneIndex(_ id: SceneID, in document: ShotsDocument) throws -> Int {
        guard let index = document.scenes.firstIndex(where: { $0.id == id }) else {
            throw ShotsEditingError.missing("scene")
        }
        return index
    }

    private static func shotIndex(_ id: ShotID, in document: ShotsDocument) throws -> (scene: Int, shot: Int) {
        for scene in document.scenes.indices {
            if let shot = document.scenes[scene].shots.firstIndex(where: { $0.id == id }) { return (scene, shot) }
        }
        throw ShotsEditingError.missing("shot")
    }
}

/// Plate images in the project folder.
enum ShotsPlateFiles {
    /// Copies an image the user chose into the project's `Shots/Plates` folder and describes it as a plate. The
    /// copy keeps the original's bytes: a plate is never resampled or re-encoded.
    static func importPlate(from source: URL, intoProject project: URL, id: PlateID) throws -> LocationPlate {
        guard let size = PlateImages.pixelSize(of: source) else {
            throw ShotsMediaError("\(source.lastPathComponent) isn't an image Shots can read. Use a PNG or JPEG plate.")
        }
        let folder = PlateImages.folder(inProject: project)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fileExtension = source.pathExtension.isEmpty ? "png" : source.pathExtension.lowercased()
        let file = "\(id).\(fileExtension)"
        let target = folder.appendingPathComponent(file)
        if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
        try FileManager.default.copyItem(at: source, to: target)
        return LocationPlate(
            id: id, name: source.deletingPathExtension().lastPathComponent, file: file, size: size, guides: .none
        )
    }
}

extension ShotsStore {
    /// The plate the current shot is blocked over.
    var currentPlate: LocationPlate? {
        guard let id = currentShot?.plateID else { return nil }
        return currentScene?.plates.first { $0.id == id }
    }

    /// Adds an image as a plate of the current scene and blocks the current shot over it, as one undo step.
    @discardableResult
    func addPlate(from source: URL, projectDirectory: URL) throws -> PlateID {
        guard !isReadOnly else { throw ShotsEditingError.readOnly }
        guard let scene = currentScene, let shot = currentShot else { throw ShotsEditingError.missing("shot") }
        let plate = try ShotsPlateFiles.importPlate(from: source, intoProject: projectDirectory, id: newID("plate"))
        try perform([.addPlate(scene.id, plate), .setShotPlate(shot.id, plate.id)])
        return plate.id
    }

    /// The current shot's first mark of an entity in its take: where the entity stands when the shot starts, when
    /// it has marks.
    func firstMark(of entityID: EntityID) -> ActorMark? {
        guard let scene = currentScene, let shot = currentShot else { return nil }
        return scene.blocking.first { $0.id == shot.blockingTakeID }?.tracks
            .first { $0.entityID == entityID }?.marks.min { $0.time < $1.time }
    }

    /// Stands an entity somewhere else in the current shot, taking its marks along, as one undo step.
    func move(_ entityID: EntityID, to position: Vec3) {
        guard let scene = currentScene, let entity = scene.entities.first(where: { $0.id == entityID }) else { return }
        let from = firstMark(of: entityID)?.position ?? entity.placement.position
        let delta = Vec3(position.x - from.x, position.y - from.y, position.z - from.z)
        run(ViewportKeyboard.entityNudgeCommands(for: [entityID], by: delta, in: scene, currentShot: currentShot))
    }

    /// Turns an entity about where it stands in the current shot, taking its marks along, as one undo step.
    func turn(_ entityID: EntityID, to heading: Double) {
        guard let scene = currentScene, let entity = scene.entities.first(where: { $0.id == entityID }) else { return }
        let mark = firstMark(of: entityID)
        let from = mark?.arriveHeading ?? entity.placement.heading
        let pivot = mark?.position ?? entity.placement.position
        run(ViewportKeyboard.entityNudgeCommands(
            for: [entityID], by: .zero, turning: (pivot: pivot, angle: heading - from), in: scene,
            currentShot: currentShot
        ))
    }

    /// What the current frame shows of each character, for the staging panel and the scene board.
    var staging: Staging? {
        evaluator?.staging(atFrame: playhead)
    }
}
