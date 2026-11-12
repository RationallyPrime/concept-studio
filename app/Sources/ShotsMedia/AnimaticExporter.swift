import CoreGraphics
import CoreText
import Foundation
import PrevisCore

/// Renders the clean cuts straight into one frame-exact video and writes its cut list beside it.
@MainActor public struct AnimaticExporter {
    public let catalog: ContentCatalog

    public init(catalog: ContentCatalog) {
        self.catalog = catalog
    }

    public func export(
        scene: PrevisScene,
        burnIn: Bool,
        to parent: URL,
        audioDirectory: URL? = nil,
        progress: @escaping (ExportProgress) -> Void
    ) async throws -> URL {
        guard let first = scene.shots.first else { throw ShotsMediaError("Add a shot to export this scene.") }
        let list = try SceneCutList(scene: scene)
        let problems = ShotsValidation.problems(in: ShotsDocument(version: 1, scenes: [scene]), catalog: catalog)
            .filter { $0.severity == .error }
        guard problems.isEmpty else { throw ShotsError.invalid(problems) }
        let evaluators = try scene.shots.map { try ShotEvaluator(scene: scene, shotID: $0.id, catalog: catalog) }
        let renderer = try ShotFrameRenderer()
        let look = PrevisLook(lighting: scene.lighting)
        let staging = parent.appendingPathComponent(".animatic-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let videoURL = staging.appendingPathComponent("animatic.mp4")
        var cutIndex = 0
        try await VideoWriter.write(
            to: videoURL,
            size: first.canvas.pixelSize,
            frameCount: list.frameCount,
            progress: { frame in
                progress(ExportProgress(
                    step: "Rendering \(scene.shots[cutIndex].name)…",
                    fractionCompleted: Double(frame + 1) / Double(list.frameCount)
                ))
            },
            draw: { buffer, index in
                if index == list.cuts[cutIndex].endFrame { cutIndex += 1 }
                let shot = scene.shots[cutIndex]
                let localIndex = index - list.cuts[cutIndex].startFrame
                let frame = evaluators[cutIndex].frame(localIndex)
                if shot.canvas == first.canvas, !burnIn {
                    try await renderer.render(frame, look: look, into: buffer)
                } else {
                    let image = try await renderer.image(of: frame, look: look)
                    try PassDrawing.draw(into: buffer) { context in
                        draw(
                            image,
                            in: first.canvas,
                            using: context,
                            label: burnIn ? label(shot.name, frame: index) : nil
                        )
                    }
                }
            }
        )
        if scene.shots.contains(where: { !$0.audioClips.isEmpty }) {
            let edits = zip(scene.shots, list.cuts).map { ($0, $1.startFrame, $1.endFrame) }
            let muxed = staging.appendingPathComponent("muxed.mp4")
            if try await ScratchAudioMix.attach(
                shots: edits, sourceDirectory: audioDirectory, to: videoURL, output: muxed
            ) {
                _ = try FileManager.default.replaceItemAt(videoURL, withItemAt: muxed)
            }
        }
        let videoProblems = await VideoInspector.problems(
            videoURL, frameCount: list.frameCount, size: first.canvas.pixelSize
        )
        guard videoProblems.isEmpty else { throw ShotsMediaError(videoProblems.joined(separator: " ")) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(list).write(to: staging.appendingPathComponent("cut-list.json"))
        try Task.checkCancellation()
        let base = "\(PackageNames.slug(scene.name))-animatic-\(PackageNames.stamp(Date()))"
        var target = parent.appendingPathComponent(base, isDirectory: true)
        var suffix = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = parent.appendingPathComponent("\(base)-\(suffix)", isDirectory: true)
            suffix += 1
        }
        try FileManager.default.moveItem(at: staging, to: target)
        return target
    }

    private func label(_ shot: String, frame: Int) -> String {
        let seconds = frame / FrameGrid.fps
        let timecode = String(
            format: "%02d:%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60, frame % FrameGrid.fps
        )
        return "\(shot)  \(timecode)"
    }

    private func draw(_ image: CGImage, in canvas: ShotCanvas, using context: CGContext, label: String?) {
        let width = Double(canvas.width), height = Double(canvas.height)
        // PassDrawing provides a top-left origin. CGImage and Core Text draw in the usual Quartz coordinates.
        context.translateBy(x: 0, y: height)
        context.scaleBy(x: 1, y: -1)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let fit = min(width / Double(image.width), height / Double(image.height))
        let w = Double(image.width) * fit, h = Double(image.height) * fit
        context.draw(image, in: CGRect(x: (width - w) / 2, y: (height - h) / 2, width: w, height: h))
        guard let label else { return }
        let fontSize = max(9, width * 0.024)
        let text = NSAttributedString(string: label, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(
                "Menlo" as CFString,
                fontSize,
                nil
            ),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
        ])
        let line = CTLineCreateWithAttributedString(text)
        let pad = max(4, fontSize / 2)
        context.setFillColor(CGColor(gray: 0, alpha: 0.75))
        let lineWidth = CTLineGetTypographicBounds(line, nil, nil, nil)
        context.fill(CGRect(x: pad, y: pad, width: lineWidth + 2 * pad, height: fontSize + 2 * pad))
        context.textPosition = CGPoint(x: 2 * pad, y: 2 * pad + fontSize * 0.15)
        CTLineDraw(line, context)
    }
}
