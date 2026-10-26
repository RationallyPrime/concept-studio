import AppKit
@testable import ConceptStudio
import Foundation
import PrevisCore
import SwiftUI
import Testing

@Suite("Viewport editor camera and D0 shells")
struct ViewportEditorCameraTests {
    @Test func fullCircleOrbitReturnsToStartInSingleAndSteppedIncrements() {
        let initial = EditorCamera(
            target: Vec3(1.25, 0.9, -2.4),
            distance: 8.5,
            yaw: 0.42,
            pitch: -0.25,
            focalLength: 35,
            sensor: .super35
        )
        let size = PixelSize(width: 960, height: 540)
        let startFrame = initial.cameraFrame(for: size)

        let singleStep = initial.orbiting(deltaYaw: 2 * .pi, deltaPitch: 0)
        #expect(abs(singleStep.yaw - initial.yaw) < 1e-12)
        #expect(abs(singleStep.pitch - initial.pitch) < 1e-12)
        #expect(distance(singleStep.position, initial.position) < 1e-12)
        #expect(distance(singleStep.cameraFrame(for: size).position, startFrame.position) < 1e-12)

        var stepped = initial
        let steps = 72
        for _ in 0 ..< steps {
            stepped.orbit(deltaYaw: (2 * .pi) / Double(steps), deltaPitch: 0)
        }
        #expect(abs(stepped.yaw - initial.yaw) < 1e-12)
        #expect(abs(stepped.pitch - initial.pitch) < 1e-12)
        #expect(distance(stepped.position, initial.position) < 1e-11)
        #expect(distance(stepped.forward, initial.forward) < 1e-12)
        #expect(distance(stepped.cameraFrame(for: size).position, startFrame.position) < 1e-11)
    }

    @Test func dollyClampsBetweenHalfMetreAndTwoHundredMetres() {
        var camera = EditorCamera(target: .zero, distance: 6.5)

        camera.dolly(delta: -500)
        #expect(camera.distance == 0.5)

        camera.dolly(delta: 500)
        #expect(camera.distance == 200.0)

        camera.dolly(scale: 0.0001)
        #expect(camera.distance == 0.5)

        camera.dolly(scale: 10000)
        #expect(camera.distance == 200.0)

        let belowMin = EditorCamera(target: .zero, distance: 0.01)
        #expect(belowMin.distance == 0.5)

        let aboveMax = EditorCamera(target: .zero, distance: 999.0)
        #expect(aboveMax.distance == 200.0)

        let mid = belowMin.dollying(delta: 4.5)
        #expect(abs(mid.distance - 5.0) < 1e-12)
    }

    @Test(arguments: [
        PixelSize(width: 640, height: 1152),
        PixelSize(width: 320, height: 576),
        PixelSize(width: 1920, height: 1080),
        PixelSize(width: 768, height: 768),
        PixelSize(width: 413, height: 271),
        PixelSize(width: 271, height: 917),
    ])
    func targetProjectsToViewportCentreAcrossArbitraryPixelSizes(size: PixelSize) throws {
        var camera = EditorCamera(
            target: Vec3(-1.8, 1.35, 2.7),
            distance: 11.2,
            yaw: -1.1,
            pitch: -0.37,
            focalLength: 28,
            sensor: .fullFrame
        )
        camera.pan(deltaRight: 0.85, deltaUp: -0.4)

        let projected = try #require(camera.project(camera.target, size: size))
        let centre = Point2(x: Double(size.width) / 2, y: Double(size.height) / 2)
        #expect(abs(projected.x - centre.x) < 1e-9)
        #expect(abs(projected.y - centre.y) < 1e-9)

        let ray = camera.ray(through: centre, size: size)
        let pointAtDistance = Vec3(
            ray.origin.x + ray.direction.x * camera.distance,
            ray.origin.y + ray.direction.y * camera.distance,
            ray.origin.z + ray.direction.z * camera.distance
        )
        #expect(distance(pointAtDistance, camera.target) < 1e-9)
    }

    @Test @MainActor func viewportAndShotCameraShellsRenderReadablyInLightAndDarkAppearances() throws {
        let store = try ShotsStore(
            catalog: ContentCatalog.bundled(),
            document: ShotsSamples.twoPersonWalk(small: true),
            saveURL: nil
        )
        let viewport = ShotsViewport(store: store)
        let shotCamera = ShotCameraView(store: store)
        #expect(viewport.store === store)
        #expect(shotCamera.store === store)

        let captureDir = ProcessInfo.processInfo.environment["SHOTS_D0_PREVIEW_DIR"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
        if let captureDir {
            try FileManager.default.createDirectory(at: captureDir, withIntermediateDirectories: true)
        }

        let sizes = [
            ("minimum", CGSize(width: 980, height: 680)),
            ("default", CGSize(width: 1240, height: 820)),
        ]
        for (theme, scheme, appearanceName) in [
            ("light", ColorScheme.light, NSAppearance.Name.aqua),
            ("dark", ColorScheme.dark, NSAppearance.Name.darkAqua),
        ] {
            for (sizeLabel, size) in sizes {
                let vpURL = captureDir?.appendingPathComponent("d0-viewport-\(theme)-\(sizeLabel).png")
                let camURL = captureDir?.appendingPathComponent("d0-shot-camera-\(theme)-\(sizeLabel).png")
                let vpSpan = try renderAndMeasureContrast(
                    of: viewport.padding(24),
                    size: size,
                    scheme: scheme,
                    appearanceName: appearanceName,
                    outputURL: vpURL
                )
                let camSpan = try renderAndMeasureContrast(
                    of: shotCamera.padding(24),
                    size: size,
                    scheme: scheme,
                    appearanceName: appearanceName,
                    outputURL: camURL
                )
                #expect(vpSpan > 0.45, "ShotsViewport contrast \(vpSpan) too low in \(theme) \(sizeLabel)")
                #expect(camSpan > 0.45, "ShotCameraView contrast \(camSpan) too low in \(theme) \(sizeLabel)")
            }
        }
    }

    @MainActor
    private func renderAndMeasureContrast(
        of view: some View,
        size: CGSize,
        scheme: ColorScheme,
        appearanceName: NSAppearance.Name,
        outputURL: URL?
    ) throws -> Double {
        let originalAppearance = NSApplication.shared.appearance
        defer { NSApplication.shared.appearance = originalAppearance }
        let appearance = try #require(NSAppearance(named: appearanceName))
        NSApplication.shared.appearance = appearance
        let content = view
            .environment(\.colorScheme, scheme)
            .frame(width: size.width, height: size.height)
            .background(InstantPrint.ground)
        let host = NSHostingView(rootView: content)
        host.appearance = appearance
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.contentView = host
        defer {
            window.contentView = nil
            window.close()
        }
        var bitmap: NSBitmapImageRep?
        appearance.performAsCurrentDrawingAppearance {
            host.layoutSubtreeIfNeeded()
            bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)
            if let bitmap { host.cacheDisplay(in: host.bounds, to: bitmap) }
        }
        let rep = try #require(bitmap)
        if let outputURL, let png = rep.representation(using: .png, properties: [:]) {
            try png.write(to: outputURL, options: .atomic)
        }
        guard let ptr = rep.bitmapData else { return 0 }
        let bytesPerRow = rep.bytesPerRow
        var minLuma = 1.0
        var maxLuma = 0.0
        for y in stride(from: 16, to: rep.pixelsHigh - 16, by: 4) {
            for x in stride(from: 16, to: rep.pixelsWide - 16, by: 4) {
                let offset = y * bytesPerRow + x * 4
                let r = Double(ptr[offset]) / 255.0
                let g = Double(ptr[offset + 1]) / 255.0
                let b = Double(ptr[offset + 2]) / 255.0
                let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
                minLuma = min(minLuma, luma)
                maxLuma = max(maxLuma, luma)
            }
        }
        return maxLuma - minLuma
    }

    private func distance(_ a: Vec3, _ b: Vec3) -> Double {
        let dx = a.x - b.x
        let dy = a.y - b.y
        let dz = a.z - b.z
        return (dx * dx + dy * dy + dz * dz).squareRoot()
    }
}
