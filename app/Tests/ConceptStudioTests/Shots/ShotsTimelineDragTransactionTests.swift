@testable import ConceptStudio
import PrevisCore
import Testing

@Suite("Shots pointer drag lifecycle")
@MainActor
struct ShotsTimelineDragTransactionTests {
    @Test func escapeThenMoreMovementAndReleaseCannotCommitOrCreateHistory() throws {
        let store = try ShotsStore(
            catalog: ContentCatalog.bundled(), document: ShotsSamples.twoPersonWalk(), saveURL: nil
        )
        let shot = try #require(store.currentShot)
        let mark = try #require(shot.camera.marks.first)
        let before = store.document
        let source = ShotsTimelineDrag.Mark.camera(shot.id, mark)
        let geometry = ShotsTimelineGeometry(frameCount: shot.frameCount, width: 600)
        var transaction = ShotsTimelineDragTransaction()
        store.preview = transaction.update(mark: source, mode: .move, geometry: geometry, delta: 40)
        #expect(transaction.isActive)
        #expect(store.preview != nil)
        transaction.cancel()
        store.preview = nil
        // The SAME gesture emits more movement after Escape, then releases.
        let resumed = transaction.update(mark: source, mode: .move, geometry: geometry, delta: 80)
        #expect(resumed == nil)
        let cancelledEnd = transaction.finish(delta: 80)
        if let cancelledEnd { try store.perform(cancelledEnd) }
        #expect(cancelledEnd == nil)
        #expect(store.preview == nil)
        #expect(store.document == before)
        #expect(!store.canUndo)
        // A new pointer gesture is allowed after release and commits exactly once.
        _ = transaction.update(mark: source, mode: .move, geometry: geometry, delta: 20)
        let nextEnd = transaction.finish(delta: 20)
        try store.perform(#require(nextEnd))
        #expect(store.document != before)
        store.undo()
        #expect(store.document == before)
        #expect(!store.canUndo)
    }

    @Test func anAbandonedGestureResetsWithoutLeavingTheNextGestureCancelled() throws {
        let document = ShotsSamples.twoPersonWalk()
        let shot = try #require(document.scenes.first?.shots.first)
        let mark = try #require(shot.camera.marks.first)
        let source = ShotsTimelineDrag.Mark.camera(shot.id, mark)
        let geometry = ShotsTimelineGeometry(frameCount: shot.frameCount, width: 600)
        var transaction = ShotsTimelineDragTransaction()
        _ = transaction.update(mark: source, mode: .stretch, geometry: geometry, delta: 20)
        transaction.cancel()
        transaction.reset() // SwiftUI GestureState ended/cancelled, including a removed mark view.
        let next = transaction.update(mark: source, mode: .stretch, geometry: geometry, delta: 40)
        let finished = transaction.finish(delta: 40)
        #expect(next != nil)
        #expect(finished != nil)
    }
}
