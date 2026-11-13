import AVFoundation
import CoreGraphics
import Foundation
import PrevisCore

/// The sandbox spike: renders and encodes the full sample's clean video into the app's temporary folder, reads
/// it back, and prints a JSON report. Lane C wires `--shots-self-test` to it. Returns 0 when the video checks out.
@MainActor public enum ShotsSelfTest {
    /// A checked frame's presentation time, like "61/24".
    struct FrameTime: Codable, Equatable {
        var frame: Int
        var time: String
    }

    struct Report: Codable, Equatable {
        var ok: Bool
        var frames: Int?
        var width: Int?
        var height: Int?
        var codec: String?
        var bt709: Bool?
        var presentationTimes: [FrameTime]?
        var seconds: Double?
        var video: String?
        var problems: [String] = []
        var reason: String?
    }

    struct PlateReport: Codable {
        var ok: Bool
        var size: PixelSize
        var frameCount: Int
        var packagePath: String?
        var problems: [String]
    }

    public static func run() async -> Int32 {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("shots-self-test", isDirectory: true)
        let report = await report(in: folder)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let fallback = #"{"ok":false,"reason":"The report couldn't be encoded."}"#
        let json = (try? encoder.encode(report)) ?? Data(fallback.utf8)
        FileHandle.standardOutput.write(json + Data("\n".utf8))
        return report.ok ? 0 : 1
    }

    /// Exercises plate composition and controls inside the signed app's sandbox using only synthetic content.
    public static func runPlate() async -> Int32 {
        let size = PixelSize(width: 288, height: 512)
        let frameCount = 22
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("shots-plate-self-test", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let report: PlateReport
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let image = try PassDrawing.image(size: size) { context in
                context.setFillColor(CGColor(srgbRed: 0.35, green: 0.45, blue: 0.55, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height))
                context.setFillColor(CGColor(srgbRed: 0.2, green: 0.3, blue: 0.4, alpha: 1))
                context.fill(CGRect(x: 0, y: size.height / 2, width: size.width, height: size.height / 2))
            }
            try StillWriter.writePNG(image, to: folder.appendingPathComponent("plate.png"))
            let scene = plateScene(size: size, frameCount: frameCount)
            let exporter = try ShotExporter(catalog: ContentCatalog.bundled(), plateRoot: folder)
            let package = try await exporter.export(
                scene: scene, shotID: "plate-shot", options: ExportOptions(passes: [.pose, .layout]),
                to: FolderDestination(parent: folder.appendingPathComponent("exports")), progress: { _ in }
            )
            let problems = await PackageValidator.problems(at: package.url)
            report = PlateReport(
                ok: problems.isEmpty, size: package.manifest.canvas.pixelSize,
                frameCount: package.manifest.frameCount, packagePath: package.url.path, problems: problems
            )
        } catch {
            report = PlateReport(
                ok: false, size: size, frameCount: frameCount, packagePath: nil,
                problems: [error.localizedDescription]
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let fallback = #"{"ok":false,"problems":["The plate report could not be encoded."]}"#
        FileHandle.standardOutput.write(((try? encoder.encode(report)) ?? Data(fallback.utf8)) + Data("\n".utf8))
        return report.ok ? 0 : 1
    }

    private static func plateScene(size: PixelSize, frameCount: Int) -> PrevisScene {
        var scene = PrevisScene.make(
            id: "plate-scene", name: "Plate sandbox probe", takeID: "plate-take",
            shotID: "plate-shot", cameraMarkID: "plate-camera"
        )
        scene.shots[0].frameCount = frameCount
        scene.shots[0].canvas = ShotCanvas(width: size.width, height: size.height)
        scene.shots[0].plateID = "plate"
        scene.shots[0].camera.marks[0].focalLength = 20
        scene.plates = [LocationPlate(
            id: "plate", name: "Synthetic plate", imagePath: "plate.png", pixelSize: size,
            calibration: PlateCalibration(focalLength: 20, confirmed: true)
        )]
        scene.setPieces = [PlateSetPiece(
            id: "table", name: "Table", position: Vec3(0, 0, 1), size: Vec3(2, 0.7, 0.4),
            supportsStanding: false
        )]
        scene.entities = [PrevisEntity(
            id: "stand-in", assetID: "person.man", name: "Stand-in",
            placement: Placement(position: .zero, heading: .pi, scale: 1)
        )]
        return scene
    }

    static func report(in folder: URL) async -> Report {
        let clock = ContinuousClock()
        let start = clock.now
        do {
            guard let scene = ShotsSamples.twoPersonWalk().scenes.first, let shot = scene.shots.first else {
                throw ShotsMediaError("The built-in sample has no shot to render.")
            }
            let evaluator = try ShotEvaluator(scene: scene, shotID: shot.id, catalog: ContentCatalog.bundled())
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent("clean.mp4")
            try await ShotFrameRenderer().writeCleanVideo(of: evaluator, look: PrevisLook(scene: scene), to: url)
            let elapsed = start.duration(to: clock.now)
            var report = try await report(on: url, frameCount: evaluator.frameCount, size: shot.canvas.pixelSize)
            report.seconds = (Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
                .rounded(toPlaces: 3)
            return report
        } catch {
            return Report(ok: false, reason: error.localizedDescription)
        }
    }

    /// Reads a written video back into a report: it passes when the video holds `frameCount` frames at `size`.
    static func report(on url: URL, frameCount: Int, size: PixelSize) async throws -> Report {
        let facts = try await VideoInspector.facts(url)
        let problems = VideoInspector.problems(
            in: facts,
            name: url.lastPathComponent,
            frameCount: frameCount,
            size: size
        )
        return Report(
            ok: problems.isEmpty,
            frames: facts.frameCount,
            width: facts.width,
            height: facts.height,
            codec: facts.codec,
            bt709: facts.isBT709,
            presentationTimes: VideoInspector.checkedFrames(facts.frameCount).map {
                FrameTime(frame: $0, time: describe(facts.presentationTimes[$0]))
            },
            video: url.path,
            problems: problems
        )
    }

    /// "61/24" when the time falls on the 24 fps grid, otherwise the raw value over its timescale.
    static func describe(_ time: CMTime) -> String {
        let scaled = time.value * 24
        if time.timescale > 0, scaled.isMultiple(of: CMTimeValue(time.timescale)) {
            return "\(scaled / CMTimeValue(time.timescale))/24"
        }
        return "\(time.value)/\(time.timescale)"
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let scale = pow(10, Double(places))
        return (self * scale).rounded() / scale
    }
}
