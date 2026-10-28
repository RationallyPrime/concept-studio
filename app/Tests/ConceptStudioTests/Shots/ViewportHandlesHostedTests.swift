import AppKit
@testable import ConceptStudio
import Foundation
import PrevisCore
import SwiftUI
import Testing

@MainActor
@Suite("Viewport D4 hosted handle routing, focus and announcements")
struct ViewportHandlesHostedTests {
    @Test
    func hostedViewportRoutesHandleDragOverCameraOrbitAndSuppressesKeysWhenUnfocusedOrInTextField() throws {
        let catalog = try ContentCatalog.bundled()
        let document = ShotsSamples.twoPersonWalk(small: true)
        let store = ShotsStore(catalog: catalog, document: document, saveURL: nil)
        let viewportSize = CGSize(width: 640, height: 480)
        let host = NSHostingView(
            rootView: ShotsViewport(store: store)
                .frame(width: viewportSize.width, height: viewportSize.height)
        )
        host.frame = CGRect(origin: .zero, size: viewportSize)
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: viewportSize),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer {
            window.contentView = nil
            window.close()
        }
        host.layoutSubtreeIfNeeded()
        let overlayView = try #require(findScrollCapturingView(in: host))
        let session = try #require(overlayView.session)
        let pixelSize = PixelSize(width: 640, height: 480)
        var announcements: [String] = []
        session.announcementPoster = { announcements.append($0) }

        let chairID = "ent_000000000003"
        store.selection = .entities([chairID])
        session.sync(with: store, frame: store.frame, size: pixelSize)
        #expect(announcements.last == "Selected Chair")

        let initialCamera = session.editorCamera
        let chairPivot = try #require(
            store.currentScene?.entities.first(where: { $0.id == chairID })?.placement.position
        )
        let startPx = try #require(initialCamera.project(chairPivot, size: pixelSize))
        let targetWorld = Vec3(chairPivot.x - 0.65, chairPivot.y, chairPivot.z + 0.45)
        let endPx = try #require(initialCamera.project(targetWorld, size: pixelSize))

        let winStart = overlayView.convert(CGPoint(x: startPx.x, y: startPx.y), to: nil)
        let winEnd = overlayView.convert(CGPoint(x: endPx.x, y: endPx.y), to: nil)
        sendMouse(type: .leftMouseDown, at: winStart, in: window, to: overlayView)
        sendMouse(type: .leftMouseDragged, at: winEnd, in: window, to: overlayView)
        #expect(store.preview != nil)
        #expect(session.editorCamera == initialCamera)
        sendMouse(type: .leftMouseUp, at: winEnd, in: window, to: overlayView)
        #expect(store.preview == nil)
        #expect(session.editorCamera == initialCamera)
        let movedChair = try #require(store.currentScene?.entities.first(where: { $0.id == chairID }))
        #expect(distance(movedChair.placement.position, targetWorld) < 0.01)

        // Focused viewport keys R, G, V work; suppressed when timeline control or NSTextView is firstResponder
        sendKey(characters: "r", keyCode: 15, in: window, to: overlayView)
        #expect(session.handleMode == .rotate)
        #expect(announcements.last == "Rotate ring active")
        try verifyFocusSuppressionAndCancelInHostedViewport(
            host: host,
            window: window,
            overlayView: overlayView,
            session: session,
            store: store
        )
        #expect(announcements.contains("Move handles active"))
    }
}

extension ViewportHandlesHostedTests {
    private func verifyFocusSuppressionAndCancelInHostedViewport(
        host: NSHostingView<some View>,
        window: NSWindow,
        overlayView: ViewportScrollWheelOverlay.ScrollCapturingView,
        session: ViewportLiveSession,
        store: ShotsStore
    ) throws {
        let textEditor = NSTextView(frame: CGRect(x: 0, y: 0, width: 80, height: 20))
        host.addSubview(textEditor)
        _ = window.makeFirstResponder(textEditor)
        sendKey(characters: "g", keyCode: 5, in: window, to: overlayView)
        #expect(session.handleMode == .rotate)

        _ = window.makeFirstResponder(overlayView)
        sendKey(characters: "g", keyCode: 5, in: window, to: overlayView)
        #expect(session.handleMode == .move)
        #expect(session.lastAnnouncement == "Move handles active")

        sendKey(characters: "v", keyCode: 9, in: window, to: overlayView)
        #expect(session.handleMode == .move)
        #expect(store.tool == .select)

        sendKey(characters: "m", keyCode: 46, in: window, to: overlayView)
        #expect(store.tool == .dropMarks)
        sendKey(characters: "\u{1B}", keyCode: 53, in: window, to: overlayView)
        #expect(store.tool == .select)
    }

    private func findScrollCapturingView(in root: NSView) -> ViewportScrollWheelOverlay.ScrollCapturingView? {
        if let match = root as? ViewportScrollWheelOverlay.ScrollCapturingView { return match }
        for child in root.subviews {
            if let match = findScrollCapturingView(in: child) { return match }
        }
        return nil
    }
}

extension ViewportHandlesHostedTests {
    private func sendMouse(
        type: NSEvent.EventType,
        at windowPoint: NSPoint,
        in window: NSWindow,
        to view: ViewportScrollWheelOverlay.ScrollCapturingView
    ) {
        guard let event = NSEvent.mouseEvent(
            with: type,
            location: windowPoint,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        ) else { return }
        switch type {
        case .leftMouseDown: view.mouseDown(with: event)
        case .leftMouseDragged: view.mouseDragged(with: event)
        case .leftMouseUp: view.mouseUp(with: event)
        default: break
        }
    }

    private func sendKey(
        characters: String,
        keyCode: UInt16,
        in window: NSWindow,
        to view: ViewportScrollWheelOverlay.ScrollCapturingView
    ) {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ) else { return }
        view.keyDown(with: event)
    }

    private func distance(_ a: Vec3, _ b: Vec3) -> Double {
        let dx = a.x - b.x
        let dy = a.y - b.y
        let dz = a.z - b.z
        return (dx * dx + dy * dy + dz * dz).squareRoot()
    }
}

extension ViewportHandlesHostedTests {
    @Test
    func undoOrCommittedTargetEditDuringHandlePreviewCancelsDragAndPreservesUndoRedo() throws {
        let catalog = try ContentCatalog.bundled()
        let document = ShotsSamples.twoPersonWalk(small: true)
        let store = ShotsStore(catalog: catalog, document: document, saveURL: nil)
        let session = ViewportLiveSession()
        let camera = EditorCamera.defaultView
        let size = PixelSize(width: 640, height: 480)
        session.viewportSize = size

        let chairID = "ent_000000000003"
        store.selection = .entities([chairID])
        let originalDoc = store.document
        let initialChair = try #require(store.currentScene?.entities.first(where: { $0.id == chairID }))

        // 1. Commit a 0.4m placement change to create one Undo entry
        var step1Placement = initialChair.placement
        step1Placement.position = Vec3(
            initialChair.placement.position.x + 0.4,
            initialChair.placement.position.y,
            initialChair.placement.position.z
        )
        store.run(.setPlacement(chairID, step1Placement))
        #expect(store.canUndo)
        #expect(!store.canRedo)

        // 2. Begin handle drag from the committed 0.4m baseline and preview another 0.8m move
        let startPx = try #require(camera.project(step1Placement.position, size: size))
        let goalWorld = Vec3(
            step1Placement.position.x - 0.8,
            step1Placement.position.y,
            step1Placement.position.z + 0.3
        )
        let goalPx = try #require(camera.project(goalWorld, size: size))
        #expect(session.beginHandleDrag(at: startPx, in: store))
        session.updateHandleDrag(at: goalPx, shiftPressed: false, in: store)
        #expect(store.preview != nil)

        // 3. Undo during active preview restores originalDoc; sync + release must NOT overwrite Undo or clear Redo
        store.undo()
        #expect(store.document == originalDoc)
        #expect(store.canRedo)
        #expect(store.preview == nil)
        session.sync(with: store, frame: store.frame, size: size)
        session.endHandleDrag(at: goalPx, shiftPressed: false, in: store)
        #expect(session.activeHandleDrag == nil)
        #expect(store.preview == nil)
        #expect(store.document == originalDoc)
        #expect(store.canRedo)

        // 4. Another committed target edit during active preview also invalidates the stale baseline
        let origPx = try #require(camera.project(initialChair.placement.position, size: size))
        #expect(session.beginHandleDrag(at: origPx, in: store))
        session.updateHandleDrag(at: goalPx, shiftPressed: false, in: store)
        #expect(store.preview != nil)
        var externalPlacement = initialChair.placement
        externalPlacement.position = Vec3(initialChair.placement.position.x, 0, initialChair.placement.position.z - 0.5)
        store.run(.setPlacement(chairID, externalPlacement))
        let committedDocAfterExternal = store.document
        session.endHandleDrag(at: goalPx, shiftPressed: false, in: store)
        #expect(session.activeHandleDrag == nil)
        #expect(store.preview == nil)
        #expect(store.document == committedDocAfterExternal)
    }
}

extension ViewportHandlesHostedTests {
    @Test
    func stationaryActorRotateNoOpCloseZoomScaleAndTeardownCancelPreview() throws {
        let catalog = try ContentCatalog.bundled()
        let document = ShotsSamples.twoPersonWalk(small: true)
        let store = ShotsStore(catalog: catalog, document: document, saveURL: nil)
        let session = ViewportLiveSession()
        let camera = EditorCamera.defaultView
        let size = PixelSize(width: 640, height: 480)
        session.viewportSize = size

        // 1. Stationary actor-mark rotation release at same point preserves nil arriveHeading and adds no undo step
        let actorID = "ent_000000000001"
        let markID = try #require(
            store.currentScene?.blocking.first?.tracks.first(where: { $0.entityID == actorID })?.marks.first?.id
        )
        store.selection = .actorMark(actorID, markID)
        let beforeDoc = store.document
        let actorTarget = try #require(ViewportHandles.resolveTarget(in: store))
        let actorGizmo = ViewportHandles.gizmoGeometry(for: actorTarget, mode: .rotate, camera: camera, size: size)
        let ringPointPx = try #require(camera.project(actorGizmo.ringPointWorld(angle: 0), size: size))
        session.setHandleMode(.rotate, in: store)
        #expect(session.beginHandleDrag(at: ringPointPx, in: store))
        session.endHandleDrag(at: ringPointPx, shiftPressed: false, in: store)
        #expect(store.preview == nil)
        #expect(store.document == beforeDoc)
        #expect(!store.canUndo)

        // 2. Close-zoom (0.5m) overlay scale matches worldRadius and projects to 56px
        store.selection = .entities([actorID])
        let entityTarget = try #require(ViewportHandles.resolveTarget(in: store))
        var closeCam = EditorCamera.defaultView
        closeCam.target = entityTarget.worldPivot
        closeCam.distance = 0.5
        let closeGeom = ViewportHandles.gizmoGeometry(for: entityTarget, mode: .move, camera: closeCam, size: size)
        let closeProjRadius = try #require(closeGeom.projectedScreenRadius(camera: closeCam, size: size))
        #expect(abs(closeProjRadius - ViewportHandleGizmoGeometry.targetScreenRadiusPixels) < 0.05)
        session.editorCamera = closeCam
        session.sync(with: store, frame: store.frame, size: size)
        let handlesEntity = try #require(session.overlayRoot.findEntity(named: ViewportHandles.rootEntityName))
        #expect(abs(Double(handlesEntity.scale.x) - closeGeom.worldRadius) < 1e-4)

        // 3. Replacing hosted ShotsViewport region during active routed handle preview clears store.preview
        let viewportSize = CGSize(width: 640, height: 480)
        let host = NSHostingView(
            rootView: AnyView(
                ShotsViewport(store: store).frame(width: viewportSize.width, height: viewportSize.height)
            )
        )
        host.frame = CGRect(origin: .zero, size: viewportSize)
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: viewportSize),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer {
            window.contentView = nil
            window.close()
        }
        host.layoutSubtreeIfNeeded()
        let overlayView = try #require(findScrollCapturingView(in: host))
        let hostSession = try #require(overlayView.session)
        let pivotPx = try #require(hostSession.editorCamera.project(entityTarget.worldPivot, size: size))
        let dragPx = try #require(
            hostSession.editorCamera.project(
                Vec3(entityTarget.worldPivot.x + 0.5, 0, entityTarget.worldPivot.z),
                size: size
            )
        )
        let winDown = overlayView.convert(CGPoint(x: pivotPx.x, y: pivotPx.y), to: nil)
        let winDrag = overlayView.convert(CGPoint(x: dragPx.x, y: dragPx.y), to: nil)
        sendMouse(type: .leftMouseDown, at: winDown, in: window, to: overlayView)
        sendMouse(type: .leftMouseDragged, at: winDrag, in: window, to: overlayView)
        #expect(store.preview != nil)
        host.rootView = AnyView(EmptyView())
        host.layoutSubtreeIfNeeded()
        #expect(store.preview == nil)
        #expect(store.document == beforeDoc)
    }
}
