@testable import ConceptStudio
import PrevisCore
import Testing

@Suite("Shots asset library placement boundaries")
@MainActor
struct ShotsAssetLibraryTests {
    @Test func armingSwitchingAndCancellingDoNotEditTheDocumentOrUndoHistory() throws {
        let catalog = try ContentCatalog.bundled()
        let store = ShotsStore(catalog: catalog, document: ShotsSamples.twoPersonWalk(), saveURL: nil)
        let before = store.document
        store.chooseAssetForPlacement("person.man")
        #expect(store.tool == .place(assetID: "person.man"))
        store.chooseAssetForPlacement("person.woman")
        #expect(store.tool == .place(assetID: "person.woman"))
        store.chooseAssetForPlacement("person.woman")
        #expect(store.tool == .select)
        #expect(store.document == before)
        #expect(!store.canUndo)
        #expect(store.preview.isEmpty)
    }

    @Test func onlyKnownStarterAssetsCanBeArmedInAnEditableShot() throws {
        let catalog = try ContentCatalog.bundled()
        let document = ShotsSamples.twoPersonWalk()
        let store = ShotsStore(catalog: catalog, document: document, saveURL: nil)
        store.chooseAssetForPlacement("missing.asset")
        #expect(store.tool == .select)
        store.currentShotID = nil
        store.chooseAssetForPlacement("person.man")
        #expect(store.tool == .select)
        let readOnly = ShotsStore(catalog: catalog, document: document, saveURL: nil, readOnly: true)
        readOnly.chooseAssetForPlacement("person.man")
        #expect(readOnly.tool == .select)
        #expect(readOnly.document == document)
    }

    @Test func sevenFormationsAndANamedDepartureUseTheAppCommands() throws {
        let catalog = try ContentCatalog.bundled()
        let store = ShotsStore(catalog: catalog, document: ShotsSamples.twoPersonWalk(), saveURL: nil)
        let squads = try (0 ..< 7).map { index in
            let id = try store.addLibraryAsset("person.man", asFormation: true)
            let placement = Placement(position: Vec3(Double(index) * 8, 0, 0), heading: 0, scale: 1)
            try store.perform(.setPlacement(id, placement))
            _ = try store.addInspectorMark(for: id)
            return id
        }
        let squad = try #require(squads.first)
        let slot = FormationSlot(formationID: squad, row: 2, column: 3)
        try store.addNamedMember(slot, assetID: "person.woman", name: "Cadet")
        let member = try #require(store.currentScene?.entities.last)
        #expect(store.selection == .entities([member.id]))
        let before = try #require(store.frame)
        #expect(before.entities.filter { squads.contains($0.id) }.count == 7)
        #expect(before.entities.flatMap(\.formationPoses).count == 146)
        let position = try #require(before.entities.first { $0.id == member.id }?.position)
        _ = try store.addInspectorMark(for: member.id)
        let released = try #require(store.frame?.entities.first { $0.id == member.id })
        #expect(released.position == position)
        #expect(released.formationID == nil)
        store.undo()
        #expect(store.frame?.entities.first { $0.id == member.id }?.formationID == squad)
    }

    @Test func filteringRetainsStarterOrderAndMatchesNameOrCategoryIgnoringCaseAndOuterSpaces() throws {
        let catalog = try ContentCatalog.bundled()
        let store = ShotsStore(catalog: catalog, document: ShotsSamples.twoPersonWalk(), saveURL: nil)
        #expect(store.libraryAssets(matching: "").map(\.id)
            == catalog.assets.filter { catalog.starter.assets.contains($0.id) }.map(\.id))
        let name = try #require(catalog.assets.first { $0.id == "person.man" })
        #expect(store.libraryAssets(matching: "  \(name.name.uppercased())  ").contains { $0.id == name.id })
        let group = store.libraryAssets(matching: name.category.uppercased())
        #expect(group.contains { $0.id == name.id })
        #expect(group.allSatisfy { catalog.starter.assets.contains($0.id) })
        #expect(store.libraryAssets(matching: "no such starter asset").isEmpty)
    }
}
