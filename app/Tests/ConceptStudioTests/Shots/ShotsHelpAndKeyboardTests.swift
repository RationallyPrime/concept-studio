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
        store.preview = preview
        #expect(throws: ShotsEditingError.self) { _ = try store.addInspectorMark(for: entity) }
        #expect(throws: ShotsEditingError.self) { _ = try store.addLibraryAsset("person.woman") }
        #expect(store.preview == preview)
        #expect(store.document == before)
        let readOnly = ShotsStore(catalog: store.catalog, document: before, saveURL: nil, readOnly: true)
        #expect(throws: ShotsEditingError.self) { _ = try readOnly.addLibraryAsset("person.man") }
        #expect(throws: ShotsEditingError.self) { _ = try readOnly.addInspectorMark(for: entity) }
        #expect(readOnly.document == before)
    }

    @Test(.enabled(if: ShotFrameRenderer.isAvailable))
    func keyboardActionModelAddsMovesMarksUndoesRedoesAndExportsAValidPackage() async throws {
        let store = try makeStore()
        let entity = try store.addLibraryAsset("person.man")
        try store.perform(.setPlacement(entity, Placement(position: Vec3(1, 0, 0), heading: 0.3, scale: 1)))
        store.playhead = 0
        _ = try store.addInspectorMark(for: entity)
        let expected = store.document
        store.undo()
        store.redo()
        #expect(store.document == expected)
        let shotID = try #require(store.currentShotID)
        try store.perform(.setFrameCount(shotID, 22))
        try store.perform(.setCanvas(shotID, ShotCanvas(width: 320, height: 576)))
        try store.perform(.setGuideFrames(shotID, [11]))
        let snapshot = try store.exportSnapshot()
        let destination = temporaryTestDirectory("Shots-keyboard-action-model")
        defer { try? FileManager.default.removeItem(at: destination) }
        let exporter = try ShotExporter(catalog: store.catalog)
        let package = try await exporter.export(
            scene: snapshot.scene, shotID: snapshot.shotID, options: .standard,
            to: FolderDestination(parent: destination)
        ) { _ in }
        #expect(package.manifest.frameCount == 22)
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
