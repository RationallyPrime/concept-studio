@testable import ConceptStudio
import PrevisCore
import Testing

@Suite("Shots timeline navigation boundaries")
@MainActor
struct ShotsTimelineNavigationTests {
    @Test func automaticEndpointGuidesCannotBePersistedAsExtraGuides() throws {
        let store = try makeStore()
        let shot = try #require(store.currentShot)
        let before = store.document
        for endpoint in [0, shot.frameCount - 1] {
            store.playhead = endpoint
            #expect(!store.canAddGuideAtPlayhead)
            store.addGuideAtPlayhead()
            #expect(store.document == before)
            #expect(!store.canUndo)
        }
        store.playhead = 1
        #expect(store.canAddGuideAtPlayhead)
        store.addGuideAtPlayhead()
        #expect(!store.canAddGuideAtPlayhead)
        store.addGuideAtPlayhead()
        store.undo()
        #expect(store.document == before)
        #expect(!store.canUndo)
    }

    @Test func viewportFocusAndTextEditingLeavePlayheadSelectionAndHistoryAlone() throws {
        let store = try makeStore()
        let scene = try #require(store.currentScene)
        let shot = try #require(store.currentShot)
        store.playhead = 12
        store.selection = .entities([scene.entities[0].id])
        store.isPlaying = true
        let before = store.document
        for key in [ShotsTimelineKey.backward, .forward, .home, .end, .delete] {
            #expect(!store.navigateTimeline(key, focused: false, editingText: false))
            #expect(!store.navigateTimeline(key, focused: true, editingText: true))
        }
        store.toggleShotsPlayback(editingText: true)
        #expect(store.playhead == 12)
        #expect(store.currentShotID == shot.id)
        #expect(store.selection == .entities([scene.entities[0].id]))
        #expect(store.isPlaying)
        #expect(store.document == before)
        #expect(!store.canUndo)
    }

    @Test func steppingClampsAndGuidesAreOneUndoableDocumentEdit() throws {
        let store = try makeStore()
        let before = store.document
        #expect(store.navigateTimeline(.forward, focused: true, editingText: false, shift: true))
        #expect(store.playhead == 24)
        store.addGuideAtPlayhead()
        store.addGuideAtPlayhead()
        #expect(store.currentShot?.guideFrames.filter { $0 == 24 }.count == 1)
        store.undo()
        #expect(store.document == before)
        #expect(!store.canUndo)
        #expect(store.navigateTimeline(.home, focused: true, editingText: false))
        #expect(store.navigateTimeline(.backward, focused: true, editingText: false))
        #expect(store.playhead == 0)
        #expect(store.navigateTimeline(.end, focused: true, editingText: false))
        let last = store.playhead
        #expect(store.navigateTimeline(.forward, focused: true, editingText: false))
        #expect(store.playhead == last)
        store.toggleShotsPlayback()
        #expect(store.playhead == 0)
        #expect(store.isPlaying)
    }

    private func makeStore() throws -> ShotsStore {
        try ShotsStore(catalog: ContentCatalog.bundled(), document: ShotsSamples.twoPersonWalk(), saveURL: nil)
    }
}
