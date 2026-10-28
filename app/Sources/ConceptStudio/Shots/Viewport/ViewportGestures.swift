import AppKit
import PrevisCore
import SwiftUI

/// Pure gesture mapping for the editor camera (orbit drag, pan on two-finger or ⌥-drag, dolly on pinch or scroll).
///
/// Reference: Blockout `src/renderer/viewport/SceneManager.ts:194-198` (`THREE.OrbitControls` on `freeCam`).
/// Intentional Swift/RealityKit deviation: instead of imperative `OrbitControls` with frame-rate-dependent damping
/// (`dampingFactor = 0.12`), gestures mutate the pure value `EditorCamera` directly so camera state and CPU picking
/// rays remain deterministic and testable without a live window (`LANE-D-VIEWPORT.md` lines 28-34, 77-80).
enum ViewportCameraGestures {
    static let orbitRadiansPerPoint: Double = 0.0075
    static let scrollDollyMetersPerPoint: Double = 0.04
    static let twoFingerPanPointsFactor: Double = 1.0

    static func applyDrag(
        to camera: inout EditorCamera,
        deltaPoints: CGSize,
        viewportSize: PixelSize,
        optionPressed: Bool
    ) {
        if optionPressed {
            applyPan(to: &camera, deltaPoints: deltaPoints, viewportSize: viewportSize)
        } else {
            applyOrbit(to: &camera, deltaPoints: deltaPoints, viewportSize: viewportSize)
        }
    }

    /// Orbits around `camera.target`. Scales by `2π / viewportHeight` (matching
    /// `THREE.OrbitControls.handleMouseMoveRotate`)
    /// when a valid viewport height is provided, or `orbitRadiansPerPoint` otherwise.
    static func applyOrbit(
        to camera: inout EditorCamera,
        deltaPoints: CGSize,
        viewportSize: PixelSize? = nil
    ) {
        let radiansPerPoint: Double = if let size = viewportSize, size.height > 0 {
            (2.0 * .pi) / Double(size.height)
        } else {
            orbitRadiansPerPoint
        }
        let deltaYaw = -Double(deltaPoints.width) * radiansPerPoint
        let deltaPitch = -Double(deltaPoints.height) * radiansPerPoint
        camera.orbit(deltaYaw: deltaYaw, deltaPitch: deltaPitch)
    }

    /// Pans `camera.target` in the camera's local image plane (`2 * distance * tan(vFOV / 2) / viewportHeight` per
    /// point,
    /// matching `THREE.OrbitControls.pan`).
    static func applyPan(
        to camera: inout EditorCamera,
        deltaPoints: CGSize,
        viewportSize: PixelSize
    ) {
        let height = Double(max(viewportSize.height, 1))
        let frame = camera.cameraFrame(for: viewportSize)
        let worldPerPixel = (2.0 * camera.distance * tan(frame.verticalFOV / 2.0)) / height
        let deltaRight = -Double(deltaPoints.width) * worldPerPixel
        let deltaUp = Double(deltaPoints.height) * worldPerPixel
        camera.pan(deltaRight: deltaRight, deltaUp: deltaUp)
    }

    /// Routes trackpad two-finger scroll (`hasPreciseScrollingDeltas == true`) to pan in both axes (including
    /// vertical-only and near-vertical drags), and discrete mouse-wheel scroll (`hasPreciseScrollingDeltas == false`)
    /// to dolly along the view axis.
    static func applyScrollOrTrackpad(
        to camera: inout EditorCamera,
        scrollingDeltaX: CGFloat,
        scrollingDeltaY: CGFloat,
        hasPreciseScrollingDeltas: Bool,
        optionPressed: Bool = false,
        viewportSize: PixelSize
    ) {
        _ = optionPressed
        if hasPreciseScrollingDeltas {
            let delta = CGSize(
                width: scrollingDeltaX * twoFingerPanPointsFactor,
                height: scrollingDeltaY * twoFingerPanPointsFactor
            )
            applyPan(to: &camera, deltaPoints: delta, viewportSize: viewportSize)
        } else {
            camera.dolly(delta: -Double(scrollingDeltaY) * scrollDollyMetersPerPoint)
        }
    }

    /// Applies an incremental trackpad pinch magnification delta (`NSEvent.magnification`).
    static func applyMagnify(
        to camera: inout EditorCamera,
        magnification: CGFloat
    ) {
        let stepFactor = max(1.0 + Double(magnification), 0.05)
        camera.dolly(scale: 1.0 / stepFactor)
    }
}

/// Hit-testable AppKit input surface over `ShotsViewport` that receives wheel dolly, trackpad two-finger pan,
/// trackpad pinch magnify, and click/drag orbit or `⌥`-pan events.
struct ViewportScrollWheelOverlay: NSViewRepresentable {
    var session: ViewportLiveSession?
    var onSync: (() -> Void)?
    var onScroll: (NSEvent) -> Void
    var onDrag: ((CGSize, Bool) -> Void)?
    var onDragEnded: (() -> Void)?
    var onMagnify: ((CGFloat) -> Void)?

    func makeNSView(context: Context) -> ScrollCapturingView {
        let view = ScrollCapturingView()
        configure(view)
        onSync?()
        return view
    }

    func updateNSView(_ nsView: ScrollCapturingView, context: Context) {
        configure(nsView)
        onSync?()
    }

    private func configure(_ view: ScrollCapturingView) {
        view.session = session
        view.onScroll = onScroll
        view.onDrag = onDrag
        view.onDragEnded = onDragEnded
        view.onMagnify = onMagnify
    }

    final class ScrollCapturingView: NSView {
        weak var session: ViewportLiveSession?
        var onScroll: ((NSEvent) -> Void)?
        var onDrag: ((CGSize, Bool) -> Void)?
        var onDragEnded: (() -> Void)?
        var onMagnify: ((CGFloat) -> Void)?
        private var lastMouseLocation: NSPoint?

        override var isFlipped: Bool {
            true
        }

        override var acceptsFirstResponder: Bool {
            true
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            true
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            let localPoint = superview.map { convert(point, from: $0) } ?? point
            return bounds.contains(localPoint) ? self : nil
        }

        override func scrollWheel(with event: NSEvent) {
            onScroll?(event)
        }

        override func mouseDown(with event: NSEvent) {
            lastMouseLocation = convert(event.locationInWindow, from: nil)
        }

        override func mouseDragged(with event: NSEvent) {
            let currentLocation = convert(event.locationInWindow, from: nil)
            let delta = if let previousLocation = lastMouseLocation,
                           abs(currentLocation.x - previousLocation.x) > 1e-6
                           || abs(currentLocation.y - previousLocation.y) > 1e-6 {
                CGSize(
                    width: currentLocation.x - previousLocation.x,
                    height: currentLocation.y - previousLocation.y
                )
            } else {
                CGSize(width: event.deltaX, height: event.deltaY)
            }
            lastMouseLocation = currentLocation
            onDrag?(delta, event.modifierFlags.contains(.option))
        }

        override func mouseUp(with event: NSEvent) {
            lastMouseLocation = nil
            onDragEnded?()
        }

        override func magnify(with event: NSEvent) {
            onMagnify?(event.magnification)
        }
    }
}

/// Hit-testable AppKit HUD toggle buttons (`Marks` and `Paths`) mounted above `ViewportScrollWheelOverlay`
/// so clicking either pill toggles the corresponding overlay group while stage drags still reach `ScrollCapturingView`.
struct ViewportOverlayTogglesRepresentable: NSViewRepresentable {
    var session: ViewportLiveSession

    func makeNSView(context: Context) -> ToggleBarView {
        let view = ToggleBarView()
        view.session = session
        view.refreshState()
        return view
    }

    func updateNSView(_ nsView: ToggleBarView, context: Context) {
        nsView.session = session
        nsView.refreshState()
    }

    final class ToggleBarView: NSView {
        weak var session: ViewportLiveSession?
        let marksButton = NSButton(title: "Marks", target: nil, action: nil)
        let pathsButton = NSButton(title: "Paths", target: nil, action: nil)

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            setupButton(marksButton, id: "viewport.hud.toggle.marks", action: #selector(handleMarksToggle))
            setupButton(pathsButton, id: "viewport.hud.toggle.paths", action: #selector(handlePathsToggle))
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        private func setupButton(_ button: NSButton, id: String, action: Selector) {
            button.identifier = NSUserInterfaceItemIdentifier(id)
            button.setButtonType(.pushOnPushOff)
            button.bezelStyle = .recessed
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11, weight: .medium)
            button.target = self
            button.action = action
            addSubview(button)
        }

        override func layout() {
            super.layout()
            let spacing: CGFloat = 4
            let buttonWidth = max((bounds.width - spacing) * 0.5, 1)
            marksButton.frame = NSRect(x: 0, y: 0, width: buttonWidth, height: bounds.height)
            pathsButton.frame = NSRect(x: buttonWidth + spacing, y: 0, width: buttonWidth, height: bounds.height)
        }

        func refreshState() {
            marksButton.state = (session?.showMarks ?? true) ? .on : .off
            pathsButton.state = (session?.showPaths ?? true) ? .on : .off
        }

        @objc private func handleMarksToggle() {
            session?.toggleMarks()
            refreshState()
        }

        @objc private func handlePathsToggle() {
            session?.togglePaths()
            refreshState()
        }
    }
}
