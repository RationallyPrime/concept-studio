import AppKit
import CoreGraphics
import Foundation
import PrevisCore
import RealityKit
import ShotsMedia

/// Offscreen snapshot helper for the 3D editor viewport.
/// Uses `ShotFrameRenderer` with `EditorCamera` and a recursive clone of the editor overlay root.
@MainActor enum ViewportSnapshotRenderer {
    static func renderSnapshot(
        frame: SceneFrame,
        look: PrevisLook,
        camera: EditorCamera,
        overlayRoot: Entity? = nil,
        size: PixelSize? = nil,
        renderer: ShotFrameRenderer? = nil
    ) async throws -> CGImage {
        let resolvedSize = size ?? frame.canvas.pixelSize
        let resolvedRenderer = try renderer ?? ShotFrameRenderer()
        let overlayClone = overlayRoot?.clone(recursive: true)
        return try await resolvedRenderer.image(
            of: frame,
            look: look,
            camera: camera.cameraFrame(for: resolvedSize),
            overlay: overlayClone,
            size: resolvedSize
        )
    }

    @discardableResult
    static func writeSnapshot(
        image: CGImage,
        named filename: String,
        directory: URL? = nil
    ) throws -> URL {
        let targetDirectory = try resolvedSnapshotDirectory(explicit: directory)
        try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        let fileURL = targetDirectory.appendingPathComponent(filename)
        guard let pngData = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw ShotsMediaError("Shots couldn't encode the viewport snapshot \(filename) as PNG.")
        }
        try pngData.write(to: fileURL, options: .atomic)
        return fileURL
    }

    static func resolvedSnapshotDirectory(explicit: URL? = nil) throws -> URL {
        if let explicit { return explicit }
        if let envPath = ProcessInfo.processInfo.environment["SHOTS_SNAPSHOT_DIR"], !envPath.isEmpty {
            return URL(fileURLWithPath: envPath, isDirectory: true)
        }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("shots-viewport-snapshots", isDirectory: true)
    }
}
