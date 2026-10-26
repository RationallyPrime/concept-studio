import PrevisCore

enum ShotsCommandApplication {
    static func apply(_ command: ShotsCommand, to document: inout ShotsDocument, catalog: ContentCatalog) throws {
        if try applyScene(command, to: &document) || applyEntity(command, to: &document, catalog: catalog)
            || applyShot(command, to: &document) || applyMarks(command, to: &document)
            || applyCamera(command, to: &document)
            || ShotsGeneratedEdits.apply(command, to: &document, catalog: catalog) { return }
        throw ShotsError.notImplemented("This Shots edit")
    }

    private static func applyScene(_ command: ShotsCommand, to document: inout ShotsDocument) throws -> Bool {
        switch command {
        case let .addScene(id, name, takeID, shotID, cameraMarkID):
            try requireNew([id, takeID, shotID, cameraMarkID], in: document)
            document.scenes.append(.make(
                id: id,
                name: name,
                takeID: takeID,
                shotID: shotID,
                cameraMarkID: cameraMarkID
            ))
        case let .renameScene(id, name):
            try document.scenes[sceneIndex(id, in: document)].name = name
        case let .deleteScene(id):
            try document.scenes.remove(at: sceneIndex(id, in: document))
        case let .importScenes(scenes):
            try requireNew(allIDs(in: ShotsDocument(version: document.version, scenes: scenes)), in: document)
            document.scenes.append(contentsOf: scenes)
        case let .setLighting(id, lighting):
            try document.scenes[sceneIndex(id, in: document)].lighting = lighting
        default: return false
        }
        return true
    }

    private static func applyEntity(
        _ command: ShotsCommand, to document: inout ShotsDocument, catalog: ContentCatalog
    ) throws -> Bool {
        switch command {
        case let .addEntity(sceneID, entity):
            try requireNew([entity.id], in: document)
            guard catalog.asset(entity.assetID) != nil else { throw ShotsError.unknownContent(entity.assetID) }
            try document.scenes[sceneIndex(sceneID, in: document)].entities.append(entity)
        case let .deleteEntities(ids):
            deleteEntities(Set(ids), from: &document)
        case let .setPlacement(id, placement):
            let index = try entityIndex(id, in: document)
            document.scenes[index.scene].entities[index.entity].placement = placement
        case let .renameEntity(id, name):
            let index = try entityIndex(id, in: document)
            document.scenes[index.scene].entities[index.entity].name = name
        case let .setLabel(id, label):
            let index = try entityIndex(id, in: document)
            document.scenes[index.scene].entities[index.entity].label = label
        default: return false
        }
        return true
    }

    private static func applyShot(_ command: ShotsCommand, to document: inout ShotsDocument) throws -> Bool {
        switch command {
        case let .addShot(sceneID, id, name, cameraMarkID):
            try requireNew([id, cameraMarkID], in: document)
            let index = try sceneIndex(sceneID, in: document)
            guard let takeID = document.scenes[index].blocking.first?.id
            else { throw ShotsEditingError.missing("take") }
            document.scenes[index].shots.append(.make(id: id, name: name, takeID: takeID, cameraMarkID: cameraMarkID))
        case let .duplicateShot(id, newID):
            let index = try shotIndex(id, in: document)
            var copy = document.scenes[index.scene].shots[index.shot]
            copy.id = newID
            copy.camera.marks = copy.camera.marks.enumerated().map { index, source in
                var mark = source
                mark.id = "\(newID)_camera_\(index)"
                return mark
            }
            try requireNew([newID] + copy.camera.marks.map(\.id), in: document)
            document.scenes[index.scene].shots.insert(copy, at: index.shot + 1)
        case let .renameShot(id, name):
            try editShot(id, in: &document) { $0.name = name }
        case let .deleteShot(id):
            let index = try shotIndex(id, in: document)
            document.scenes[index.scene].shots.remove(at: index.shot)
        case let .setFrameCount(id, count):
            try editShot(id, in: &document) {
                $0.frameCount = FrameGrid.snap(count)
                let last = $0.frameCount - 1
                $0.guideFrames.removeAll { $0 <= 0 || $0 >= last }
            }
        case let .setCanvas(id, canvas):
            try editShot(id, in: &document) { $0.canvas = canvas }
        case let .setGuideFrames(id, frames):
            try editShot(id, in: &document) { $0.guideFrames = Array(Set(frames)).sorted() }
        case let .setNotes(id, notes):
            try editShot(id, in: &document) { $0.notes = notes }
        case let .setPrompt(id, prompt):
            try editShot(id, in: &document) { $0.prompt = prompt }
        default: return false
        }
        return true
    }

    private static func applyMarks(_ command: ShotsCommand, to document: inout ShotsDocument) throws -> Bool {
        switch command {
        case let .addActorMark(shotID, entityID, mark):
            try requireNew([mark.id], in: document)
            try editActorTrack(shotID, entityID, in: &document) { $0.marks.append(mark) }
        case let .updateActorMark(shotID, entityID, mark):
            try editActorTrack(shotID, entityID, in: &document) {
                guard let index = $0.marks.firstIndex(where: { $0.id == mark.id }) else {
                    throw ShotsEditingError.missing("actor mark")
                }
                $0.marks[index] = mark
            }
        case let .deleteMarks(shotID, markIDs):
            let index = try shotIndex(shotID, in: document)
            let takeID = document.scenes[index.scene].shots[index.shot].blockingTakeID
            try editShot(shotID, in: &document) { shot in
                shot.camera.marks.removeAll { markIDs.contains($0.id) }
            }
            for take in document.scenes[index.scene].blocking.indices
                where document.scenes[index.scene].blocking[take].id == takeID {
                for track in document.scenes[index.scene].blocking[take].tracks.indices {
                    document.scenes[index.scene].blocking[take].tracks[track].marks
                        .removeAll { markIDs.contains($0.id) }
                }
            }
        case let .addCameraMark(shotID, mark):
            try requireNew([mark.id], in: document)
            try editShot(shotID, in: &document) {
                $0.camera.marks.append(mark); $0.camera.marks.sort { $0.time < $1.time }
            }
        case let .updateCameraMark(shotID, mark):
            try editShot(shotID, in: &document) {
                guard let index = $0.camera.marks.firstIndex(where: { $0.id == mark.id }) else {
                    throw ShotsEditingError.missing("camera mark")
                }
                $0.camera.marks[index] = mark
                $0.camera.marks.sort { $0.time < $1.time }
            }
        default: return false
        }
        return true
    }

    private static func editShot(
        _ id: ShotID, in document: inout ShotsDocument, edit: (inout Shot) throws -> Void
    ) throws {
        let index = try shotIndex(id, in: document)
        try edit(&document.scenes[index.scene].shots[index.shot])
    }

    private static func editActorTrack(
        _ shotID: ShotID, _ entityID: EntityID, in document: inout ShotsDocument,
        edit: (inout Track) throws -> Void
    ) throws {
        let index = try shotIndex(shotID, in: document)
        let takeID = document.scenes[index.scene].shots[index.shot].blockingTakeID
        guard document.scenes[index.scene].entities.contains(where: { $0.id == entityID }),
              let takeIndex = document.scenes[index.scene].blocking.firstIndex(where: { $0.id == takeID })
        else { throw ShotsEditingError.missing("actor or take") }
        var take = document.scenes[index.scene].blocking[takeIndex]
        if !take.tracks.contains(where: { $0.entityID == entityID }) {
            take.tracks.append(Track(entityID: entityID, marks: []))
        }
        let trackIndex = take.tracks.firstIndex { $0.entityID == entityID }!
        try edit(&take.tracks[trackIndex])
        take.tracks[trackIndex].marks.sort { $0.time < $1.time }
        document.scenes[index.scene].blocking[takeIndex] = take
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

    private static func entityIndex(_ id: EntityID, in document: ShotsDocument) throws -> (scene: Int, entity: Int) {
        for scene in document.scenes.indices {
            if let entity = document.scenes[scene].entities
                .firstIndex(where: { $0.id == id }) { return (scene, entity) }
        }
        throw ShotsEditingError.missing("entity")
    }

    private static func applyCamera(_ command: ShotsCommand, to document: inout ShotsDocument) throws -> Bool {
        switch command {
        case let .setCameraRig(id, sensor, rig, intensity):
            try editShot(id, in: &document) {
                $0.camera.sensor = sensor
                $0.camera.rig = rig
                $0.camera.rigIntensity = intensity
            }
        case let .setTracking(id, subjects):
            try editShot(id, in: &document) { $0.camera.trackIDs = subjects }
        case let .setMount(id, parent):
            try editShot(id, in: &document) { $0.camera.mountID = parent }
        default: return false
        }
        return true
    }

    private static func deleteEntities(_ ids: Set<EntityID>, from document: inout ShotsDocument) {
        for scene in document.scenes.indices {
            document.scenes[scene].entities.removeAll { ids.contains($0.id) }
            for entity in document.scenes[scene].entities.indices {
                if let parent = document.scenes[scene].entities[entity].attachment?.parentID, ids.contains(parent) {
                    document.scenes[scene].entities[entity].attachment = nil
                }
            }
            for take in document.scenes[scene].blocking.indices {
                document.scenes[scene].blocking[take].tracks.removeAll { ids.contains($0.entityID) }
                for track in document.scenes[scene].blocking[take].tracks.indices {
                    for mark in document.scenes[scene].blocking[take].tracks[track].marks.indices {
                        if let board = document.scenes[scene].blocking[take].tracks[track].marks[mark].boardID,
                           ids.contains(board) {
                            document.scenes[scene].blocking[take].tracks[track].marks[mark].boardID = nil
                        }
                    }
                }
            }
            for shot in document.scenes[scene].shots.indices {
                document.scenes[scene].shots[shot].camera.trackIDs.removeAll { ids.contains($0) }
                if let mount = document.scenes[scene].shots[shot].camera.mountID, ids.contains(mount) {
                    document.scenes[scene].shots[shot].camera.mountID = nil
                }
                document.scenes[scene].shots[shot].notes.characters.removeAll { ids.contains($0.entityID) }
            }
        }
    }

    private static func allIDs(in document: ShotsDocument) -> [String] {
        var ids: [String] = []
        for scene in document.scenes {
            ids.append(scene.id)
            ids.append(contentsOf: scene.entities.map(\.id))
            for take in scene.blocking {
                ids.append(take.id)
                for track in take.tracks {
                    ids.append(contentsOf: track.marks.map(\.id))
                }
            }
            for shot in scene.shots {
                ids.append(shot.id)
                ids.append(contentsOf: shot.camera.marks.map(\.id))
            }
        }
        return ids
    }

    private static func requireNew(_ ids: [String], in document: ShotsDocument) throws {
        var existing = Set(allIDs(in: document))
        for id in ids {
            guard existing.insert(id).inserted else { throw ShotsEditingError.duplicate(id) }
        }
    }
}
