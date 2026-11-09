import ConceptCore
@testable import ConceptStudio
import Foundation
import PrevisCore
import ShotsMedia
import Testing

@Suite("Shots help and keyboard action preparation")
@MainActor
struct ShotsHelpAndKeyboardTests {
    @Test func requiredShotsTermsAreSearchableWithoutAProjectAndKeepValidRelatedLinks() {
        let names = [
            "Shots",
            "Scene",
            "Shot",
            "Blocking",
            "Mark",
            "Hold",
            "Gait",
            "Guide frame",
            "Shot package",
            "Frame grid",
            "Canvas",
            "Look-through",
            "Aim lock",
        ]
        let allIDs = Set(StudioGlossaryCatalog.allEntries.map(\.id))
        for name in names {
            let entries = StudioTerm.search(name).filter { $0.title == name }
            #expect(entries.count == 1)
            #expect(entries.first?.entry.sectionId == "using-conceptstudio")
            #expect(entries.allSatisfy { !$0.definition.isEmpty && !$0.technicalDefinition.isEmpty })
            for entry in entries {
                #expect(Set(entry.entry.relatedTerms).isSubset(of: allIDs))
            }
        }
    }

    @Test func libraryButtonCreatesSelectedEntitiesAndInspectorMarkUsesThePlayhead() throws {
        let store = try makeStore()
        let before = store.document
        let first = try store.addLibraryAsset("person.man")
        #expect(store.selection == .entities([first]))
        #expect(store.tool == .select)
        let placement = Placement(position: Vec3(1, 0, 0), heading: 0.7, scale: 1)
        try store.perform(.setPlacement(first, placement))
        store.playhead = 12
        let evaluated = try #require(store.frame?.entities.first { $0.id == first })
        let beforeMark = store.document
        let markID = try store.addInspectorMark(for: first)
        let mark = try #require(store.currentScene?.blocking.first?.tracks.first { $0.entityID == first }?
            .marks.first { $0.id == markID })
        #expect(mark.time == 0.5)
        #expect(mark.position == evaluated.position)
        #expect(mark.arriveHeading == evaluated.heading)
        #expect(store.selection == .actorMark(first, markID))
        store.undo()
        #expect(store.document == beforeMark)
        store.undo()
        store.undo()
        #expect(store.document == before)
        #expect(!store.canUndo)
    }

    @Test func readOnlyAndAnotherEditorsPreviewCannotBeCommittedByKeyboardActions() throws {
        let store = try makeStore()
        let entity = try store.addLibraryAsset("person.man")
        let before = store.document
        let preview = ShotsCommand.setPlacement(entity, Placement(position: Vec3(9, 0, 0), heading: 0, scale: 1))
        store.preview = [preview]
        #expect(throws: ShotsEditingError.self) { _ = try store.addInspectorMark(for: entity) }
        #expect(throws: ShotsEditingError.self) { _ = try store.addLibraryAsset("person.woman") }
        #expect(store.preview == [preview])
        #expect(store.document == before)
        let readOnly = ShotsStore(catalog: store.catalog, document: before, saveURL: nil, readOnly: true)
        #expect(throws: ShotsEditingError.self) { _ = try readOnly.addLibraryAsset("person.man") }
        #expect(throws: ShotsEditingError.self) { _ = try readOnly.addInspectorMark(for: entity) }
        #expect(readOnly.document == before)
    }

    /// The keyboard-only path written down in `docs/shots/status/lane-c.md`, step for step, through the same store
    /// actions the controls call: the library's Add button, the X and Z inspector fields (coalesced placement edits),
    /// the focused timeline's End key, Add mark here, Undo/Redo, then the exporter that Export shot package calls.
    @Test(.enabled(if: ShotFrameRenderer.isAvailable))
    func keyboardActionModelAddsMovesMarksUndoesRedoesAndExportsAValidPackage() async throws {
        let store = try makeStore()
        let shotID = try #require(store.currentShotID)
        try store.perform(.setFrameCount(shotID, 22))
        try store.perform(.setCanvas(shotID, ShotCanvas(width: 320, height: 576)))
        try store.perform(.setGuideFrames(shotID, [11]))
        let entity = try store.addLibraryAsset("person.man")
        let added = store.document
        let start = try #require(store.currentScene?.entities.first { $0.id == entity }?.placement)
        #expect(start.position == .zero)
        var moved = start
        moved.position.x = 1.5
        store.run(.setPlacement(entity, moved), coalescing: true)
        moved.position.z = -2
        store.run(.setPlacement(entity, moved), coalescing: true)
        #expect(store.currentScene?.entities.first { $0.id == entity }?.placement.position == Vec3(1.5, 0, -2))
        let afterMove = store.document
        #expect(store.navigateTimeline(.end, focused: true, editingText: false))
        #expect(store.playhead == 21)
        let markID = try store.addInspectorMark(for: entity)
        let mark = try #require(store.currentScene?.blocking.first?.tracks.first { $0.entityID == entity }?
            .marks.first { $0.id == markID })
        #expect(mark.time == FrameGrid.time(ofFrame: 21))
        #expect(mark.position == Vec3(1.5, 0, -2))
        let expected = store.document
        store.undo()
        #expect(store.document == afterMove)
        store.redo()
        #expect(store.document == expected)
        // Field edits coalesce within 800 ms; under load they may be two steps, so undo by state, not by count.
        while store.document != added, store.canUndo {
            store.undo()
        }
        #expect(store.document == added)
        while store.document != expected, store.canRedo {
            store.redo()
        }
        #expect(store.document == expected)
        let snapshot = try store.exportSnapshot()
        let destination = temporaryTestDirectory("Shots-keyboard-action-model")
        defer { try? FileManager.default.removeItem(at: destination) }
        let exporter = try ShotExporter(catalog: store.catalog)
        let package = try await exporter.export(
            scene: snapshot.scene, shotID: snapshot.shotID, options: .standard,
            to: FolderDestination(parent: destination)
        ) { _ in }
        #expect(package.manifest.frameCount == 22)
        #expect(package.manifest.canvas == ShotCanvas(width: 320, height: 576))
        #expect(package.manifest.shot.id == shotID)
        let problems = await PackageValidator.problems(at: package.url)
        #expect(problems.isEmpty)
        // This covers the action model. No native key events, focus traversal or VoiceOver are exercised here.
    }

    private func makeStore() throws -> ShotsStore {
        try ShotsStore(catalog: ContentCatalog.bundled(), document: ShotsDocument(
            version: ShotsDocument.currentVersion,
            scenes: [PrevisScene.make(
                id: "scene",
                name: "Keyboard stage",
                takeID: "take",
                shotID: "shot",
                cameraMarkID: "camera"
            )]
        ), saveURL: nil)
    }
}
