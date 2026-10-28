import AppKit
@testable import ConceptStudio
import CoreGraphics
import Foundation
import ImageIO
import PrevisCore
import ShotsMedia
import SwiftUI
import Testing

private let lookThroughRenderingEnabled = ShotFrameRenderer.isAvailable
    && ProcessInfo.processInfo.environment["SHOTS_SKIP_RENDER"] == nil

@Suite("Viewport D5 look-through rendering and coalescing")
@MainActor
struct ViewportLookThroughTests {
    @Test(.enabled(if: lookThroughRenderingEnabled))
    func lookThroughFrameElevenMatchesExportedMiddleGuideCleanPNGAsDecodedRGB() async throws {
        let catalog = try ContentCatalog.bundled()
        let document = ShotsSamples.twoPersonWalk(small: true)
        let store = ShotsStore(catalog: catalog, document: document, saveURL: nil)
        let scene = try #require(store.currentScene)
        let shot = try #require(store.currentShot)
        #expect(shot.frameCount == 22)
        #expect(shot.canvas == ShotCanvas(width: 320, height: 576))
        #expect(shot.guideFrames == [11])

        store.playhead = 11
        let session = ShotCameraPreviewSession()
        session.requestRender(for: store)
        await session.waitForIdle()

        let lookThroughImage = try #require(session.renderedImage)
        #expect(session.errorMessage == nil)
        #expect(!session.isRendering)
        #expect(session.renderedRequest?.frame.index == 11)
        #expect(lookThroughImage.width == 320)
        #expect(lookThroughImage.height == 576)

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("shots-d5-parity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let package = try await ShotExporter(catalog: catalog).export(
            scene: scene,
            shotID: shot.id,
            options: ExportOptions(passes: [.clean]),
            to: FolderDestination(parent: tempRoot),
            progress: { _ in }
        )
        let guideURL = package.url.appendingPathComponent("guides/middle-f0011-clean.png")
        let exportedImage = try decodePNGImage(at: guideURL)
        #expect(exportedImage.width == 320)
        #expect(exportedImage.height == 576)

        let lookThroughRGB = try decodedSRGBBytes(of: lookThroughImage)
        let exportedRGB = try decodedSRGBBytes(of: exportedImage)
        #expect(lookThroughRGB.count == 320 * 576 * 3)
        #expect(lookThroughRGB == exportedRGB)

        // Control: frame 0 look-through differs from frame 11 exported middle guide.
        store.playhead = 0
        session.requestRender(for: store)
        await session.waitForIdle()
        let frameZeroRGB = try decodedSRGBBytes(of: #require(session.renderedImage))
        #expect(frameZeroRGB != exportedRGB)
    }

    @Test
    func coalescingCollapsesIntermediateRequestsToLatestWhileOneRenderIsInFlight() async throws {
        let catalog = try ContentCatalog.bundled()
        let store = ShotsStore(
            catalog: catalog,
            document: ShotsSamples.twoPersonWalk(small: true),
            saveURL: nil
        )
        var renderedIndices: [Int] = []
        var gates: [CheckedContinuation<Void, Never>] = []

        let session = ShotCameraPreviewSession { frame, _ in
            let index = frame.index ?? -1
            renderedIndices.append(index)
            await withCheckedContinuation { continuation in
                gates.append(continuation)
            }
            return try makeSolidImage(
                width: frame.canvas.width,
                height: frame.canvas.height,
                red: UInt8(clamping: index * 10)
            )
        }

        store.playhead = 0
        session.requestRender(for: store)
        while gates.isEmpty {
            await Task.yield()
        }
        #expect(renderedIndices == [0])
        #expect(session.isRendering)

        // Queue multiple intermediate playhead frames while frame 0 is still in flight.
        for frameIndex in [3, 7, 11, 18] {
            store.playhead = frameIndex
            session.requestRender(for: store)
        }
        #expect(renderedIndices == [0])

        // Release frame 0; only the latest request (18) should start next.
        gates.removeFirst().resume()
        while gates.isEmpty {
            await Task.yield()
        }
        #expect(renderedIndices == [0, 18])

        gates.removeFirst().resume()
        await session.waitForIdle()

        #expect(!session.isRendering)
        #expect(session.errorMessage == nil)
        #expect(renderedIndices == [0, 18])
        #expect(session.renderedRequest?.frame.index == 18)
        let terminalBytes = try decodedSRGBBytes(of: #require(session.renderedImage))
        #expect(terminalBytes.first == 180)
    }

    @Test
    func retainedImageCaptionAndAccessibilityIdentifyDisplayedFrameWhileNewerRenderIsPending() async throws {
        let store = try ShotsStore(
            catalog: ContentCatalog.bundled(),
            document: ShotsSamples.twoPersonWalk(small: true),
            saveURL: nil
        )
        var pendingGate: CheckedContinuation<Void, Never>?
        let session = ShotCameraPreviewSession { frame, _ in
            if frame.index == 11 {
                await withCheckedContinuation { continuation in
                    pendingGate = continuation
                }
            }
            return try makeSolidImage(
                width: frame.canvas.width,
                height: frame.canvas.height,
                red: frame.index == 11 ? 210 : 30
            )
        }
        let view = ShotCameraView(store: store, session: session)

        // 1. Initial control: render frame 0 to completion.
        store.playhead = 0
        session.requestRender(for: store)
        await session.waitForIdle()
        #expect(session.renderedImage != nil)
        #expect(session.renderedRequest?.frame.index == 0)
        #expect(view.captionText == "Shot 1A · 320 × 576 · Frame 0")
        #expect(view.accessibilityLabelText == "Shot camera preview. Shot 1A · 320 × 576 · Frame 0")

        // 2. Gated pending regression: set playhead 11 and hold frame 11 render while frame 0 image remains shown.
        store.playhead = 11
        session.requestRender(for: store)
        while pendingGate == nil {
            await Task.yield()
        }
        #expect(session.isRendering)
        #expect(session.renderedImage != nil)
        #expect(session.renderedRequest?.frame.index == 0)
        #expect(view.captionText == "Shot 1A · 320 × 576 · Frame 0")
        #expect(view.accessibilityLabelText == "Shot camera preview. Shot 1A · 320 × 576 · Frame 0")

        // 3. Completed control: release frame 11 render; image, request, caption and accessibility label all match 11.
        pendingGate?.resume()
        pendingGate = nil
        await session.waitForIdle()
        #expect(!session.isRendering)
        #expect(session.renderedRequest?.frame.index == 11)
        #expect(view.captionText == "Shot 1A · 320 × 576 · Frame 11")
        #expect(view.accessibilityLabelText == "Shot camera preview. Shot 1A · 320 × 576 · Frame 11")
        let completedBytes = try decodedSRGBBytes(of: #require(session.renderedImage))
        #expect(completedBytes.first == 210)
    }

    @Test
    func switchingShotOrClearingActiveShotPreventsStaleInFlightCompletionFromOverwriting() async throws {
        let catalog = try ContentCatalog.bundled()
        let store = ShotsStore(
            catalog: catalog,
            document: ShotsSamples.twoPersonWalk(small: true),
            saveURL: nil
        )
        let firstShotID = try #require(store.currentShotID)
        try store.perform(.duplicateShot(firstShotID, newID: "shot_second"))
        var gates: [CheckedContinuation<Void, Never>] = []

        let session = ShotCameraPreviewSession { frame, _ in
            await withCheckedContinuation { continuation in
                gates.append(continuation)
            }
            return try makeSolidImage(
                width: frame.canvas.width,
                height: frame.canvas.height,
                red: UInt8(clamping: (frame.index ?? 0) + 1)
            )
        }

        store.currentShotID = firstShotID
        store.playhead = 2
        session.requestRender(for: store)
        while gates.isEmpty {
            await Task.yield()
        }

        // Switch to shot_second while firstShotID's render is still suspended.
        store.currentShotID = "shot_second"
        store.playhead = 9
        session.requestRender(for: store)
        #expect(session.renderedImage == nil)
        #expect(session.renderedRequest == nil)

        // Release firstShotID's render; its stale result must not populate shot_second.
        gates.removeFirst().resume()
        while gates.isEmpty {
            await Task.yield()
        }
        #expect(session.renderedImage == nil)
        #expect(session.renderedRequest == nil)

        // Release shot_second's render; it becomes the rendered state.
        gates.removeFirst().resume()
        await session.waitForIdle()
        #expect(session.renderedRequest?.shotID == "shot_second")
        #expect(session.renderedRequest?.frame.index == 9)
        #expect(session.renderedImage != nil)

        // Now start another render, then delete the scene so currentShot becomes nil before completion.
        store.playhead = 12
        session.requestRender(for: store)
        while gates.isEmpty {
            await Task.yield()
        }
        let sceneID = try #require(store.currentSceneID)
        try store.perform(.deleteScene(sceneID))
        #expect(store.currentShot == nil)
        session.requestRender(for: store)
        #expect(session.renderedImage == nil)
        #expect(session.renderedRequest == nil)
        #expect(!session.isRendering)

        gates.removeFirst().resume()
        await session.waitForIdle()
        #expect(session.renderedImage == nil)
        #expect(session.renderedRequest == nil)
    }
}

@MainActor
extension ViewportLookThroughTests {
    @Test
    func renderErrorReportsToStoreWithoutSilentSuccessAndRecoversOnSubsequentRender() async throws {
        let catalog = try ContentCatalog.bundled()
        let store = ShotsStore(
            catalog: catalog,
            document: ShotsSamples.twoPersonWalk(small: true),
            saveURL: nil
        )
        var reportedErrors: [String] = []
        store.onError = { reportedErrors.append($0) }

        let session = ShotCameraPreviewSession { frame, _ in
            if frame.index == 4 {
                throw ShotsMediaError("Synthetic GPU failure.")
            }
            return try self.makeSolidImage(width: frame.canvas.width, height: frame.canvas.height, red: 77)
        }

        store.playhead = 4
        session.requestRender(for: store)
        await session.waitForIdle()

        #expect(!session.isRendering)
        #expect(session.renderedImage == nil)
        #expect(session.renderedRequest == nil)
        #expect(session.errorMessage == "Synthetic GPU failure.")
        #expect(reportedErrors == ["Synthetic GPU failure."])
        let view = ShotCameraView(store: store, session: session)
        #expect(view.accessibilityLabelText.contains("Synthetic GPU failure."))

        store.playhead = 6
        session.requestRender(for: store)
        await session.waitForIdle()

        #expect(!session.isRendering)
        #expect(session.errorMessage == nil)
        #expect(session.renderedRequest?.frame.index == 6)
        #expect(session.renderedImage != nil)
    }

    @Test
    func hostedShotCameraViewRendersLetterboxedCanvasAndUpdatesOnPlayheadChange() async throws {
        let store = try ShotsStore(
            catalog: ContentCatalog.bundled(),
            document: ShotsSamples.twoPersonWalk(small: true),
            saveURL: nil
        )
        let session = ShotCameraPreviewSession { frame, _ in
            try self.makeSolidImage(
                width: frame.canvas.width,
                height: frame.canvas.height,
                red: frame.index == 11 ? 220 : 40
            )
        }
        let hostSize = CGSize(width: 640, height: 480)
        let host = NSHostingView(
            rootView: ShotCameraView(store: store, session: session)
                .frame(width: hostSize.width, height: hostSize.height)
        )
        host.frame = CGRect(origin: .zero, size: hostSize)
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: hostSize),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer {
            window.contentView = nil
            window.close()
        }
        host.layoutSubtreeIfNeeded()
        await session.waitForIdle()
        #expect(session.renderedRequest?.frame.index == 0)

        store.playhead = 11
        await Task.yield()
        host.layoutSubtreeIfNeeded()
        await session.waitForIdle()
        #expect(session.renderedRequest?.frame.index == 11)
        let renderedBytes = try decodedSRGBBytes(of: #require(session.renderedImage))
        #expect(renderedBytes.first == 220)
    }

    @Test
    func letterboxRectFitsPortraitLandscapeAndSquareCanvasesAndUpdatesRequestOnCanvasAndLightingEdits() throws {
        let portrait = ShotCanvas(width: 640, height: 1152)
        let landscape = ShotCanvas(width: 1152, height: 640)
        let square = ShotCanvas(width: 768, height: 768)

        let pillarboxed = ShotCameraView.letterboxRect(in: CGSize(width: 800, height: 576), canvas: portrait)
        #expect(abs(pillarboxed.width - 320) < 1e-6)
        #expect(abs(pillarboxed.height - 576) < 1e-6)
        #expect(abs(pillarboxed.origin.x - 240) < 1e-6)
        #expect(abs(pillarboxed.origin.y) < 1e-6)

        let letterboxed = ShotCameraView.letterboxRect(in: CGSize(width: 576, height: 800), canvas: landscape)
        #expect(abs(letterboxed.width - 576) < 1e-6)
        #expect(abs(letterboxed.height - 320) < 1e-6)
        #expect(abs(letterboxed.origin.x) < 1e-6)
        #expect(abs(letterboxed.origin.y - 240) < 1e-6)

        let squareFit = ShotCameraView.letterboxRect(in: CGSize(width: 600, height: 600), canvas: square)
        #expect(squareFit == CGRect(x: 0, y: 0, width: 600, height: 600))
        #expect(ShotCameraView.letterboxRect(in: .zero, canvas: portrait) == .zero)

        let store = try ShotsStore(
            catalog: ContentCatalog.bundled(),
            document: ShotsSamples.twoPersonWalk(small: true),
            saveURL: nil
        )
        let sceneID = try #require(store.currentSceneID)
        let shotID = try #require(store.currentShotID)
        try store.perform(.setLighting(sceneID, .night))
        try store.perform(.setCanvas(shotID, ShotCanvas(width: 640, height: 640)))
        let request = try #require(ShotCameraRenderRequest.make(from: store))
        #expect(request.look == PrevisLook(lighting: .night))
        #expect(request.frame.canvas == ShotCanvas(width: 640, height: 640))
    }

    func decodePNGImage(at url: URL) throws -> CGImage {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    func decodedSRGBBytes(of image: CGImage) throws -> [UInt8] {
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var rgba = [UInt8](repeating: 0, count: bytesPerRow * height)
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        try rgba.withUnsafeMutableBytes { rawBuffer in
            let baseAddress = try #require(rawBuffer.baseAddress)
            let context = try #require(CGContext(
                data: baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var rgb = [UInt8]()
        rgb.reserveCapacity(width * height * 3)
        for pixelIndex in 0 ..< (width * height) {
            let offset = pixelIndex * 4
            rgb.append(rgba[offset])
            rgb.append(rgba[offset + 1])
            rgb.append(rgba[offset + 2])
        }
        return rgb
    }

    func makeSolidImage(width: Int, height: Int, red: UInt8) throws -> CGImage {
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(CGColor(
            srgbRed: CGFloat(red) / 255.0,
            green: 0.25,
            blue: 0.5,
            alpha: 1.0
        ))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }
}
