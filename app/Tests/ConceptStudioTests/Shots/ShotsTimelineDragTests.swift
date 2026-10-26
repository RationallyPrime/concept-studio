@testable import ConceptStudio
import PrevisCore
import Testing

@Suite("Shots timeline drag transactions")
@MainActor
struct ShotsTimelineDragTests {
    @Test func stretchingAnActorPreviewsWithoutSavingAndCommitsOneUndoStep() throws {
        let store = try ShotsStore(
            catalog: ContentCatalog.bundled(), document: ShotsSamples.twoPersonWalk(), saveURL: nil
        )
        let scene = try #require(store.currentScene)
        let shot = try #require(store.currentShot)
        let track = try #require(scene.blocking.first { $0.id == shot.blockingTakeID }?.tracks.first)
        let original = try #require(track.marks.first)
        let before = store.document
        let drag = ShotsTimelineDrag(
            mark: .actor(shot.id, track.entityID, original), mode: .stretch,
            geometry: ShotsTimelineGeometry(frameCount: shot.frameCount, width: 600)
        )
        store.preview = drag.command(delta: 30)
        store.preview = drag.command(delta: 60)
        #expect(store.document == before)
        #expect(!store.canUndo)
        guard case let .updateActorMark(_, _, changed) = store.preview else {
            Issue.record("Actor drag must preview one updateActorMark")
            return
        }
        var expected = original
        expected.hold = changed.hold
        #expect(changed == expected)
        #expect(changed.hold > original.hold)
        try store.perform(drag.command(delta: 60))
        #expect(store.preview == nil)
        #expect(store.document != before)
        store.undo()
        #expect(store.document == before)
        #expect(!store.canUndo)
    }

    @Test func cameraRetimePreservesEveryOtherChannelAndCancellationLeavesNoHistory() throws {
        let store = try ShotsStore(
            catalog: ContentCatalog.bundled(), document: ShotsSamples.twoPersonWalk(), saveURL: nil
        )
        let shot = try #require(store.currentShot)
        let original = try #require(shot.camera.marks.first)
        let before = store.document
        let drag = ShotsTimelineDrag(
            mark: .camera(shot.id, original), mode: .move,
            geometry: ShotsTimelineGeometry(frameCount: shot.frameCount, width: 600)
        )
        let command = drag.command(delta: 120)
        guard case let .updateCameraMark(id, changed) = command else {
            Issue.record("Camera drag must produce one updateCameraMark")
            return
        }
        var expected = original
        expected.time = changed.time
        #expect(id == shot.id)
        #expect(changed == expected)
        #expect(changed.time > original.time)
        store.preview = command
        store.preview = nil
        #expect(store.document == before)
        #expect(!store.canUndo)
        #expect(drag.command(delta: 120) == command)
    }
}
