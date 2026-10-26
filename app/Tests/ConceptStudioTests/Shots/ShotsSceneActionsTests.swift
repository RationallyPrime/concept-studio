@testable import ConceptStudio
import Foundation
import PrevisCore
import Testing

@Suite("Shots scene and import actions")
@MainActor
struct ShotsSceneActionsTests {
    @Test func exportCapturesCommittedShotRatherThanTransientPreviewOrLaterEdits() throws {
        let store = try makeStore(ShotsSamples.twoPersonWalk())
        let shot = try #require(store.currentShot)
        let committed = try #require(store.currentScene)
        store.preview = .setFrameCount(shot.id, 22)
        #expect(store.currentShot?.frameCount == 22)
        let snapshot = try store.exportSnapshot()
        #expect(snapshot.scene == committed)
        #expect(snapshot.shotID == shot.id)
        try store.perform(.renameShot(shot.id, name: "A later edit"))
        #expect(snapshot.scene == committed)
        #expect(snapshot.scene != store.currentScene)
    }

    @Test func newAndCopiedShotsSelectTheirSceneAndUndoAsWholeEdits() throws {
        let store = try makeStore(ShotsDocument(version: 1))
        let sceneID = try store.createScene()
        let shotID = try store.createShot(in: sceneID)
        let before = store.document
        let original = try #require(store.currentShot)
        let copyID = try store.copyShot(shotID)
        #expect(store.currentSceneID == sceneID)
        #expect(store.currentShotID == copyID)
        #expect(store.currentShot?.blockingTakeID == original.blockingTakeID)
        #expect(store.currentShot?.camera.marks.first?.id != original.camera.marks.first?.id)
        store.undo()
        #expect(store.document == before)
        store.redo()
        #expect(store.currentScene?.shots.contains { $0.id == copyID } == true)
    }

    @Test func copiedSceneKeepsItsOwnReferencesAndLeavesTheOriginalIntact() throws {
        var source = try #require(ShotsSamples.twoPersonWalk().scenes.first)
        let first = source.entities[0].id, second = source.entities[1].id
        var mount = source.entities[1]
        mount.id = "copy_mount"
        let mountIndex = source.entities.count
        source.entities.append(mount)
        source.entities[1].attachment = EntityAttachment(parentID: mount.id, offset: .zero, rotation: .identity)
        source.blocking[0].tracks[0].marks[0].boardID = mount.id
        source.shots[0].camera.mountID = first
        source.shots[0].camera.trackIDs = [first, second]
        source.shots[0].notes.characters = [CharacterNote(entityID: second, appearance: "A blue coat")]
        let original = source
        let copy = ShotsSceneCopy.duplicate(source)
        let copiedFirst = copy.entities[0].id, copiedSecond = copy.entities[1].id
        let copiedMount = copy.entities[mountIndex].id
        #expect(copy.id != source.id)
        #expect(copy.name == source.name + " copy")
        #expect(Set(copy.entities.map(\.id)).isDisjoint(with: source.entities.map(\.id)))
        #expect(copy.entities[1].attachment?.parentID == copiedMount)
        #expect(copy.blocking[0].id != source.blocking[0].id)
        #expect(copy.blocking[0].tracks[0].entityID == copiedFirst)
        #expect(copy.blocking[0].tracks[0].marks[0].boardID == copiedMount)
        #expect(copy.blocking[0].tracks[0].marks[0].id != source.blocking[0].tracks[0].marks[0].id)
        #expect(copy.shots[0].blockingTakeID == copy.blocking[0].id)
        #expect(copy.shots[0].camera.mountID == copiedFirst)
        #expect(copy.shots[0].camera.trackIDs == [copiedFirst, copiedSecond])
        #expect(copy.shots[0].notes.characters[0].entityID == copiedSecond)
        #expect(copy.shots[0].camera.marks[0].id != source.shots[0].camera.marks[0].id)
        #expect(source == original)
    }

    @Test func duplicateSceneAppendsOneIndependentGraphAndUndoRestoresTheDocument() throws {
        let store = try makeStore(ShotsSamples.twoPersonWalk())
        let before = store.document
        let source = try #require(store.currentScene)
        let copyID = try store.copyScene(source.id)
        let copy = try #require(store.currentScene)
        #expect(copy.id == copyID)
        #expect(store.document.scenes.count == before.scenes.count + 1)
        #expect(store.document.scenes.first == source)
        #expect(store.currentShotID == copy.shots.first?.id)
        #expect(copy.revision == source.revision + 1)
        store.undo()
        #expect(store.document == before)
    }

    @Test func importingTheRealBlockoutSampleAddsScenesNotesAndOneUndoStep() throws {
        let store = try makeStore(ShotsSamples.twoPersonWalk())
        let before = store.document
        let data = ShotsSamples.blockoutProjectJSON()
        let expected = try BlockoutImport.document(fromProjectJSON: data, catalog: store.catalog)
        let notes = try store.importBlockoutProject(data)
        #expect(notes == expected.notes)
        #expect(store.document.scenes.count == before.scenes.count + expected.document.scenes.count)
        #expect(!before.scenes.contains { $0.id == store.currentSceneID })
        #expect(store.currentScene?.shots.contains { $0.id == store.currentShotID } == true)
        store.undo()
        #expect(store.document == before)
        #expect(!store.canUndo)
    }

    @Test func invalidImportPreservesTheCurrentEditingContext() throws {
        let store = try makeStore(ShotsSamples.twoPersonWalk())
        let before = store.document
        let scene = try #require(store.currentScene)
        let shot = store.currentShotID
        store.preview = .renameScene(scene.id, name: "Uncommitted")
        store.selection = .entities([scene.entities[0].id])
        let preview = store.preview, selection = store.selection
        #expect(throws: (any Error).self) { try store.importBlockoutProject(Data("not JSON".utf8)) }
        #expect(store.document == before)
        #expect(store.currentShotID == shot)
        #expect(store.preview == preview)
        #expect(store.selection == selection)
    }

    private func makeStore(_ document: ShotsDocument) throws -> ShotsStore {
        try ShotsStore(catalog: ContentCatalog.bundled(), document: document, saveURL: nil)
    }
}
