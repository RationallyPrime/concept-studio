import CoreGraphics
import CoreVideo
import Metal
import PrevisCore
import RealityKit

/// Renders evaluated frames offscreen. Export and the look-through view both use it, so they agree pixel for
/// pixel. Transforms come from the frame alone and the renderer is driven with a zero time step, so a frame
/// renders the same bytes however often and in whatever order it is drawn.
@MainActor public final class ShotFrameRenderer {
    /// False without a Metal device; render tests skip on false.
    public nonisolated static var isAvailable: Bool {
        MTLCreateSystemDefaultDevice() != nil
    }

    private let renderer: RealityRenderer
    private let mapper: PrevisSceneMapper
    private let textureCache: CVMetalTextureCache
    private var pools: [PixelSize: CVPixelBufferPool] = [:]

    public init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw ShotsMediaError("This Mac has no Metal device, so Shots can't render frames.")
        }
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess, let cache else {
            throw ShotsMediaError("Shots couldn't prepare a Metal texture cache for rendering.")
        }
        textureCache = cache
        renderer = try RealityRenderer()
        mapper = PrevisSceneMapper(look: PrevisLook(lighting: .day))
        renderer.entities.append(mapper.root)
        renderer.cameraSettings.antialiasing = .multisample4X
        renderer.cameraSettings.isToneMappingEnabled = false
    }

    /// Renders `frame` with `look`. `camera` nil uses the frame's camera; `size` nil uses the frame's canvas.
    /// `overlay` (editor chrome) is added for this render only; pass a clone if it is attached elsewhere.
    public func image(
        of frame: SceneFrame,
        look: PrevisLook,
        camera: CameraFrame? = nil,
        overlay: Entity? = nil,
        size: PixelSize? = nil
    ) async throws -> CGImage {
        let size = size ?? frame.canvas.pixelSize
        guard size.width > 0, size.height > 0 else {
            throw ShotsMediaError("Shots can't render a \(size.width) × \(size.height) image.")
        }
        let buffer = try pixelBuffer(size)
        try await render(frame, look: look, camera: camera, overlay: overlay, into: buffer)
        return try Self.image(from: buffer)
    }

    /// Renders into an IOSurface-backed BGRA buffer, the shape `AVAssetWriter` takes directly (B2).
    func render(
        _ frame: SceneFrame,
        look: PrevisLook,
        camera: CameraFrame? = nil,
        overlay: Entity? = nil,
        into buffer: CVPixelBuffer
    ) async throws {
        mapper.setLook(look)
        mapper.apply(frame)
        let cameraEntity = mapper.cameraEntity(for: camera ?? frame.camera)
        if cameraEntity.parent == nil, !renderer.entities.contains(where: { $0 === cameraEntity }) {
            renderer.entities.append(cameraEntity)
        }
        renderer.activeCamera = cameraEntity
        renderer.cameraSettings.colorBackground = .color(look.palette.background.cgColor)
        if let overlay { renderer.entities.append(overlay) }
        defer { if let overlay { renderer.entities.remove(overlay) } }

        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        var textureRef: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil, textureCache, buffer, nil, .bgra8Unorm_srgb, width, height, 0, &textureRef
        )
        guard status == kCVReturnSuccess, let textureRef, let texture = CVMetalTextureGetTexture(textureRef) else {
            throw ShotsMediaError("Shots couldn't create a render target of \(width) × \(height).")
        }
        let output = try RealityRenderer.CameraOutput(.singleProjection(colorTexture: texture))
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            do {
                try renderer.updateAndRender(deltaTime: 0, cameraOutput: output, onComplete: { _ in
                    continuation.resume()
                })
            } catch {
                continuation.resume(throwing: error)
            }
        }
        withExtendedLifetime(textureRef) {}
    }

    func pixelBuffer(_ size: PixelSize) throws -> CVPixelBuffer {
        let pool: CVPixelBufferPool
        if let existing = pools[size] {
            pool = existing
        } else {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: size.width,
                kCVPixelBufferHeightKey as String: size.height,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ]
            var created: CVPixelBufferPool?
            guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &created) == kCVReturnSuccess,
                  let created
            else { throw ShotsMediaError("Shots couldn't allocate render buffers of \(size.width) × \(size.height).") }
            pools[size] = created
            pool = created
        }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else {
            throw ShotsMediaError("Shots ran out of render buffers.")
        }
        return buffer
    }

    /// Copies the rendered pixels out, so the image doesn't depend on the buffer's lifetime.
    static func image(from buffer: CVPixelBuffer) throws -> CGImage {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let provider = CGDataProvider(data: Data(bytes: base, count: bytesPerRow * height) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: bytesPerRow,
                  space: space,
                  bitmapInfo: CGBitmapInfo(
                      rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
                  ),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              )
        else { throw ShotsMediaError("Shots couldn't read back a rendered frame.") }
        return image
    }
}

/// A plain-sentence error for media work that has no PrevisCore equivalent.
public struct ShotsMediaError: Error, LocalizedError, Sendable, Equatable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? {
        message
    }
}
