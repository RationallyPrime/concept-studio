@testable import ConceptStudio
import PrevisCore
import Testing

@Suite("Shots document commands")
@MainActor
struct ShotsCommandTests {
    @Test func duplicateShotSharesBlockingAndRenewsOnlyCameraIdentifiers() throws {
        let store = try sampleStore()
        let scene = try #require(store.currentScene)
        let original = try #require(store.currentShot)
        try store.perform(.duplicateShot(original.id, newID: "shot_copy"))
        let copy = try #require(store.currentScene?.shots.last)
        #expect(copy.id == "shot_copy")
        #expect(copy.blockingTakeID == original.blockingTakeID)
        #expect(store.currentScene?.blocking == scene.blocking)
        #expect(Set(copy.camera.marks.map(\.id)).isDisjoint(with: original.camera.marks.map(\.id)))
        var normalized = copy
        normalized.id = original.id
        normalized.camera.marks = zip(copy.camera.marks, original.camera.marks).map { copied, source in
            var mark = copied
            mark.id = source.id
            return mark
        }
        #expect(normalized == original)
        store.undo()
        #expect(store.currentScene == scene)
    }

    @Test func duplicateCommandProducesTheSameDocumentFromTheSameInput() throws {
        let catalog = try ContentCatalog.bundled()
        let original = ShotsSamples.twoPersonWalk()
        let shotID = try #require(original.scenes.first?.shots.first?.id)
        var first = original
        var second = original
        let command = ShotsCommand.duplicateShot(shotID, newID: "deterministic_copy")
        try ShotsCommandApplication.apply(command, to: &first, catalog: catalog)
        try ShotsCommandApplication.apply(command, to: &second, catalog: catalog)
        #expect(first == second)
    }

    @Test func importingAnyConflictingIdentifierIsAtomic() throws {
        let store = try sampleStore()
        let original = store.document
        var scene = try #require(store.currentScene)
        scene.id = "new_scene"
        #expect(throws: ShotsEditingError.self) { try store.perform(.importScenes([scene])) }
        #expect(store.document == original)
        #expect(!store.canUndo)
        let empty = ShotsStore(catalog: store.catalog, document: ShotsDocument(version: 1), saveURL: nil)
        var conflict = scene
        conflict.id = "another_scene"
        #expect(throws: ShotsEditingError.self) { try empty.perform(.importScenes([scene, conflict])) }
        #expect(empty.document.scenes.isEmpty)
        try empty.perform(.importScenes([scene]))
        #expect(empty.currentSceneID == scene.id)
        #expect(empty.currentShotID == scene.shots.first?.id)
    }

    @Test func cameraCommandsAndMarkDeletionAreUndoable() throws {
        let store = try sampleStore()
        let shot = try #require(store.currentShot)
        let entity = try #require(store.currentScene?.entities.first)
        try store.perform(.setCameraRig(shot.id, sensor: .fullFrame, rig: .handheld, intensity: 0.5))
        try store.perform(.setTracking(shot.id, [entity.id]))
        try store.perform(.setMount(shot.id, entity.id))
        #expect(store.currentShot?.camera.sensor == .fullFrame)
        #expect(store.currentShot?.camera.rig == .handheld)
        #expect(store.currentShot?.camera.rigIntensity == 0.5)
        #expect(store.currentShot?.camera.trackIDs == [entity.id])
        #expect(store.currentShot?.camera.mountID == entity.id)
        let mark = try #require(shot.camera.marks.first)
        store.selection = .cameraMark(mark.id)
        let before = store.document
        try store.perform(.deleteMarks(shot.id, [mark.id]))
        #expect(store.currentShot?.camera.marks.contains { $0.id == mark.id } == false)
        #expect(store.selection == .none)
        store.undo()
        #expect(store.document == before)
    }

    @Test func deletingAnEntityCleansReferencesAndUndoRestoresThem() throws {
        var document = ShotsSamples.twoPersonWalk()
        let parent = document.scenes[0].entities[0].id
        let child = document.scenes[0].entities[1].id
        document.scenes[0].entities[1].attachment = EntityAttachment(
            parentID: parent, offset: .zero, rotation: .yaw(0)
        )
        document.scenes[0].blocking[0].tracks[1].marks[0].boardID = parent
        document.scenes[0].shots[0].camera.mountID = parent
        document.scenes[0].shots[0].camera.trackIDs = [parent, child]
        document.scenes[0].shots[0].notes.characters = [
            CharacterNote(entityID: parent, appearance: "Parent"),
            CharacterNote(entityID: child, appearance: "Child"),
        ]
        let store = try ShotsStore(catalog: ContentCatalog.bundled(), document: document, saveURL: nil)
        store.selection = .entities([parent, child])
        try store.perform(.deleteEntities([parent]))
        let scene = try #require(store.currentScene)
        #expect(!scene.entities.contains { $0.id == parent })
        #expect(scene.entities.first { $0.id == child }?.attachment == nil)
        #expect(!scene.blocking[0].tracks.contains { $0.entityID == parent })
        #expect(scene.blocking[0].tracks.flatMap(\.marks).allSatisfy { $0.boardID != parent })
        #expect(scene.shots[0].camera.mountID == nil)
        #expect(scene.shots[0].camera.trackIDs == [child])
        #expect(scene.shots[0].notes.characters.map(\.entityID) == [child])
        #expect(store.selection == .entities([child]))
        store.undo()
        #expect(store.document == document)
    }

    @Test func rejectedGeneratedEditsPreserveTheCommittedDocumentAndHistory() throws {
        let store = try sampleStore()
        let shot = try #require(store.currentShot)
        let actor = try #require(store.currentScene?.entities.first)
        let original = store.document
        let commands: [ShotsCommand] = [
            .applyMotion(shot.id, actor.id, motionID: "missing_motion", atFrame: 24),
            .overlayMotion(shot.id, actor.id, motionID: "missing_motion"),
            .applyActionPath(shot.id, actor.id, pathID: "missing_path", atFrame: 24, duration: 1, speed: nil),
            .applyCameraMove(shot.id, moveID: "missing_move", subjects: [actor.id]),
            .attach(child: "missing_actor", parent: actor.id, shot: shot.id, atFrame: 24),
        ]
        for command in commands {
            #expect(throws: (any Error).self) { try store.perform(command) }
            #expect(store.document == original)
            #expect(!store.canUndo)
            #expect(!store.canRedo)
        }
    }

    private func sampleStore() throws -> ShotsStore {
        try ShotsStore(catalog: ContentCatalog.bundled(), document: ShotsSamples.twoPersonWalk(), saveURL: nil)
    }
}
