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
