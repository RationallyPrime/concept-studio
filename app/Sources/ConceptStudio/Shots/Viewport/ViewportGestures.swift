import AppKit
import PrevisCore
import SwiftUI

/// Pure gesture mapping for the editor camera (orbit drag, pan on two-finger or ⌥-drag, dolly on pinch or scroll).
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
            applyOrbit(to: &camera, deltaPoints: deltaPoints)
        }
    }

    static func applyOrbit(to camera: inout EditorCamera, deltaPoints: CGSize) {
        let deltaYaw = -Double(deltaPoints.width) * orbitRadiansPerPoint
        let deltaPitch = -Double(deltaPoints.height) * orbitRadiansPerPoint
        camera.orbit(deltaYaw: deltaYaw, deltaPitch: deltaPitch)
    }

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
