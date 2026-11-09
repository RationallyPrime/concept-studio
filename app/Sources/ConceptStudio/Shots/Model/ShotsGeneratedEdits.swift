import PrevisCore

/// Document-side plumbing only. Motion, framing and attachment math remain in PrevisCore.
enum ShotsGeneratedEdits {
    static func apply(
        _ command: ShotsCommand,
        to document: inout ShotsDocument,
        catalog: ContentCatalog
    ) throws -> Bool {
        switch command {
        case let .applyCameraMove(shotID, moveID, subjects):
            try edit(shotID, in: &document) { scene, shot in
                let generated = try CameraMoves.marks(
                    moveID, scene: scene, shotID: shot.id, subjects: subjects, catalog: catalog
                )
                shot.camera.marks = generated.marks
                shot.camera.trackIDs = generated.trackIDs
            }
        case let .applyFraming(shotID, kind, subjects, atFrame):
            try edit(shotID, in: &document) { scene, shot in
                let mark = try Framing.cameraMark(
                    kind, scene: scene, shotID: shot.id, subjects: subjects, atFrame: atFrame, catalog: catalog
                )
                frame(mark, kind: kind, into: &shot.camera.marks)
            }
        default: return try applyActor(command, to: &document, catalog: catalog)
        }
        return true
    }

    private static func applyActor(
        _ command: ShotsCommand, to document: inout ShotsDocument, catalog: ContentCatalog
    ) throws -> Bool {
        switch command {
        case let .applyMotion(shot, entity, motion, frame):
            try editTrack(shot, entity, in: &document) { actor, track in
                try Motions.apply(motion, to: actor, track: track, at: FrameGrid.time(ofFrame: frame), catalog: catalog)
            }
        case let .overlayMotion(shot, entity, motion):
            try editTrack(shot, entity, in: &document) { _, track in
                guard let track else { throw ShotsEditingError.missing("actor track") }
                return try Motions.overlay(motion, onto: track, catalog: catalog)
            }
        case let .applyActionPath(shot, entity, path, frame, duration, speed):
            try editTrack(shot, entity, in: &document) { actor, _ in
                try Track(entityID: entity, marks: ActionPaths.marks(
                    path, entity: actor, startTime: FrameGrid.time(ofFrame: frame),
                    duration: duration, speed: speed, catalog: catalog
                ))
            }
        case let .attach(child, parent, shot, frame):
            try attach(child, to: parent, shot: shot, frame: frame, in: &document, catalog: catalog)
        default: return false
        }
        return true
    }

    private static func editTrack(
        _ shotID: ShotID, _ entityID: EntityID, in document: inout ShotsDocument,
        generate: (PrevisEntity, Track?) throws -> Track
    ) throws {
        for sceneIndex in document.scenes.indices {
            let scene = document.scenes[sceneIndex]
            guard let shot = scene.shots.first(where: { $0.id == shotID }) else { continue }
            guard let entity = scene.entities.first(where: { $0.id == entityID }),
                  let takeIndex = scene.blocking.firstIndex(where: { $0.id == shot.blockingTakeID })
            else { throw ShotsEditingError.missing("actor or take") }
            var take = scene.blocking[takeIndex]
            let index = take.tracks.firstIndex { $0.entityID == entityID }
            let generated = try generate(entity, index.map { take.tracks[$0] })
            if let index { take.tracks[index] = generated } else { take.tracks.append(generated) }
            document.scenes[sceneIndex].blocking[takeIndex] = take
            return
        }
        throw ShotsEditingError.missing("shot")
    }

    private static func attach(
        _ child: EntityID, to parent: EntityID?, shot shotID: ShotID, frame: Int,
        in document: inout ShotsDocument, catalog: ContentCatalog
    ) throws {
        for index in document.scenes.indices {
            let scene = document.scenes[index]
            guard scene.shots.contains(where: { $0.id == shotID }) else { continue }
            guard let entity = scene.entities.firstIndex(where: { $0.id == child })
            else { throw ShotsEditingError.missing("actor") }
            if let parent {
                document.scenes[index].entities[entity].attachment = try Attachments.attachment(
                    child: child, parent: parent, scene: scene, shotID: shotID, atFrame: frame, catalog: catalog
                )
            } else {
                let placement = try Attachments.placementWhenDetached(
                    child: child, scene: scene, shotID: shotID, atFrame: frame, catalog: catalog
                )
                document.scenes[index].entities[entity].placement = placement
                document.scenes[index].entities[entity].attachment = nil
            }
            return
        }
        throw ShotsEditingError.missing("shot")
    }

    /// Puts a framing's camera pose on the playhead's frame. Blockout writes it into the active camera mark, the
    /// last one at or before the playhead (`SceneManager.ts` `writeCameraPose`, `activeCameraMark`), so between
    /// marks its camera view at the playhead does not show the framing. Shots adds a mark at the playhead instead;
    /// a mark already on that frame is rewritten as Blockout does (position, pan and tilt, or only the roll for
    /// dutch; its timing, easing and focus stay), so the view there is the framing rather than a second mark at the
    /// same time that the evaluator plays after the first.
    static func frame(_ mark: CameraMark, kind: Framing.Kind, into marks: inout [CameraMark]) {
        let target = FrameGrid.frame(atTime: mark.time)
        let onFrame = marks.indices.filter { FrameGrid.frame(atTime: marks[$0].time) == target }
        guard !onFrame.isEmpty else {
            marks.append(mark)
            marks = marks.enumerated().sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }
                .map(\.element)
            return
        }
        for index in onFrame {
            // Dutch keeps the camera where it is and only turns the horizon; Blockout writes back the mark's own
            // pan and tilt. Reading them from the evaluated camera would bake in aim lock and rig shake.
            if kind == .dutch { marks[index].roll = mark.roll; continue }
            marks[index].position = mark.position
            marks[index].pan = mark.pan
            marks[index].tilt = mark.tilt
            // The distance was worked out for the lens at the playhead, which is this mark's own.
            marks[index].focalLength = mark.focalLength
        }
    }

    private static func edit(
        _ shotID: ShotID, in document: inout ShotsDocument, body: (PrevisScene, inout Shot) throws -> Void
    ) throws {
        for index in document.scenes.indices {
            let scene = document.scenes[index]
            if let shotIndex = scene.shots.firstIndex(where: { $0.id == shotID }) {
                var shot = scene.shots[shotIndex]
                try body(scene, &shot)
                document.scenes[index].shots[shotIndex] = shot
                return
            }
        }
        throw ShotsEditingError.missing("shot")
    }
}
