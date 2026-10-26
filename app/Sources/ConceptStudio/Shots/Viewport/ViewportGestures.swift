import AppKit
import PrevisCore
import SwiftUI

/// Pure gesture mapping for the editor camera (orbit drag, pan on two-finger or ⌥-drag, dolly on pinch or scroll).
///
/// Reference: Blockout `src/renderer/viewport/SceneManager.ts:194-198` (`THREE.OrbitControls` on `freeCam`).
/// Intentional Swift/RealityKit deviation: instead of imperative `OrbitControls` with frame-rate-dependent damping
/// (`dampingFactor = 0.12`), gestures mutate the pure value `EditorCamera` directly so camera state and CPU picking
/// rays remain deterministic and testable without a live window (`LANE-D-VIEWPORT.md` lines 28-34).
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

    static func applyScrollOrTrackpad(
        to camera: inout EditorCamera,
        scrollingDeltaX: CGFloat,
        scrollingDeltaY: CGFloat,
        hasPreciseScrollingDeltas: Bool,
        optionPressed: Bool,
        viewportSize: PixelSize
    ) {
        if hasPreciseScrollingDeltas, optionPressed || abs(scrollingDeltaX) > 0.01 {
            let delta = CGSize(
                width: scrollingDeltaX * twoFingerPanPointsFactor,
                height: scrollingDeltaY * twoFingerPanPointsFactor
            )
            applyPan(to: &camera, deltaPoints: delta, viewportSize: viewportSize)
        } else {
            camera.dolly(delta: -Double(scrollingDeltaY) * scrollDollyMetersPerPoint)
        }
    }
}

/// Captures scroll-wheel / trackpad two-finger pan events over the viewport without stealing normal clicks.
struct ViewportScrollWheelOverlay: NSViewRepresentable {
    var onScroll: (NSEvent) -> Void

    func makeNSView(context: Context) -> ScrollCapturingView {
        let view = ScrollCapturingView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ nsView: ScrollCapturingView, context: Context) {
        nsView.onScroll = onScroll
    }

    final class ScrollCapturingView: NSView {
        var onScroll: ((NSEvent) -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        override func scrollWheel(with event: NSEvent) {
            onScroll?(event)
        }
    }
}
