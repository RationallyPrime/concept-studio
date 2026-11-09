import AppKit
@testable import ConceptStudio
import Foundation
import PrevisCore
import RealityKit
import ShotsMedia
import SwiftUI
import Testing

private let renderingEnabled = ShotFrameRenderer.isAvailable
    && ProcessInfo.processInfo.environment["SHOTS_SKIP_RENDER"] == nil

/// IT4 (CONTRACTS section 9, D6): scripted viewport input on `twoPersonWalk(small: true)`, inside Lane C's workspace
/// layout. Every edit goes through real mouse and key events on the viewport's input view; only the steps that
/// belong to Lane C's own controls (choosing a library asset, moving the playhead, selecting a mark in the list)
/// set the store the way those controls do.
@Suite("IT4 viewport integration")
@MainActor
struct ViewportIntegrationTests {
    @Test(.enabled(if: renderingEnabled))
    func scriptedViewportInputProducesTheExpectedDocumentAndLookThroughMatchesExport() async throws {
        let catalog = try ContentCatalog.bundled()
        let original = ShotsSamples.twoPersonWalk(small: true)
        let store = ShotsStore(catalog: catalog, document: original, saveURL: nil)
        let workspace = try HostedWorkspace(store: store)
        defer { workspace.close() }
        workspace.settle()
        let script = try IT4Script(store: store, workspace: workspace)

        let placed = try script.placePerson()
        let marks = try script.dropMarks(for: placed)
        let drag = try script.dragSecondMark(of: placed, marks: marks)

        // Undo and redo walk exactly that one step.
        store.undo()
        #expect(store.document == drag.before)
        store.redo()
        #expect(store.document == drag.after)
        #expect(store.preview == nil)

        // The expected document, built by commands from the scripted pixels alone.
        let expected = try script.expectedDocument(from: original, placed: placed, marks: marks, drag: drag)
        #expect(store.document == expected)

        // C toggles to the shot camera view in the same pane, with the keys still live there.
        try workspace.key("c", keyCode: 8)
        #expect(workspace.input == nil)
        let lookThroughKeys = try #require(workspace.lookThroughKeys)
        #expect(workspace.window.firstResponder === lookThroughKeys)
        try await lookThroughAtFrameElevenMatchesTheExportedStill(store: store, catalog: catalog)

        // And C again returns to the scene view, focused, where Space (Lane C's, anywhere in Shots) still plays.
        try workspace.key("c", keyCode: 8)
        let sceneInput = try #require(workspace.input)
        #expect(workspace.window.firstResponder === sceneInput)
        try workspace.key(" ", keyCode: 49)
        #expect(store.isPlaying)
        store.isPlaying = false
    }

    /// The look-through for frame 11 (the shot's guide frame) equals the exported still, as decoded RGB.
    private func lookThroughAtFrameElevenMatchesTheExportedStill(
        store: ShotsStore,
        catalog: ContentCatalog
    ) async throws {
        store.playhead = 11
        let preview = ShotCameraPreviewSession()
        preview.requestRender(for: store)
        await preview.waitForIdle()
        let lookThrough = try #require(preview.renderedImage)
        #expect(preview.renderedRequest?.frame.index == 11)
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("shots-it4-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let package = try await ShotExporter(catalog: catalog).export(
            scene: #require(store.currentScene),
            shotID: #require(store.currentShotID),
            options: ExportOptions(passes: [.clean]),
            to: FolderDestination(parent: folder),
            progress: { _ in }
        )
        let pixels = ViewportLookThroughTests()
        let still = package.url.appendingPathComponent("guides/middle-f0011-clean.png")
        let exportedRGB = try pixels.decodedSRGBBytes(of: pixels.decodePNGImage(at: still))
        let lookThroughRGB = try pixels.decodedSRGBBytes(of: lookThrough)
        #expect(lookThroughRGB.count == 320 * 576 * 3)
        #expect(lookThroughRGB == exportedRGB)
    }

    /// D6 budget fix: orbit and playback re-pose the overlay but rebuild none of its marks or paths, as Blockout's
    /// viewport only rebuilds its overlay on a document, scene or shot change. An edit still rebuilds it.
    @Test
    func orbitAndPlaybackReuseTheOverlayWhileAnEditRebuildsIt() throws {
        let store = try ShotsStore(
            catalog: ContentCatalog.bundled(),
            document: ShotsSamples.twoPersonWalk(small: true),
            saveURL: nil
        )
        let session = ViewportLiveSession()
        let size = PixelSize(width: 640, height: 480)
        store.selection = .entities(["ent_000000000001"])
        session.sync(with: store, frame: store.frame, size: size)
        // Entities, not identifiers: holding them keeps a rebuilt child from reusing a freed one's address.
        func children(_ group: String) -> [Entity] {
            Array(ViewportOverlays.ensureGroup(named: group, in: session.overlayRoot).children)
        }
        func unchanged(_ group: String, _ before: [Entity]) -> Bool {
            let now = children(group)
            return now.count == before.count && zip(now, before).allSatisfy { $0 === $1 }
        }
        let marks = children(ViewportOverlays.marksGroupName)
        let paths = children(ViewportOverlays.pathsGroupName)
        let boxes = children(ViewportOverlays.selectionGroupName)
        #expect(!marks.isEmpty && !paths.isEmpty && boxes.count == 1)

        session.editorCamera.orbit(deltaYaw: 0.4, deltaPitch: -0.1)
        session.sync(with: store, frame: store.frame, size: size)
        #expect(unchanged(ViewportOverlays.marksGroupName, marks))
        #expect(unchanged(ViewportOverlays.pathsGroupName, paths))
        #expect(unchanged(ViewportOverlays.selectionGroupName, boxes))

        // Playback moves the selected actor: its box follows, the marks and paths stay.
        store.playhead = 11
        session.sync(with: store, frame: store.frame, size: size)
        #expect(unchanged(ViewportOverlays.marksGroupName, marks))
        #expect(unchanged(ViewportOverlays.pathsGroupName, paths))
        #expect(!unchanged(ViewportOverlays.selectionGroupName, boxes))
        // The twelve edges' midpoints average to the box's centre, which is the actor's centre at frame 11.
        let box = try #require(children(ViewportOverlays.selectionGroupName).first)
        let centroid = box.children.map(\.position).reduce(.zero, +) / Float(box.children.count)
        let bounds = try #require(store.frame?.entities.first { $0.id == "ent_000000000001" }?.bounds)
        let centre = SIMD3<Float>(
            Float((bounds.min.x + bounds.max.x) / 2),
            Float((bounds.min.y + bounds.max.y) / 2),
            Float((bounds.min.z + bounds.max.z) / 2)
        )
        #expect(box.children.count == 12 && simd_distance(centroid, centre) < 1e-4)
        let badge = try #require(session.overlayRoot.findEntity(named: "mark.number.1"))
        #expect(badge.orientation == ViewportOverlays.simd(session.editorCamera.orientation))

        // Hiding marks still applies when nothing is rebuilt.
        session.setShowMarks(false)
        session.sync(with: store, frame: store.frame, size: size)
        let marksGroup = ViewportOverlays.ensureGroup(named: ViewportOverlays.marksGroupName, in: session.overlayRoot)
        #expect(marksGroup.isEnabled == false)
        session.setShowMarks(true)

        let shotID = try #require(store.currentShotID)
        try store.perform(.addActorMark(shotID, "ent_000000000001", ActorMark(
            id: "mark_added", time: 0.2, hold: 0, easeIn: 0.25, easeOut: 0.25, position: Vec3(0, 0, 1), gait: .walk
        )))
        session.sync(with: store, frame: store.frame, size: size)
        #expect(children(ViewportOverlays.marksGroupName).count == marks.count + 1)
        #expect(!unchanged(ViewportOverlays.pathsGroupName, paths))
        // Rebuilt badges face the camera too.
        let rebuiltBadge = try #require(session.overlayRoot.findEntity(named: "mark.number.1"))
        #expect(rebuiltBadge !== badge)
        #expect(rebuiltBadge.orientation == ViewportOverlays.simd(session.editorCamera.orientation))

        // Switching shots rebuilds the camera marks for the new shot.
        try store.perform(.duplicateShot(shotID, newID: "shot_other"))
        let otherMarks = try #require(store.currentScene?.shots.first { $0.id == "shot_other" }?.camera.marks)
        try store.perform(.deleteMarks("shot_other", [#require(otherMarks.first?.id)]))
        store.currentShotID = "shot_other"
        session.sync(with: store, frame: store.frame, size: size)
        let cameraMarkNames = children(ViewportOverlays.marksGroupName).map(\.name)
            .filter { $0.hasPrefix("viewport.mark.camera:") }
        let expectedNames = try #require(store.currentShot?.camera.marks).map { "viewport.mark.camera:\($0.id)" }
        #expect(cameraMarkNames == expectedNames && expectedNames.count == otherMarks.count - 1)
    }
}

/// IT4's steps, each through the hosted viewport, with the editor camera held fixed so pixels map to ground points.
@MainActor
private struct IT4Script {
    struct Drag {
        var grab: Point2
        var release: Point2
        var before: ShotsDocument
        var after: ShotsDocument
    }

    struct DroppedMarks {
        var ids: [MarkID]
        var first: Point2
        var second: Point2
    }

    let store: ShotsStore
    let workspace: HostedWorkspace
    let session: ViewportLiveSession
    let camera: EditorCamera
    let size: PixelSize
    let placedAt: Point2

    init(store: ShotsStore, workspace: HostedWorkspace) throws {
        self.store = store
        self.workspace = workspace
        session = try workspace.session()
        let input = try #require(workspace.input)
        // The viewport fills its pane of the split layout, and picking uses that same size.
        size = session.viewportSize
        #expect(size == PixelSize(
            width: Int(input.bounds.width.rounded()),
            height: Int(input.bounds.height.rounded())
        ))
        #expect(size.width >= 260 && size.height >= 220)
        camera = session.editorCamera
        placedAt = try Self.pixel(over: Vec3(0.4, 0, 1.2), camera: camera, size: size)
    }

    /// Whole pixels over a world point on the ground.
    static func pixel(over world: Vec3, camera: EditorCamera, size: PixelSize) throws -> Point2 {
        let projected = try #require(camera.project(world, size: size))
        return Point2(x: projected.x.rounded(), y: projected.y.rounded())
    }

    func pixel(over world: Vec3) throws -> Point2 {
        try Self.pixel(over: world, camera: camera, size: size)
    }

    /// Where the viewport's ray through `pixel` meets the ground.
    func ground(at pixel: Point2) throws -> Vec3 {
        try #require(ViewportPicking.intersectGround(at: pixel, camera: camera, size: size))
    }

    /// The library arms the place tool, then a click on the floor places the person and selects it.
    func placePerson() throws -> PrevisEntity {
        store.tool = .place(assetID: "person.woman")
        try workspace.click(atViewportPixel: placedAt)
        let placed = try #require(store.currentScene?.entities.first { $0.name == "Woman 2" })
        #expect(store.selection == .entities([placed.id]))
        #expect(store.tool == .select)
        #expect(distance(placed.placement.position, Vec3(0.4, 0, 1.2)) < 0.03)
        return placed
    }

    /// M, then a mark at frame 0 and one at frame 15 after the timeline moves the playhead. Esc ends the tool.
    func dropMarks(for placed: PrevisEntity) throws -> DroppedMarks {
        try workspace.key("m", keyCode: 46)
        #expect(store.tool == .dropMarks)
        try workspace.click(atViewportPixel: placedAt)
        store.playhead = 15
        let second = try pixel(over: Vec3(-0.6, 0, 0.6))
        try workspace.click(atViewportPixel: second)
        try workspace.key("\u{1B}", keyCode: 53)
        #expect(store.tool == .select)
        let marks = try #require(store.currentScene?.blocking.first?.tracks.first { $0.entityID == placed.id }?.marks)
        try #require(marks.count == 2)
        #expect(marks.map(\.time) == [0, FrameGrid.time(ofFrame: 15)])
        return DroppedMarks(ids: marks.map(\.id), first: placedAt, second: second)
    }

    /// The mark list selects the second mark; its move handle drags it through three points. The preview follows,
    /// the document stays untouched until release, and release commits once.
    func dragSecondMark(of placed: PrevisEntity, marks: DroppedMarks) throws -> Drag {
        store.selection = .actorMark(placed.id, marks.ids[1])
        workspace.settle()
        let before = store.document
        let grab = marks.second
        let path = try [Vec3(-0.7, 0, 0.5), Vec3(-0.8, 0, 0.35), Vec3(-0.9, 0, 0.2)].map(pixel(over:))
        let release = try #require(path.last)
        try workspace.send(.leftMouseDown, at: workspace.windowPoint(forViewportPixel: grab))
        workspace.settle()
        for point in path {
            try workspace.send(.leftMouseDragged, at: workspace.windowPoint(forViewportPixel: point))
            workspace.settle()
            #expect(store.preview != nil)
            #expect(store.document == before)
            #expect(session.editorCamera == camera, "a handle drag must not orbit")
        }
        let previewed = try #require(store.currentScene?.blocking.first?.tracks.first { $0.entityID == placed.id })
        #expect(distance(previewed.marks[1].position, Vec3(-0.9, 0, 0.2)) < 0.03)
        try workspace.send(.leftMouseUp, at: workspace.windowPoint(forViewportPixel: release))
        workspace.settle()
        #expect(store.preview == nil)
        #expect(store.document != before)
        return Drag(grab: grab, release: release, before: before, after: store.document)
    }

    func expectedDocument(
        from original: ShotsDocument,
        placed: PrevisEntity,
        marks: DroppedMarks,
        drag: Drag
    ) throws -> ShotsDocument {
        let expected = ShotsStore(catalog: store.catalog, document: original, saveURL: nil)
        let sceneID = try #require(expected.currentSceneID), shotID = try #require(expected.currentShotID)
        try expected.perform(.addEntity(sceneID, PrevisEntity(
            id: placed.id,
            assetID: "person.woman",
            name: "Woman 2",
            placement: Placement(position: ground(at: placedAt), heading: 0, scale: 1)
        )))
        func mark(_ index: Int, frame: Int, at pixel: Point2) throws -> ActorMark {
            try ActorMark(
                id: marks.ids[index], time: FrameGrid.time(ofFrame: frame), hold: 0, easeIn: 0.25, easeOut: 0.25,
                position: ground(at: pixel), gait: .walk
            )
        }
        try expected.perform(.addActorMark(shotID, placed.id, mark(0, frame: 0, at: marks.first)))
        try expected.perform(.addActorMark(shotID, placed.id, mark(1, frame: 15, at: marks.second)))
        var moved = try mark(1, frame: 15, at: marks.second)
        let start = try ground(at: drag.grab), end = try ground(at: drag.release)
        moved.position = Vec3(moved.position.x + end.x - start.x, 0, moved.position.z + end.z - start.z)
        #expect(distance(moved.position, Vec3(-0.9, 0, 0.2)) < 0.03)
        try expected.perform(.updateActorMark(shotID, placed.id, moved))
        return expected.document
    }
}

private func distance(_ a: Vec3, _ b: Vec3) -> Double {
    ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y) + (a.z - b.z) * (a.z - b.z)).squareRoot()
}
