@testable import ConceptStudio
import Foundation
import PrevisCore
import RealityKit
import Testing

/// The D4 handle on an actor that has marks (owner ruling 2026-11-09, follow Blockout): it sits on the body drawn at
/// the playhead, and a drag moves the actor's whole blocking with it, previewed live and committed as one undo step
/// (Blockout `SceneManager.ts:1060, 1131-1149, 1171-1277`). A prop without marks still edits only its placement.
@MainActor
@Suite("Viewport D4 handle on an actor with marks")
struct ViewportBlockedActorHandleTests {
    private let man: EntityID = "ent_000000000001"
    private let chair: EntityID = "ent_000000000003"
    private let camera = EditorCamera.defaultView
    private let size = PixelSize(width: 640, height: 480)

    /// The small two-person walk at frame 11, the Man selected, with a `via` waypoint on his second mark.
    private func blockedManStore() throws -> ShotsStore {
        var document = ShotsSamples.twoPersonWalk(small: true)
        document.scenes[0].blocking[0].tracks[0].marks[1].via = [Vec3(-0.8, 0, 0.3)]
        let store = try ShotsStore(catalog: ContentCatalog.bundled(), document: document, saveURL: nil)
        store.playhead = 11
        store.selection = .entities([man])
        return store
    }

    private func body(_ id: EntityID, in store: ShotsStore) throws -> EntityFrame {
        try #require(store.frame?.entities.first { $0.id == id })
    }

    private func marks(of id: EntityID, in document: ShotsDocument) throws -> [ActorMark] {
        try #require(document.scenes[0].blocking[0].tracks.first { $0.entityID == id }?.marks)
    }

    @Test
    func theHandleSitsOnTheBodyDrawnAtThePlayhead() throws {
        let store = try blockedManStore()
        let drawn = try body(man, in: store)
        let placement = try #require(store.currentScene?.entities.first { $0.id == man }?.placement)
        // D6 found the handle at the placement (x −1.30) while the Man is drawn at x −0.50.
        #expect(abs(drawn.position.x - placement.position.x) > 0.5)

        let target = try #require(ViewportHandles.resolveTarget(in: store))
        #expect(target.worldPivot == drawn.position)
        #expect(target.worldHeading == drawn.heading)
        #expect(try #require(ViewportHandles.resolveTarget(in: store, useCommittedDocument: true)) == target)

        // While another gesture previews a move of the Man, the drawn handle follows the preview, but a drag
        // starts from the committed document's body.
        let shotID = try #require(store.currentShotID)
        let movedMarks = try marks(of: man, in: store.document).map { mark in
            var mark = mark
            mark.position.x += 1
            mark.via = mark.via.map { Vec3($0.x + 1, $0.y, $0.z) }
            return ShotsCommand.updateActorMark(shotID, man, mark)
        }
        store.preview = movedMarks
        let previewed = try #require(ViewportHandles.resolveTarget(in: store))
        #expect(abs(previewed.worldPivot.x - drawn.position.x - 1) < 1e-9)
        #expect(try #require(ViewportHandles.resolveTarget(in: store, useCommittedDocument: true)) == target)
        store.preview = []

        let overlayRoot = Entity()
        ViewportHandles.syncOverlay(in: overlayRoot, store: store, mode: .move, camera: camera, size: size)
        let handles = try #require(overlayRoot.findEntity(named: ViewportHandles.rootEntityName))
        #expect(handles.isEnabled)
        let drawnAt = SIMD3<Float>(Float(drawn.position.x), Float(drawn.position.y), Float(drawn.position.z))
        #expect(simd_distance(handles.position, drawnAt) < 1e-5)
    }

    @Test
    func aMoveDragPreviewsTheWholeBlockingAndCommitsOneUndoStep() throws {
        let store = try blockedManStore()
        let before = store.document
        let start = try body(man, in: store).position
        let grab = try #require(camera.project(start, size: size))
        var drag = ViewportHandles.beginDrag(at: grab, in: store, mode: .move, camera: camera, size: size)
        #expect(drag?.component == .planeXZ)

        let path = [Vec3(0.2, 0, 0.3), Vec3(0.5, 0, 0.7), Vec3(0.8, 0, 1.1)].map {
            Vec3(start.x + $0.x, start.y, start.z + $0.z)
        }
        for point in path {
            let pixel = try #require(camera.project(point, size: size))
            let previewed = ViewportHandles.updateDrag(&drag, at: pixel, in: store, camera: camera, size: size)
            // The placement and each of the Man's three marks, all held in the preview at once.
            #expect(previewed.count == 4 && store.preview == previewed)
            #expect(store.document == before)
            #expect(try distance(body(man, in: store).position, point) < 0.005)
        }
        #expect(ViewportHandles.endDrag(&drag, in: store, camera: camera, size: size))
        #expect(store.preview.isEmpty)

        // The drawn body ends where the pointer put it, and the blocking moved by the drag's delta.
        let release = try #require(path.last)
        #expect(try distance(body(man, in: store).position, release) < 0.005)
        let delta = Vec3(release.x - start.x, 0, release.z - start.z)
        func shifted(_ point: Vec3) -> Vec3 {
            Vec3(point.x + delta.x, point.y, point.z + delta.z)
        }
        let oldMarks = try marks(of: man, in: before), newMarks = try marks(of: man, in: store.document)
        #expect(newMarks.count == oldMarks.count)
        for (old, new) in zip(oldMarks, newMarks) {
            #expect(distance(new.position, shifted(old.position)) < 0.005)
            #expect(new.via.count == old.via.count)
            for (oldVia, newVia) in zip(old.via, new.via) {
                #expect(distance(newVia, shifted(oldVia)) < 0.005)
            }
            #expect(new.arriveHeading == old.arriveHeading && new.time == old.time && new.gait == old.gait)
        }
        let oldPlacement = try #require(before.scenes[0].entities.first { $0.id == man }?.placement)
        let newPlacement = try #require(store.document.scenes[0].entities.first { $0.id == man }?.placement)
        #expect(distance(newPlacement.position, shifted(oldPlacement.position)) < 0.005)
        #expect(newPlacement.heading == oldPlacement.heading)
        // Nobody else moved.
        #expect(try marks(of: "ent_000000000002", in: store.document) == marks(of: "ent_000000000002", in: before))

        // One undo step, back to the document before the drag.
        let after = store.document
        store.undo()
        #expect(store.document == before)
        #expect(!store.canUndo)
        store.redo()
        #expect(store.document == after)
    }

    @Test
    func aRotateDragTurnsTheBlockingAboutTheDrawnBody() throws {
        let store = try blockedManStore()
        let before = store.document
        let start = try body(man, in: store)
        let target = try #require(ViewportHandles.resolveTarget(in: store, useCommittedDocument: true))
        let gizmo = ViewportHandles.gizmoGeometry(for: target, mode: .rotate, camera: camera, size: size)
        let ring = { (angle: Double) in camera.project(gizmo.ringPointWorld(angle: angle), size: size) }

        // A click on the ring that does not turn it commits nothing, so leaves no undo step; a press pauses playback.
        store.isPlaying = true
        var click = try ViewportHandles.beginDrag(
            at: #require(ring(0)),
            in: store,
            mode: .rotate,
            camera: camera,
            size: size
        )
        #expect(click != nil && !store.isPlaying)
        _ = try ViewportHandles.endDrag(&click, at: #require(ring(0)), in: store, camera: camera, size: size)
        #expect(store.document == before && !store.canUndo && store.preview.isEmpty)

        var drag = try ViewportHandles.beginDrag(
            at: #require(ring(0)),
            in: store,
            mode: .rotate,
            camera: camera,
            size: size
        )
        #expect(drag?.component == .rotateY)
        _ = try ViewportHandles.updateDrag(&drag, at: #require(ring(.pi / 4)), in: store, camera: camera, size: size)
        #expect(store.document == before && store.preview.count == 4)
        _ = try ViewportHandles.updateDrag(&drag, at: #require(ring(.pi / 2)), in: store, camera: camera, size: size)
        #expect(ViewportHandles.endDrag(&drag, in: store, camera: camera, size: size))

        // The body stays where it is drawn and turns a quarter.
        let turnedBody = try body(man, in: store)
        #expect(distance(turnedBody.position, start.position) < 0.005)
        #expect(abs(ViewportHandles.normalizeAngle(turnedBody.heading - start.heading - .pi / 2)) < 0.01)

        // Every mark, waypoint and facing turned a quarter about the body.
        func turned(_ point: Vec3) -> Vec3 {
            let dx = point.x - start.position.x, dz = point.z - start.position.z
            return Vec3(start.position.x + dz, point.y, start.position.z - dx)
        }
        for (old, new) in try zip(marks(of: man, in: before), marks(of: man, in: store.document)) {
            #expect(distance(new.position, turned(old.position)) < 0.01)
            for (oldVia, newVia) in zip(old.via, new.via) {
                #expect(distance(newVia, turned(oldVia)) < 0.01)
            }
            #expect((old.arriveHeading == nil) == (new.arriveHeading == nil))
            if let oldFacing = old.arriveHeading, let newFacing = new.arriveHeading {
                #expect(abs(ViewportHandles.normalizeAngle(newFacing - oldFacing - .pi / 2)) < 0.01)
            }
        }
        #expect(try marks(of: man, in: before).last?.arriveHeading != nil)
        let oldPlacement = try #require(before.scenes[0].entities.first { $0.id == man }?.placement)
        let newPlacement = try #require(store.document.scenes[0].entities.first { $0.id == man }?.placement)
        #expect(distance(newPlacement.position, turned(oldPlacement.position)) < 0.01)
        #expect(abs(ViewportHandles.normalizeAngle(newPlacement.heading - oldPlacement.heading - .pi / 2)) < 0.01)
        store.undo()
        #expect(store.document == before && !store.canUndo)
    }

    @Test
    func aPropWithoutMarksStillEditsOnlyItsPlacement() throws {
        let store = try blockedManStore()
        store.selection = .entities([chair])
        let before = store.document
        let placement = try #require(store.currentScene?.entities.first { $0.id == chair }?.placement)
        let target = try #require(ViewportHandles.resolveTarget(in: store))
        #expect(target == .entity(id: chair, initialPlacement: placement, body: nil))

        let grab = try #require(camera.project(placement.position, size: size))
        let moved = Vec3(placement.position.x - 0.4, placement.position.y, placement.position.z + 0.3)
        var drag = ViewportHandles.beginDrag(at: grab, in: store, mode: .move, camera: camera, size: size)
        let previewed = try ViewportHandles.updateDrag(
            &drag,
            at: #require(camera.project(moved, size: size)),
            in: store,
            camera: camera,
            size: size
        )
        guard previewed.count == 1, case let .setPlacement(id, newPlacement) = previewed[0] else {
            Issue.record("A prop drag must preview one setPlacement, got \(previewed)")
            return
        }
        #expect(id == chair && distance(newPlacement.position, moved) < 0.005)
        #expect(ViewportHandles.endDrag(&drag, in: store, camera: camera, size: size))
        #expect(store.document.scenes[0].blocking == before.scenes[0].blocking)
        store.undo()
        #expect(store.document == before)
    }

    private func distance(_ a: Vec3, _ b: Vec3) -> Double {
        ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y) + (a.z - b.z) * (a.z - b.z)).squareRoot()
    }
}
