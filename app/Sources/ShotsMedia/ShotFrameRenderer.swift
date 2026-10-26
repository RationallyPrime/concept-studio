import CoreGraphics
import Metal
import PrevisCore
import RealityKit

/// Renders evaluated frames offscreen. Export and the look-through view both use it, so they agree pixel for pixel.
@MainActor public final class ShotFrameRenderer {
    /// False without a Metal device; render tests skip on false.
    public nonisolated static var isAvailable: Bool {
        MTLCreateSystemDefaultDevice() != nil
    }

    public init() throws {}

    /// Renders `frame` with `look`. `camera` nil uses the frame's camera; `size` nil uses the frame's canvas.
    /// `overlay` (editor chrome) is added for this render only; pass a clone if it is attached elsewhere.
    public func image(
        of frame: SceneFrame,
        look: PrevisLook,
        camera: CameraFrame? = nil,
        overlay: Entity? = nil,
        size: PixelSize? = nil
    ) async throws -> CGImage {
        throw ShotsError.notImplemented("Offscreen frame rendering")
    }
}
