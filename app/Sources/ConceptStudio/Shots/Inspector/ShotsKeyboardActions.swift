import PrevisCore

extension ShotsStore {
    /// Blockout store.ts:498ff supplies asset/name/selection semantics. The keyboard alternative adds at the stage
    /// origin; Lane D still owns click-to-place. Position can then be edited through the inspector fields.
    @discardableResult
    func addLibraryAsset(_ assetID: String, asFormation: Bool = false) throws -> EntityID {
        guard !isReadOnly else { throw ShotsEditingError.readOnly }
        guard let scene = currentScene, currentShot != nil else { throw ShotsEditingError.missing("shot") }
        guard preview.isEmpty else { throw ShotsEditingError.finishCurrentEdit }
        guard let asset = catalog.asset(assetID), catalog.starter.assets.contains(assetID) else {
            throw ShotsError.unknownContent(assetID)
        }
        let name = asFormation ? "\(asset.name) formation" : asset.name
        let count = scene.entities.filter { $0.assetID == assetID && ($0.formation != nil) == asFormation }.count
        let formation = asFormation ? Formation(rows: 3, columns: 7, rowSpacing: 1.3, columnSpacing: 0.9) : nil
        let entity = PrevisEntity(
            id: newID("entity"), assetID: assetID, name: count == 0 ? name : "\(name) \(count + 1)",
            placement: Placement(position: .zero, heading: 0, scale: 1), formation: formation
        )
        try perform(.addEntity(scene.id, entity))
        selection = .entities([entity.id])
        tool = .select
        return entity.id
    }

    func addNamedMember(_ slot: FormationSlot, assetID: String, name: String) throws {
        guard let scene = currentScene,
              let formation = frame?.entities.first(where: { $0.id == slot.formationID }) else {
            throw ShotsEditingError.missing("formation")
        }
        let member = PrevisEntity(
            id: newID("entity"), assetID: assetID, name: name,
            placement: Placement(position: formation.position, heading: formation.heading, scale: 1),
            formationSlot: slot
        )
        try perform(.addEntity(scene.id, member))
        selection = .entities([member.id])
    }

    /// Blockout store.ts:537ff creates a walk mark. LANE-D-VIEWPORT D3 deliberately uses the playhead, instead of
    /// Blockout's first-at-zero/subsequent-two-second spacing. Capture committed evaluated placement and facing.
    @discardableResult
    func addInspectorMark(for entityID: EntityID) throws -> MarkID {
        guard !isReadOnly else { throw ShotsEditingError.readOnly }
        guard preview.isEmpty else { throw ShotsEditingError.finishCurrentEdit }
        guard let shot = currentShot, let entity = frame?.entities.first(where: { $0.id == entityID }) else {
            throw ShotsEditingError.missing("entity or shot")
        }
        let mark = ActorMark(
            id: newID("mark"), time: FrameGrid.time(ofFrame: playhead), hold: 0, easeIn: 0.2, easeOut: 0.2,
            position: entity.position, gait: .walk, arriveHeading: entity.heading
        )
        try perform(.addActorMark(shot.id, entityID, mark))
        selection = .actorMark(entityID, mark.id)
        tool = .select
        return mark.id
    }
}
