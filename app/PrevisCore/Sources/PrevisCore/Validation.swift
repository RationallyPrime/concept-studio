import Foundation

/// Problems in a document, CONTRACTS section 5.6. Errors are what stops a shot from being evaluated or exported:
/// unresolved references, attachment cycles, non-finite numbers, an invalid canvas or frame count, an unknown asset,
/// and guide frames out of range. Everything else is a warning. Each message names the thing and the fix.
public enum ShotsValidation {
    public static func problems(in document: ShotsDocument, catalog: ContentCatalog) -> [ShotsProblem] {
        document.scenes.flatMap { SceneChecker(scene: $0, catalog: catalog).problems() }
    }
}

private struct SceneChecker {
    let scene: PrevisScene
    let catalog: ContentCatalog

    private var entityIDs: Set<EntityID> {
        Set(scene.entities.map(\.id))
    }

    private func name(of id: EntityID) -> String {
        scene.entities.first { $0.id == id }?.name ?? id
    }

    private func error(
        _ message: String,
        shot: ShotID? = nil,
        entity: EntityID? = nil,
        mark: MarkID? = nil
    ) -> ShotsProblem {
        ShotsProblem(
            severity: .error,
            message: message,
            sceneID: scene.id,
            shotID: shot,
            entityID: entity,
            markID: mark
        )
    }

    private func warning(_ message: String, shot: ShotID? = nil, entity: EntityID? = nil) -> ShotsProblem {
        ShotsProblem(severity: .warning, message: message, sceneID: scene.id, shotID: shot, entityID: entity)
    }

    func problems() -> [ShotsProblem] {
        entityProblems() + attachmentCycles() + takeProblems() + scene.shots.flatMap(shotProblems)
    }

    // MARK: Entities

    private func entityProblems() -> [ShotsProblem] {
        var out: [ShotsProblem] = []
        for entity in scene.entities {
            if catalog.asset(entity.assetID) == nil {
                out.append(error(
                    "\"\(entity.name)\" uses the unknown asset \(entity.assetID); choose an asset from the catalog.",
                    entity: entity.id
                ))
            }
            let placement = entity.placement
            if !placement.position.isFinite || !placement.heading.isFinite || !placement.scale.isFinite {
                out.append(error(
                    "\"\(entity.name)\" has a position, heading or scale that is not a number; reset it.",
                    entity: entity.id
                ))
            } else if placement.scale <= 0 {
                out.append(warning(
                    "\"\(entity.name)\" has a scale of \(placement.scale); use a scale above zero.",
                    entity: entity.id
                ))
            }
            if let attachment = entity.attachment {
                if !entityIDs.contains(attachment.parentID) {
                    out.append(error(
                        "\"\(entity.name)\" is attached to \(attachment.parentID), which is not in the scene; "
                            + "detach it or pick another parent.",
                        entity: entity.id
                    ))
                }
                if !attachment.offset.isFinite {
                    out.append(error(
                        "The attachment of \"\(entity.name)\" has an offset that is not a number; reset it.",
                        entity: entity.id
                    ))
                }
                let rotation = attachment.rotation
                if !(rotation.x.isFinite && rotation.y.isFinite && rotation.z.isFinite && rotation.w.isFinite) {
                    out.append(error(
                        "The attachment of \"\(entity.name)\" has a rotation that is not a number; reset it.",
                        entity: entity.id
                    ))
                }
            }
        }
        return out
    }

    /// One error per cycle, naming every entity on it.
    private func attachmentCycles() -> [ShotsProblem] {
        AttachmentCycles.find(in: scene.entities).map { cycle in
            let names = cycle.map { "\"\(name(of: $0))\"" }.joined(separator: " and ")
            return error("\(names) are attached to each other in a cycle; detach one of them.", entity: cycle[0])
        }
    }

    // MARK: Takes

    private func takeProblems() -> [ShotsProblem] {
        var out: [ShotsProblem] = []
        for take in scene.blocking {
            for track in take.tracks {
                guard entityIDs.contains(track.entityID) else {
                    out.append(error(
                        "The take \"\(take.name)\" has a track for \(track.entityID), which is not in the scene; "
                            + "delete the track.",
                        entity: track.entityID
                    ))
                    continue
                }
                for mark in track.marks {
                    if !(mark.time.isFinite && mark.hold.isFinite && mark.easeIn.isFinite && mark.easeOut.isFinite
                        && mark.position.isFinite && mark.via.allSatisfy(\.isFinite)
                        && (mark.arriveHeading?.isFinite ?? true) && mark.joints.values.allSatisfy(\.isFinite)) {
                        out.append(error(
                            "A mark of \"\(name(of: track.entityID))\" has a value that is not a number; "
                                + "move or delete it.",
                            entity: track.entityID,
                            mark: mark.id
                        ))
                    }
                    if let board = mark.boardID, !entityIDs.contains(board) {
                        out.append(error(
                            "A mark of \"\(name(of: track.entityID))\" boards \(board), which is not in the scene; "
                                + "clear the boarding or pick another vehicle.",
                            entity: track.entityID,
                            mark: mark.id
                        ))
                    }
                }
            }
        }
        return out
    }

    // MARK: Shots

    private func shotProblems(_ shot: Shot) -> [ShotsProblem] {
        var out: [ShotsProblem] = []
        let label = "Shot \"\(shot.name)\""
        if !scene.blocking.contains(where: { $0.id == shot.blockingTakeID }) {
            out.append(error(
                "\(label) uses the take \(shot.blockingTakeID), which is not in the scene; choose one of its takes.",
                shot: shot.id
            ))
        }
        if !FrameGrid.isValid(shot.frameCount) {
            out.append(error(
                "\(label) has \(shot.frameCount) frames, which is not on the grid (5, 22, 39, ... 17 more each time); "
                    + "use \(FrameGrid.snap(shot.frameCount)).",
                shot: shot.id
            ))
        }
        if !shot.canvas.isValid {
            out.append(error(
                "\(label) has a \(shot.canvas.width) × \(shot.canvas.height) canvas; "
                    + "use multiples of 32 from 64 to 2048.",
                shot: shot.id
            ))
        }
        out += cameraProblems(shot, label)
        out += guideProblems(shot, label)
        for note in shot.notes.characters where !entityIDs.contains(note.entityID) {
            out.append(error(
                "\(label) describes \(note.entityID), who is not in the scene; delete that note.",
                shot: shot.id,
                entity: note.entityID
            ))
        }
        return out
    }

    private func cameraProblems(_ shot: Shot, _ label: String) -> [ShotsProblem] {
        var out: [ShotsProblem] = []
        let camera = shot.camera
        if let mount = camera.mountID, !entityIDs.contains(mount) {
            out.append(error(
                "\(label) mounts its camera on \(mount), which is not in the scene; clear the mount.",
                shot: shot.id
            ))
        }
        for id in camera.trackIDs where !entityIDs.contains(id) {
            out.append(error(
                "\(label) aims its camera at \(id), which is not in the scene; clear the aim lock.",
                shot: shot.id
            ))
        }
        if !camera.seed.isFinite || !camera.rigIntensity.isFinite {
            out.append(error(
                "\(label) has a camera seed or rig intensity that is not a number; reset it.",
                shot: shot.id
            ))
        }
        for mark in camera.marks {
            let numbers = [
                mark.time,
                mark.hold,
                mark.easeIn,
                mark.easeOut,
                mark.pan,
                mark.tilt,
                mark.roll,
                mark.focalLength,
            ]
            if !(numbers.allSatisfy(\.isFinite) && mark.position.isFinite && mark.via.allSatisfy(\.isFinite)
                && (mark.focusDistance?.isFinite ?? true)) {
                out.append(error(
                    "\(label) has a camera mark with a value that is not a number; move or delete it.",
                    shot: shot.id,
                    mark: mark.id
                ))
            } else if mark.focalLength <= 0 {
                out.append(error(
                    "\(label) has a camera mark with a \(mark.focalLength) mm lens; use a lens above zero.",
                    shot: shot.id,
                    mark: mark.id
                ))
            }
        }
        return out
    }

    private func guideProblems(_ shot: Shot, _ label: String) -> [ShotsProblem] {
        var out: [ShotsProblem] = []
        let valid = 1 ... max(shot.frameCount - 2, 1)
        for frame in shot.guideFrames where !valid.contains(frame) || shot.frameCount < 3 {
            out.append(error(
                "\(label) has a guide frame at \(frame), outside 1 to \(shot.frameCount - 2); move or delete it.",
                shot: shot.id
            ))
        }
        if shot.guideFrames != Array(Set(shot.guideFrames)).sorted() {
            out.append(warning(
                "\(label) lists its guide frames out of order or twice; sort them and remove repeats.",
                shot: shot.id
            ))
        }
        return out
    }
}

private extension Vec3 {
    var isFinite: Bool {
        x.isFinite && y.isFinite && z.isFinite
    }
}
