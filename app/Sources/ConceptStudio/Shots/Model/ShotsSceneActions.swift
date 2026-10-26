import Foundation
import PrevisCore

extension ShotsStore {
    /// An export uses committed values even while a drag has a transient preview.
    func exportSnapshot() throws -> (scene: PrevisScene, shotID: ShotID) {
        guard let currentShotID,
              let scene = document.scenes.first(where: { $0.shots.contains { $0.id == currentShotID } }) else {
            throw ShotsEditingError.missing("shot")
        }
        return (scene, currentShotID)
    }

    func selectShot(_ id: ShotID?) {
        guard let id,
              let scene = document.scenes.first(where: { $0.shots.contains { $0.id == id } }) else { return }
        preview = nil
        selection = .none
        currentSceneID = scene.id
        currentShotID = id
        // Blockout src/renderer/store.ts selectShot, pinned at 3f2d0564, starts a selected shot at time zero.
        playhead = 0
    }

    @discardableResult
    func createScene() throws -> SceneID {
        let id = newID("scene"), shot = newID("shot")
        try perform(.addScene(
            id: id, name: "New scene", takeID: newID("take"), shotID: shot, cameraMarkID: newID("camera")
        ))
        selectShot(shot)
        return id
    }

    @discardableResult
    func createShot(in sceneID: SceneID) throws -> ShotID {
        let id = newID("shot")
        try perform(.addShot(sceneID, id: id, name: "New shot", cameraMarkID: newID("camera")))
        selectShot(id)
        return id
    }

    @discardableResult
    func copyScene(_ id: SceneID) throws -> SceneID {
        guard let scene = document.scenes.first(where: { $0.id == id }) else {
            throw ShotsEditingError.missing("scene")
        }
        let copy = ShotsSceneCopy.duplicate(scene)
        try perform(.importScenes([copy]))
        if let shot = copy.shots.first { selectShot(shot.id) } else {
            preview = nil
            selection = .none
            currentSceneID = copy.id
            currentShotID = nil
        }
        return copy.id
    }

    @discardableResult
    func copyShot(_ id: ShotID) throws -> ShotID {
        let copyID = newID("shot")
        try perform(.duplicateShot(id, newID: copyID))
        selectShot(copyID)
        return copyID
    }

    func importBlockoutProject(_ data: Data) throws -> [String] {
        let imported = try BlockoutImport.document(fromProjectJSON: data, catalog: catalog)
        try perform(.importScenes(imported.document.scenes))
        if let firstShot = imported.document.scenes.lazy.flatMap(\.shots).first {
            selectShot(firstShot.id)
        } else if let scene = imported.document.scenes.first {
            preview = nil
            selection = .none
            currentSceneID = scene.id
            currentShotID = nil
        }
        return imported.notes
    }
}
