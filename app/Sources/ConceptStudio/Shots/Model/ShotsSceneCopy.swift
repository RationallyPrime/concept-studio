import PrevisCore

/// Copies a scene's graph without keeping references to the original scene's objects.
enum ShotsSceneCopy {
    static func duplicate(_ source: PrevisScene) -> PrevisScene {
        let ids = identifiers(in: source)
        func mapped(_ id: String) -> String {
            ids[id] ?? id
        }
        var copy = source
        copy.id = mapped(source.id)
        copy.name += " copy"
        for index in copy.entities.indices {
            copy.entities[index].id = mapped(copy.entities[index].id)
            if let parent = copy.entities[index].attachment?.parentID {
                copy.entities[index].attachment?.parentID = mapped(parent)
            }
        }
        for take in copy.blocking.indices {
            copy.blocking[take].id = mapped(copy.blocking[take].id)
            for track in copy.blocking[take].tracks.indices {
                copy.blocking[take].tracks[track].entityID = mapped(copy.blocking[take].tracks[track].entityID)
                for mark in copy.blocking[take].tracks[track].marks.indices {
                    var item = copy.blocking[take].tracks[track].marks[mark]
                    item.id = mapped(item.id)
                    item.boardID = item.boardID.map(mapped)
                    copy.blocking[take].tracks[track].marks[mark] = item
                }
            }
        }
        for index in copy.shots.indices {
            copy.shots[index] = duplicate(copy.shots[index], mapped: mapped)
        }
        return copy
    }

    private static func duplicate(_ source: Shot, mapped: (String) -> String) -> Shot {
        var copy = source
        copy.id = mapped(copy.id)
        copy.blockingTakeID = mapped(copy.blockingTakeID)
        copy.camera.trackIDs = copy.camera.trackIDs.map(mapped)
        copy.camera.mountID = copy.camera.mountID.map(mapped)
        for index in copy.camera.marks.indices {
            copy.camera.marks[index].id = mapped(copy.camera.marks[index].id)
        }
        for index in copy.notes.characters.indices {
            copy.notes.characters[index].entityID = mapped(copy.notes.characters[index].entityID)
        }
        for index in copy.results.indices {
            copy.results[index].id = mapped(copy.results[index].id)
        }
        return copy
    }

    private static func identifiers(in scene: PrevisScene) -> [String: String] {
        var ids = [scene.id: PrevisIDs.make("scene")]
        for entity in scene.entities {
            ids[entity.id] = PrevisIDs.make("entity")
        }
        for take in scene.blocking {
            ids[take.id] = PrevisIDs.make("take")
            for track in take.tracks {
                for mark in track.marks {
                    ids[mark.id] = PrevisIDs.make("mark")
                }
            }
        }
        for shot in scene.shots {
            ids[shot.id] = PrevisIDs.make("shot")
            for mark in shot.camera.marks {
                ids[mark.id] = PrevisIDs.make("camera")
            }
            for result in shot.results {
                ids[result.id] = PrevisIDs.make("result")
            }
        }
        return ids
    }
}
