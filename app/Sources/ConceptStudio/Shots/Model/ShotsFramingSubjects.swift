import PrevisCore

/// Who a framing button frames, as Blockout chooses at 3f2d0564 (`src/renderer/viewport/SceneManager.ts`).
///
/// - Shot sizes (`autoFrame`, lines 1416-1424): the selected entity when exactly one is selected, else the first
///   person in the scene, else its first entity.
/// - The other framings (`framingSubjects`, lines 1480-1489): the selected entities when two or more are selected,
///   else every person in the scene, else its first two entities.
///
/// Entities come in document order, as Blockout filters `docScene.entities`. Aim lock plays no part: it is the
/// camera's own setting and does not pick framing subjects.
enum ShotsFramingSubjects {
    static func subjects(for kind: Framing.Kind, in scene: PrevisScene, selection: ShotsSelection) -> [EntityID] {
        let selected: [EntityID] = if case let .entities(ids) = selection {
            scene.entities.map(\.id).filter(ids.contains)
        } else {
            []
        }
        let people = scene.entities.filter { $0.assetID.hasPrefix("person.") }.map(\.id)
        switch kind {
        case .wide, .full, .medium, .closeUp:
            if selected.count == 1 { return selected }
            guard let first = people.first ?? scene.entities.first?.id else { return [] }
            return [first]
        case .twoShot, .overShoulder, .reverse, .top, .low, .dutch:
            if selected.count >= 2 { return selected }
            return people.isEmpty ? scene.entities.prefix(2).map(\.id) : people
        }
    }
}

extension ShotsStore {
    /// The subjects `kind` frames in the current scene, from the current selection.
    func framingSubjects(for kind: Framing.Kind) -> [EntityID] {
        guard let scene = currentScene else { return [] }
        return ShotsFramingSubjects.subjects(for: kind, in: scene, selection: selection)
    }

    /// Frames the current subjects as `kind` at the playhead (the camera inspector's framing buttons).
    func applyFraming(_ kind: Framing.Kind) {
        guard let shotID = currentShotID else { return }
        run(.applyFraming(shotID, kind, subjects: framingSubjects(for: kind), atFrame: playhead))
    }
}
