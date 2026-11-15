import PrevisCore

/// Who a framing button or camera move frames, as Blockout chooses at 3f2d0564
/// (`src/renderer/viewport/SceneManager.ts`).
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

    /// The one subject a camera move is built around: the first selected entity in document order, else the first
    /// person, else the first entity. Blockout's `applyCameraMove` (lines 1704-1709) takes the first of
    /// `framingSubjects()`, which ignores a single selection and uses the first person; Shots follows its button
    /// help instead ("Select an entity first to build the move around it", `Inspector.tsx` line 1451), an
    /// intentional deviation (integrator ruling 2026-11-09). Several selected entities do not make a midpoint subject.
    static func cameraMoveSubject(in scene: PrevisScene, selection: ShotsSelection) -> EntityID? {
        if case let .entities(ids) = selection, let first = scene.entities.first(where: { ids.contains($0.id) }) {
            return first.id
        }
        return subjects(for: .twoShot, in: scene, selection: .none).first
    }
}

extension ShotsStore {
    /// The subjects `kind` frames in the current scene, from the current selection.
    func framingSubjects(for kind: Framing.Kind) -> [EntityID] {
        guard let scene = currentScene else { return [] }
        return ShotsFramingSubjects.subjects(for: kind, in: scene, selection: selection)
    }

    /// Frames the current subjects as `kind` at the playhead (the framing buttons).
    func applyFraming(_ kind: Framing.Kind) {
        guard let shotID = currentShotID else { return }
        run(.applyFraming(shotID, kind, subjects: framingSubjects(for: kind), atFrame: playhead))
    }

    /// The subject a camera move would be built around now, from the current selection.
    var cameraMoveSubject: EntityID? {
        currentScene.flatMap { ShotsFramingSubjects.cameraMoveSubject(in: $0, selection: selection) }
    }

    /// Replaces the shot's camera marks with `moveID` built around `cameraMoveSubject`. A move that follows its
    /// subject aim-locks onto it; any other move clears aim lock (`CameraMoves.marks`, Blockout `applyCameraMove`).
    func applyCameraMove(_ moveID: String) {
        guard let shotID = currentShotID else { return }
        run(.applyCameraMove(shotID, moveID: moveID, subjects: cameraMoveSubject.map { [$0] } ?? []))
    }
}
