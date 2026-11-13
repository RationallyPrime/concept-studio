import PrevisCore

enum ShotsCommand: Codable, Sendable, Equatable {
    case addScene(id: SceneID, name: String, takeID: TakeID, shotID: ShotID, cameraMarkID: MarkID)
    case renameScene(SceneID, name: String)
    case deleteScene(SceneID)
    case setLighting(SceneID, LightingPreset)
    case addShot(SceneID, id: ShotID, name: String, cameraMarkID: MarkID)
    case duplicateShot(ShotID, newID: ShotID)
    case renameShot(ShotID, name: String)
    case deleteShot(ShotID)
    case setFrameCount(ShotID, Int)
    case setCanvas(ShotID, ShotCanvas)
    case setGuideFrames(ShotID, [Int])
    case setNotes(ShotID, ShotNotes)
    case setPrompt(ShotID, ShotPrompt?)
    case importScenes([PrevisScene])

    case addEntity(SceneID, PrevisEntity)
    case setPlacement(EntityID, Placement)
    case renameEntity(EntityID, name: String)
    case setLabel(EntityID, EntityLabel?)
    case deleteEntities([EntityID])
    case attach(child: EntityID, parent: EntityID?, shot: ShotID, atFrame: Int)

    case addActorMark(ShotID, EntityID, ActorMark)
    case updateActorMark(ShotID, EntityID, ActorMark)
    case applyMotion(ShotID, EntityID, motionID: String, atFrame: Int)
    case overlayMotion(ShotID, EntityID, motionID: String)
    case applyActionPath(ShotID, EntityID, pathID: String, atFrame: Int, duration: Double, speed: Double?)

    case setCameraRig(ShotID, sensor: Sensor, rig: Rig, intensity: Double)
    case setTracking(ShotID, [EntityID])
    case setMount(ShotID, EntityID?)
    case addCameraMark(ShotID, CameraMark)
    case updateCameraMark(ShotID, CameraMark)
    case applyCameraMove(ShotID, moveID: String, subjects: [EntityID])
    case applyFraming(ShotID, Framing.Kind, subjects: [EntityID], atFrame: Int)

    case deleteMarks(ShotID, [MarkID])

    // Plates and set pieces (CONTRACTS section 7)
    case addPlate(SceneID, LocationPlate)
    case updatePlate(SceneID, LocationPlate) // matched by id; every shot on the plate follows its camera
    case deletePlate(SceneID, PlateID) // shots on it go back to the grey stage
    case setShotPlate(ShotID, PlateID?) // puts the shot's first camera mark on the plate's camera
    case setKeyCanvas(ShotID, ShotCanvas?) // nil = the plate's own size
    case setAsks(ShotID, [FramingAsk])
    case setSetPiece(EntityID, SetPiece) // size, steps and whether the plate shows it; the kind stays
    case replaceScene(PrevisScene) // a scene blocked from a description, as one step; matched by id
    case giveOwnBlocking(ShotID, takeID: TakeID) // the shot stops sharing its blocking with the scene's others
}
