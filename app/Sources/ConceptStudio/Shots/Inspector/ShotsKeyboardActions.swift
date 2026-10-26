import PrevisCore

extension ShotsStore {
    /// Blockout store.ts:498ff supplies asset/name/selection semantics. The keyboard alternative adds at the stage
    /// origin; Lane D still owns click-to-place. Position can then be edited through the inspector fields.
    @discardableResult
    func addLibraryAsset(_ assetID: String) throws -> EntityID {
        guard !isReadOnly else { throw ShotsEditingError.readOnly }
        guard let scene = currentScene, currentShot != nil else { throw ShotsEditingError.missing("shot") }
        guard preview == nil else { throw ShotsEditingError.finishCurrentEdit }
        guard let asset = catalog.asset(assetID), catalog.starter.assets.contains(assetID) else {
            throw ShotsError.unknownContent(assetID)
        }
        let count = scene.entities.filter { $0.assetID == assetID }.count
        let entity = PrevisEntity(
            id: newID("entity"), assetID: assetID, name: count == 0 ? asset.name : "\(asset.name) \(count + 1)",
            placement: Placement(position: .zero, heading: 0, scale: 1)
        )
        try perform(.addEntity(scene.id, entity))
        selection = .entities([entity.id])
        tool = .select
        return entity.id
    }

    /// Blockout store.ts:537ff creates a walk mark. LANE-D-VIEWPORT D3 deliberately uses the playhead, instead of
    /// Blockout's first-at-zero/subsequent-two-second spacing. Capture committed evaluated placement and facing.
    @discardableResult
    func addInspectorMark(for entityID: EntityID) throws -> MarkID {
        guard !isReadOnly else { throw ShotsEditingError.readOnly }
        guard preview == nil else { throw ShotsEditingError.finishCurrentEdit }
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
