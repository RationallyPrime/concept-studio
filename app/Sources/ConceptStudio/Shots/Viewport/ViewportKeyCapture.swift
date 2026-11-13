import AppKit
import Foundation
import PrevisCore
import SwiftUI

/// Focusable AppKit key-capture overlay for `ShotCameraView` so look-through mode accepts viewport-focused
/// shortcuts (such as `C` to return to `ShotsViewport` and `1–9` camera-mark jumps) without intercepting
/// text editing or non-viewport responders.
struct ViewportKeyCaptureOverlay: NSViewRepresentable {
    var session: ViewportLiveSession?
    var selection: ShotsSelection = .none
    var claimFocusOnAppear = false
    var onClaimedFocus: (() -> Void)?
    /// Pointer presses, drags and releases over the overlay, in its own points from the top left. The look-through
    /// view uses them to select a stand-in and slide it along the floor.
    var onPointer: ((PointerPhase, CGPoint) -> Void)?
    var onSync: (() -> Void)?
    var onKeyDown: ((String?, UInt16, NSEvent.ModifierFlags) -> Bool)?

    enum PointerPhase { case down, moved, up }

    func makeNSView(context: Context) -> KeyCapturingView {
        let view = KeyCapturingView()
        configure(view)
        onSync?()
        return view
    }

    func updateNSView(_ nsView: KeyCapturingView, context: Context) {
        configure(nsView)
        onSync?()
    }

    private func configure(_ view: KeyCapturingView) {
        view.session = session
        session?.hostView = view
        view.onKeyDown = onKeyDown
        view.onPointer = onPointer
        view.onClaimedFocus = onClaimedFocus
        if claimFocusOnAppear {
            view.requestFocusIfNeeded()
        }
    }

    final class KeyCapturingView: NSView {
        weak var session: ViewportLiveSession?
        var onClaimedFocus: (() -> Void)?
        var onKeyDown: ((String?, UInt16, NSEvent.ModifierFlags) -> Bool)?
        var onPointer: ((PointerPhase, CGPoint) -> Void)?
        private var pendingFocusRequest = false

        private func point(of event: NSEvent) -> CGPoint {
            let local = convert(event.locationInWindow, from: nil)
            return CGPoint(x: local.x, y: bounds.height - local.y)
        }

        override func mouseDragged(with event: NSEvent) {
            onPointer?(.moved, point(of: event))
        }

        override func mouseUp(with event: NSEvent) {
            onPointer?(.up, point(of: event))
        }

        override var acceptsFirstResponder: Bool {
            true
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            true
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if pendingFocusRequest {
                requestFocusIfNeeded()
            }
        }

        func requestFocusIfNeeded() {
            guard let window else {
                pendingFocusRequest = true
                return
            }
            pendingFocusRequest = false
            window.makeFirstResponder(self)
            onClaimedFocus?()
        }

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            onPointer?(.down, point(of: event))
        }

        override func keyDown(with event: NSEvent) {
            if let responder = window?.firstResponder {
                if responder is NSText { return }
                if responder !== self, responder !== window { return }
            }
            if onKeyDown?(event.charactersIgnoringModifiers, event.keyCode, event.modifierFlags) == true {
                return
            }
            super.keyDown(with: event)
        }
    }
}
