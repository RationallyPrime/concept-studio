@testable import ConceptStudio
import PrevisCore
import Testing

@Suite("Shots C5 review regressions")
@MainActor
struct ShotsInspectorReviewTests {
    @Test func typingAnEntityNameCoalescesWithoutEvictingEarlierHistory() throws {
        let store = try makeStore()
        let before = store.document
        let scene = try #require(store.currentScene)
        let entity = try #require(scene.entities.first)
        try store.perform(.setLighting(scene.id, .night))
        let earlierEdit = store.document
        for length in 1 ... 240 {
            try store.perform(.renameEntity(entity.id, name: String(repeating: "n", count: length)), coalescing: true)
        }
        store.undo()
        #expect(store.document == earlierEdit)
        store.undo()
        #expect(store.document == before)
        #expect(!store.canUndo)
    }

    @Test func renameTargetsAndExplicitNonCoalescingRemainSeparateSteps() throws {
        let store = try makeStore()
        let scene = try #require(store.currentScene)
        let first = try #require(scene.entities.first)
        let second = try #require(scene.entities.last)
        try store.perform(.renameEntity(first.id, name: "One"), coalescing: true)
        let one = store.document
        try store.perform(.renameEntity(second.id, name: "Two"), coalescing: true)
        store.undo()
        #expect(store.document == one)
        try store.perform(.renameEntity(first.id, name: "Three"))
        let three = store.document
        try store.perform(.renameEntity(first.id, name: "Four"))
        store.undo()
        #expect(store.document == three)
    }

    @Test func undoDuringSliderDragInvalidatesReleaseAndFurtherMovement() throws {
        for movesAfterUndo in [false, true] {
            let store = try makeStore()
            let before = store.document
            let shot = try #require(store.currentShot)
            try store.perform(.setCameraRig(shot.id, sensor: .fullFrame, rig: .handheld, intensity: 0.1))
            var gesture = ShotsInspectorGesture()
            gesture.preview(.setCameraRig(shot.id, sensor: .fullFrame, rig: .handheld, intensity: 0.8), in: store)
            store.undo()
            if movesAfterUndo {
                gesture.preview(.setCameraRig(shot.id, sensor: .fullFrame, rig: .handheld, intensity: 0.9), in: store)
            }
            gesture.commit(in: store)
            #expect(store.document == before)
            #expect(store.preview == nil)
            #expect(!store.canUndo)
            #expect(store.canRedo)
        }
    }

    @Test func redoOrAnotherPreviewCannotBeOverwrittenByStaleRelease() throws {
        let store = try makeStore()
        let scene = try #require(store.currentScene)
        let shot = try #require(store.currentShot)
        let entity = try #require(scene.entities.first)
        try store.perform(.setLighting(scene.id, .night))
        let redone = store.document
        store.undo()
        var gesture = ShotsInspectorGesture()
        gesture.preview(.setCameraRig(shot.id, sensor: .fullFrame, rig: .handheld, intensity: 0.8), in: store)
        store.redo()
        gesture.commit(in: store)
        #expect(store.document == redone)
        let replacement = ShotsCommand.setPlacement(entity.id, Placement(position: Vec3(4, 0, 1), heading: 0, scale: 1))
        gesture.preview(.setCameraRig(shot.id, sensor: .fullFrame, rig: .handheld, intensity: 0.6), in: store)
        store.preview = replacement
        gesture.invalidateIfNeeded(in: store)
        gesture.commit(in: store)
        #expect(store.preview == replacement)
        #expect(store.document == redone)
        store.preview = nil
        store.undo()
        #expect(!store.canUndo)
    }

    @Test func realSliderLifecycleCommitsOneEditAndCancellationKeepsTheNextDragUsable() throws {
        let store = try makeStore()
        let before = store.document
        let shot = try #require(store.currentShot)
        var gesture = ShotsInspectorGesture()
        for intensity in [0.2, 0.4, 0.6] {
            gesture.preview(.setCameraRig(shot.id, sensor: .super35, rig: .handheld, intensity: intensity), in: store)
        }
        #expect(store.document == before)
        gesture.commit(in: store)
        #expect(store.currentShot?.camera.rigIntensity == 0.6)
        store.undo()
        #expect(store.document == before)
        #expect(!store.canUndo)
        gesture.preview(.setCameraRig(shot.id, sensor: .super35, rig: .handheld, intensity: 0.8), in: store)
        gesture.cancel(in: store)
        gesture.preview(.setCameraRig(shot.id, sensor: .super35, rig: .handheld, intensity: 0.9), in: store)
        gesture.commit(in: store)
        #expect(store.document == before)
        #expect(store.preview == nil)
        gesture.preview(.setCameraRig(shot.id, sensor: .super35, rig: .handheld, intensity: 0.3), in: store)
        gesture.commit(in: store)
        #expect(store.currentShot?.camera.rigIntensity == 0.3)
    }

    private func makeStore() throws -> ShotsStore {
        try ShotsStore(catalog: ContentCatalog.bundled(), document: ShotsSamples.twoPersonWalk(), saveURL: nil)
    }
}
