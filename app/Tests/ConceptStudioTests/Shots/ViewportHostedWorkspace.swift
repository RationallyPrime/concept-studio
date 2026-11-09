import AppKit
@testable import ConceptStudio
import Foundation
import PrevisCore
import SwiftUI
import Testing

/// `ShotsWorkspaceView`, Lane C's layout, hosted in an unshown window, with the viewport's AppKit input view found
/// so tests can script real mouse and key events through it (D6, IT4 and the viewport timing test).
@MainActor
struct HostedWorkspace {
    let window: NSWindow
    let host: NSView
    private let defaults = IsolatedDefaults()
    private var dragPoint: CGPoint?

    init(store: ShotsStore, size: CGSize = CGSize(width: 1280, height: 860)) throws {
        let studio = makeTestSession(preferences: defaults.defaults)
        studio.shots = store
        let hosting = NSHostingView(rootView: ShotsWorkspaceView(session: studio)
            .frame(width: size.width, height: size.height))
        hosting.frame = CGRect(origin: .zero, size: size)
        window = NSWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        host = hosting
        hosting.layoutSubtreeIfNeeded()
        _ = try #require(input)
    }

    /// The scene view's input view, or nil while the shot camera view is showing.
    var input: ViewportScrollWheelOverlay.ScrollCapturingView? {
        Self.find(ViewportScrollWheelOverlay.ScrollCapturingView.self, in: host)
    }

    /// The shot camera view's key view, or nil while the scene view is showing.
    var lookThroughKeys: ViewportKeyCaptureOverlay.KeyCapturingView? {
        Self.find(ViewportKeyCaptureOverlay.KeyCapturingView.self, in: host)
    }

    func session() throws -> ViewportLiveSession {
        try #require(input?.session)
    }

    func close() {
        window.contentView = nil
        window.close()
        defaults.remove()
    }

    /// Lets SwiftUI apply pending updates (body, `updateNSView`, `RealityView`'s update) as a run-loop turn would.
    func settle() {
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date())
        host.layoutSubtreeIfNeeded()
    }

    /// The window point over viewport pixel `pixel` (top-left origin), which must be whole pixels to round-trip.
    func windowPoint(forViewportPixel pixel: Point2) throws -> CGPoint {
        try #require(input).convert(CGPoint(x: pixel.x, y: pixel.y), to: nil)
    }

    func click(atViewportPixel pixel: Point2, modifiers: NSEvent.ModifierFlags = []) throws {
        let point = try windowPoint(forViewportPixel: pixel)
        try send(.leftMouseDown, at: point, modifiers: modifiers)
        try send(.leftMouseUp, at: point, modifiers: modifiers)
        settle()
    }

    /// Presses at `start`, moves through `through`, and releases at the last point.
    func drag(fromViewportPixel start: Point2, through points: [Point2]) throws {
        try send(.leftMouseDown, at: windowPoint(forViewportPixel: start))
        settle()
        for point in points {
            try send(.leftMouseDragged, at: windowPoint(forViewportPixel: point))
            settle()
        }
        try send(.leftMouseUp, at: windowPoint(forViewportPixel: points.last ?? start))
        settle()
    }

    /// Orbit steps for the timing test: the first call presses at the viewport's centre.
    mutating func orbit(by delta: CGSize) throws {
        let input = try #require(input)
        if dragPoint == nil {
            let centre = input.convert(CGPoint(x: input.bounds.midX, y: input.bounds.midY), to: nil)
            try send(.leftMouseDown, at: centre)
            dragPoint = centre
        }
        let point = try #require(dragPoint)
        dragPoint = CGPoint(x: point.x + delta.width, y: point.y - delta.height)
        try send(.leftMouseDragged, at: #require(dragPoint))
    }

    mutating func endOrbit() throws {
        guard let point = dragPoint else { return }
        try send(.leftMouseUp, at: point)
        dragPoint = nil
    }

    func send(_ type: NSEvent.EventType, at windowPoint: CGPoint, modifiers: NSEvent.ModifierFlags = []) throws {
        let input = try #require(input)
        let event = try #require(NSEvent.mouseEvent(
            with: type, location: windowPoint, modifierFlags: modifiers, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        switch type {
        case .leftMouseDown: input.mouseDown(with: event)
        case .leftMouseDragged: input.mouseDragged(with: event)
        case .leftMouseUp: input.mouseUp(with: event)
        default: Issue.record("unsupported event \(type)")
        }
    }

    /// Sends a key through the window, so it reaches whichever view has focus and then the responder chain and
    /// SwiftUI's key handlers, as AppKit delivers it.
    func key(_ characters: String, keyCode: UInt16) throws {
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
        ))
        window.sendEvent(event)
        settle()
    }

    static func find<View: NSView>(_ type: View.Type, in root: NSView) -> View? {
        if let match = root as? View { return match }
        for child in root.subviews {
            if let match = find(type, in: child) { return match }
        }
        return nil
    }
}
