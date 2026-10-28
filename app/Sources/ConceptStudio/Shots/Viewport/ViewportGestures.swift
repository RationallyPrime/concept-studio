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
    static let dragThresholdPoints: CGFloat = 3.0

    var session: ViewportLiveSession?
    var onSync: (() -> Void)?
    var onScroll: (NSEvent) -> Void
    var onDrag: ((CGSize, Bool) -> Void)?
    var onDragEnded: (() -> Void)?
    var onMagnify: ((CGFloat) -> Void)?
    var onClick: ((Point2, Bool, Bool) -> Void)?
    var onKeyDown: ((String?, UInt16, NSEvent.ModifierFlags) -> Bool)?

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
        view.onClick = onClick
        view.onKeyDown = onKeyDown
    }

    final class ScrollCapturingView: NSView {
        weak var session: ViewportLiveSession?
        var onScroll: ((NSEvent) -> Void)?
        var onDrag: ((CGSize, Bool) -> Void)?
        var onDragEnded: (() -> Void)?
        var onMagnify: ((CGFloat) -> Void)?
        var onClick: ((Point2, Bool, Bool) -> Void)?
        var onKeyDown: ((String?, UInt16, NSEvent.ModifierFlags) -> Bool)?
        private var mouseDownLocation: NSPoint?
        private var lastMouseLocation: NSPoint?
        private var accumulatedSubThresholdDelta: CGSize = .zero
        private var didDragBeyondThreshold = false

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
            window?.makeFirstResponder(self)
            let local = convert(event.locationInWindow, from: nil)
            mouseDownLocation = local
            lastMouseLocation = local
            accumulatedSubThresholdDelta = .zero
            didDragBeyondThreshold = false
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
            let optionPressed = event.modifierFlags.contains(.option)

            if didDragBeyondThreshold {
                onDrag?(delta, optionPressed)
                return
            }

            accumulatedSubThresholdDelta = CGSize(
                width: accumulatedSubThresholdDelta.width + delta.width,
                height: accumulatedSubThresholdDelta.height + delta.height
            )
            let distanceFromDown: CGFloat = if let down = mouseDownLocation {
                hypot(currentLocation.x - down.x, currentLocation.y - down.y)
            } else {
                hypot(accumulatedSubThresholdDelta.width, accumulatedSubThresholdDelta.height)
            }
            let accumulatedDistance = hypot(accumulatedSubThresholdDelta.width, accumulatedSubThresholdDelta.height)
            if max(distanceFromDown, accumulatedDistance) >= ViewportScrollWheelOverlay.dragThresholdPoints {
                didDragBeyondThreshold = true
                let initialDragDelta = accumulatedSubThresholdDelta
                accumulatedSubThresholdDelta = .zero
                onDrag?(initialDragDelta, optionPressed)
            }
        }

        override func mouseUp(with event: NSEvent) {
            let upLocation = convert(event.locationInWindow, from: nil)
            if let down = mouseDownLocation,
               hypot(upLocation.x - down.x, upLocation.y - down.y) >= ViewportScrollWheelOverlay.dragThresholdPoints,
               !didDragBeyondThreshold {
                didDragBeyondThreshold = true
                let totalDelta = CGSize(width: upLocation.x - down.x, height: upLocation.y - down.y)
                onDrag?(totalDelta, event.modifierFlags.contains(.option))
            }
            let wasDrag = didDragBeyondThreshold
            mouseDownLocation = nil
            lastMouseLocation = nil
            accumulatedSubThresholdDelta = .zero
            didDragBeyondThreshold = false
            if wasDrag {
                onDragEnded?()
            } else {
                let converted = ViewportPicking.viewportPixel(
                    fromViewPoint: upLocation,
                    viewBounds: bounds,
                    isFlipped: isFlipped
                )
                let shiftPressed = event.modifierFlags.contains(.shift)
                let optionPressed = event.modifierFlags.contains(.option)
                onClick?(converted.pixel, shiftPressed, optionPressed)
                onDragEnded?()
            }
        }

        override func magnify(with event: NSEvent) {
            onMagnify?(event.magnification)
        }

        override func keyDown(with event: NSEvent) {
            if onKeyDown?(event.charactersIgnoringModifiers, event.keyCode, event.modifierFlags) == true {
                return
            }
            super.keyDown(with: event)
        }
    }
}
