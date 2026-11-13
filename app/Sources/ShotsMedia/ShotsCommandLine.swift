import ConceptCore
import Foundation
import PrevisCore

/// All of `shots-export`'s logic, so tests run it in-process.
public enum ShotsCommandLine {
    static let usage = """
    usage: shots-export --sample --out <dir>
           shots-export --blockout <project.json> [--scene <id|index>] [--shot <id|name>] --out <dir>
           shots-export --document <shots.json> --shot <id> [--plates <dir>] --out <dir>
           shots-export --plate-sample <plate image> --out <dir>
           shots-export --document <shots.json> --block <briefs.json> [--scene <id|index>]
           Blockout input also takes [--frames N] [--canvas WxH] [--passes clean,pose,layout,matte].
           --plates is the folder of plate images; by default the Shots/Plates folder beside the document's project.
           --plate-sample blocks the built-in throne-room sample over your image, to see a plate export.
           shots-export --document <shots.json> --shot <id> [--plates <dir>] --fit-check <picture.png>
           --block places the shots a briefs file describes and saves them into the document; it exports nothing.
           --fit-check writes one picture: the shot's first frame over its plate with the set pieces showing
           faintly and names on the stand-ins, to check how the camera match and the set pieces sit.
    Writes one validated shot package and prints its path.

    """

    /// 0 when a valid package was written, 1 when the export failed, 2 for a usage error.
    @MainActor public static func run(arguments: [String]) async -> Int32 {
        if arguments.contains("--block") { return block(arguments: arguments) }
        if arguments.contains("--fit-check") { return await fitCheck(arguments: arguments) }
        do {
            let job = try Job(arguments: arguments)
            let catalog = try ContentCatalog.bundled()
            let (scene, shotID) = try job.shot(catalog: catalog)
            var options = job.options
            options.plateFolder = job.plateFolder
            let package = try await ShotExporter(catalog: catalog).export(
                scene: scene,
                shotID: shotID,
                options: options,
                to: FolderDestination(parent: URL(fileURLWithPath: job.out, isDirectory: true)),
                progress: { _ in }
            )
            if let prompt = scene.shots.first(where: { $0.id == shotID })?.prompt {
                for problem in ShotPromptCompiler.problems(prompt, scene: scene) {
                    FileHandle.standardError.write(Data("note: \(problem)\n".utf8))
                }
            }
            FileHandle.standardOutput.write(Data((package.url.path + "\n").utf8))
            return 0
        } catch let error as UsageError {
            FileHandle.standardError.write(Data("shots-export: \(error.message)\n\(usage)".utf8))
            return 2
        } catch {
            FileHandle.standardError.write(Data("shots-export: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }
}

extension ShotsCommandLine {
    /// `--document <shots.json> --shot <id> [--plates <dir>] --fit-check <picture.png>`: what the app's shot-camera
    /// view shows for the first frame, as a file.
    @MainActor static func fitCheck(arguments: [String]) async -> Int32 {
        do {
            var values: [String: String] = [:]
            var remaining = arguments[...]
            while let argument = remaining.popFirst() {
                guard ["--document", "--shot", "--plates", "--fit-check"].contains(argument) else {
                    throw UsageError("--fit-check takes --document, --shot and --plates only, not \(argument).")
                }
                guard let value = remaining.popFirst() else { throw UsageError("\(argument) needs a value.") }
                values[argument] = value
            }
            guard let path = values["--document"], let shotID = values["--shot"], let out = values["--fit-check"] else {
                throw UsageError("--fit-check needs --document <shots.json>, --shot <id> and a picture to write.")
            }
            let url = URL(fileURLWithPath: path)
            let document = try JSONDecoder().decode(ShotsDocument.self, from: Data(contentsOf: url))
            guard let scene = document.scenes.first(where: { $0.shots.contains { $0.id == shotID } }),
                  let shot = scene.shots.first(where: { $0.id == shotID })
            else { throw ShotsMediaError("\(path) has no shot with id \(shotID).") }
            let frame = try ShotEvaluator(scene: scene, shotID: shotID, catalog: ContentCatalog.bundled()).frame(0)
            guard let plate = frame.plate else {
                throw ShotsMediaError("Shot \"\(shot.name)\" isn't blocked over a plate, so there is no fit to check.")
            }
            let folder = values["--plates"].map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? PlateImages.folder(inProject: url.deletingLastPathComponent().deletingLastPathComponent())
            let image = try await ShotFrameRenderer().image(
                of: frame, over: PlateImages.read(folder.appendingPathComponent(plate.file), name: plate.name),
                look: PrevisLook(scene: scene), options: .blocking, sensor: shot.camera.sensor,
                size: (shot.keyCanvas ?? ShotCanvas(width: plate.size.width, height: plate.size.height)).pixelSize
            )
            try StillWriter.writePNG(image, to: URL(fileURLWithPath: out))
            FileHandle.standardOutput.write(Data((out + "\n").utf8))
            return 0
        } catch let error as UsageError {
            FileHandle.standardError.write(Data("shots-export: \(error.message)\n\(usage)".utf8))
            return 2
        } catch {
            FileHandle.standardError.write(Data("shots-export: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    /// `--document <shots.json> --block <briefs.json> [--scene <id|index>]`: blocks each brief in the scene (the
    /// first by default) and saves the document, so the shots can be reviewed in the app. Prints each shot's id and
    /// staging, and the solver's notes. Nothing is saved when any brief fails.
    static func block(arguments: [String]) -> Int32 {
        do {
            var values: [String: String] = [:]
            var remaining = arguments[...]
            while let argument = remaining.popFirst() {
                guard ["--document", "--block", "--scene"].contains(argument) else {
                    throw UsageError("--block takes --document, --block and --scene only, not \(argument).")
                }
                guard let value = remaining.popFirst() else { throw UsageError("\(argument) needs a value.") }
                values[argument] = value
            }
            guard let path = values["--document"], let briefsPath = values["--block"] else {
                throw UsageError("--block needs --document <shots.json> and --block <briefs.json>.")
            }
            let url = URL(fileURLWithPath: path)
            var document = try JSONDecoder().decode(ShotsDocument.self, from: Data(contentsOf: url))
            guard document.version <= ShotsDocument.currentVersion else {
                throw ShotsMediaError(
                    "\(path) is shots format \(document.version); this build reads up to "
                        + "\(ShotsDocument.currentVersion)."
                )
            }
            let data = try Data(contentsOf: URL(fileURLWithPath: briefsPath))
            let briefs: [BlockingBrief]
            do {
                briefs = try (try? JSONDecoder().decode([BlockingBrief].self, from: data))
                    ?? [JSONDecoder().decode(BlockingBrief.self, from: data)]
            } catch {
                throw ShotsMediaError("\(briefsPath) isn't a blocking brief or a list of them: \(error)")
            }
            let key = values["--scene"]
            guard let index = key.map({ key in
                document.scenes.firstIndex { $0.id == key } ?? Int(key).flatMap {
                    document.scenes.indices.contains($0) ? $0 : nil
                }
            }) ?? (document.scenes.isEmpty ? nil : 0) else {
                throw ShotsMediaError("\(path) has no scene \(key ?? "at all"): give a scene id or an index from 0.")
            }
            let catalog = try ContentCatalog.bundled()
            var scene = document.scenes[index]
            var report = ""
            for brief in briefs {
                let result = try BlockingSolver.apply(brief, to: &scene, catalog: catalog)
                let staging = try ShotEvaluator(scene: scene, shotID: result.shotID, catalog: catalog).staging()
                report += "\(brief.shot)\t\(result.shotID)\n" + staging.description() + "\n"
                report += result.notes.map { "note: \($0)\n" }.joined() + "\n"
            }
            scene.revision += 1
            document.scenes[index] = scene
            document.version = ShotsDocument.currentVersion
            let problems = ShotsValidation.problems(in: document, catalog: catalog).filter { $0.severity == .error }
            guard problems.isEmpty else { throw ShotsError.invalid(problems) }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try AtomicFile.write(encoder.encode(document), to: url)
            FileHandle.standardOutput.write(Data(report.utf8))
            return 0
        } catch let error as UsageError {
            FileHandle.standardError.write(Data("shots-export: \(error.message)\n\(usage)".utf8))
            return 2
        } catch {
            FileHandle.standardError.write(Data("shots-export: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }
}

/// A command line that asks for something `shots-export` doesn't do.
struct UsageError: Error {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}

/// One parsed command line: which shot to export, with which passes, to where.
struct Job {
    enum Input: Equatable {
        case sample
        case blockout(path: String, scene: String?, shot: String?)
        case document(path: String, shot: String)
        case plateSample(image: String)
    }

    var input: Input
    var out: String
    var options = ExportOptions.standard
    var frameCount: Int?
    var canvas: ShotCanvas?

    private static let valueOptions: Set = [
        "--out",
        "--blockout",
        "--document",
        "--scene",
        "--shot",
        "--frames",
        "--canvas",
        "--passes",
        "--plates",
        "--plate-sample",
    ]

    var plates: String?

    /// Where the plate images are: `--plates`, or the project's `Shots/Plates` beside a document at
    /// `<project>/.conceptstudio/shots.json`, or the folder of the sample's image.
    var plateFolder: URL? {
        if let plates { return URL(fileURLWithPath: plates, isDirectory: true) }
        switch input {
        case let .document(path, _):
            let project = URL(fileURLWithPath: path).deletingLastPathComponent().deletingLastPathComponent()
            return PlateImages.folder(inProject: project)
        case let .plateSample(image):
            return URL(fileURLWithPath: image).deletingLastPathComponent()
        case .sample, .blockout:
            return nil
        }
    }

    /// Checks every option before anything is read, so a usage error never leaves a half-done export.
    init(arguments: [String]) throws {
        var values: [String: String] = [:]
        var sample = false
        var remaining = arguments[...]
        while let argument = remaining.popFirst() {
            if argument == "--sample" {
                sample = true
            } else if Self.valueOptions.contains(argument) {
                guard let value = remaining.popFirst() else { throw UsageError("\(argument) needs a value.") }
                values[argument] = value
            } else {
                throw UsageError("Unknown argument \(argument).")
            }
        }
        guard let out = values["--out"] else { throw UsageError("--out <dir> is required.") }
        self.out = out
        plates = values["--plates"]
        input = try Self.input(sample: sample, values: values)
        if plates != nil, case .document = input {} else if plates != nil {
            throw UsageError("--plates applies to --document only.")
        }
        if case .blockout = input {
            frameCount = try values["--frames"].map(Self.frameCount)
            canvas = try values["--canvas"].map(Self.canvas)
            options = try values["--passes"].map(Self.passes) ?? .standard
        } else if let option = ["--scene", "--frames", "--canvas", "--passes"].first(where: { values[$0] != nil }) {
            throw UsageError("\(option) applies to Blockout input only.")
        } else if input == .sample, values["--shot"] != nil {
            throw UsageError("--sample exports the sample's one shot, so it takes no --shot.")
        } else if case .plateSample = input, values["--shot"] != nil {
            throw UsageError("--plate-sample exports the sample's one shot, so it takes no --shot.")
        }
    }

    /// Exactly one way of saying what to export.
    private static func input(sample: Bool, values: [String: String]) throws -> Input {
        switch (sample, values["--blockout"], values["--document"], values["--plate-sample"]) {
        case (true, nil, nil, nil):
            return .sample
        case let (false, path?, nil, nil):
            return .blockout(path: path, scene: values["--scene"], shot: values["--shot"])
        case let (false, nil, path?, nil):
            guard let shot = values["--shot"] else { throw UsageError("--document needs --shot <id>.") }
            return .document(path: path, shot: shot)
        case let (false, nil, nil, image?):
            return .plateSample(image: image)
        default:
            throw UsageError("Choose exactly one of --sample, --blockout, --document and --plate-sample.")
        }
    }

    /// The scene to export and the shot within it, with Blockout input's overrides applied.
    func shot(catalog: ContentCatalog) throws -> (scene: PrevisScene, shotID: ShotID) {
        switch input {
        case .sample:
            guard let scene = ShotsSamples.twoPersonWalk().scenes.first, let shot = scene.shots.first else {
                throw ShotsMediaError("The built-in sample has no shot to export.")
            }
            return (scene, shot.id)
        case let .plateSample(image):
            guard var scene = ShotsSamples.plateStaging().scenes.first, let shot = scene.shots.first else {
                throw ShotsMediaError("The built-in plate sample has no shot to export.")
            }
            // The sample's plate becomes the given image, at its own size.
            let url = URL(fileURLWithPath: image)
            guard let size = PlateImages.pixelSize(of: url) else {
                throw ShotsMediaError("\(image) isn't an image Shots can read. Use a PNG or JPEG plate.")
            }
            scene.plates[0].file = url.lastPathComponent
            scene.plates[0].size = size
            scene.shots[0].keyCanvas = nil
            return (scene, shot.id)
        case let .document(path, shot):
            let document = try JSONDecoder().decode(ShotsDocument.self, from: Self.read(path))
            guard document.version <= ShotsDocument.currentVersion else {
                throw ShotsMediaError(
                    "\(path) is shots format \(document.version); "
                        + "this build reads up to \(ShotsDocument.currentVersion)."
                )
            }
            guard let scene = document.scenes.first(where: { $0.shots.contains { $0.id == shot } }) else {
                throw ShotsMediaError("\(path) has no shot with id \(shot).")
            }
            return (scene, shot)
        case let .blockout(path, sceneKey, shotKey):
            // The project's own ids, so --scene and --shot take the ids written in it.
            let (document, notes) = try BlockoutImport.document(
                fromProjectJSON: Self.read(path), catalog: catalog, keepIDs: true
            )
            for note in notes {
                FileHandle.standardError.write(Data("note: \(note)\n".utf8))
            }
            var scene = try Self.scene(sceneKey, in: document)
            let index = try Self.shotIndex(shotKey, in: scene)
            apply(to: &scene.shots[index])
            return (scene, scene.shots[index].id)
        }
    }

    private func apply(to shot: inout Shot) {
        if let canvas {
            shot.canvas = canvas
        }
        if let frameCount {
            shot.frameCount = frameCount
            shot.guideFrames = shot.guideFrames.filter { $0 > 0 && $0 < frameCount - 1 }
        }
    }

    private static func scene(_ key: String?, in document: ShotsDocument) throws -> PrevisScene {
        guard let key else {
            guard let first = document.scenes.first else { throw ShotsMediaError("The project has no scenes.") }
            return first
        }
        if let scene = document.scenes.first(where: { $0.id == key }) { return scene }
        if let index = Int(key), document.scenes.indices.contains(index) { return document.scenes[index] }
        throw ShotsMediaError(
            "The project has no scene \(key): give a scene id or an index from 0 to \(document.scenes.count - 1)."
        )
    }

    /// Without a key, the first shot, as Blockout opens a scene. A name two shots share picks neither.
    private static func shotIndex(_ key: String?, in scene: PrevisScene) throws -> Int {
        guard let key else {
            guard !scene.shots.isEmpty else {
                throw ShotsMediaError("Scene \"\(scene.name)\" has no shot at all: give a shot id or name.")
            }
            return 0
        }
        if let index = scene.shots.firstIndex(where: { $0.id == key }) { return index }
        let named = scene.shots.indices.filter { scene.shots[$0].name == key }
        guard named.count < 2 else {
            throw ShotsMediaError("Scene \"\(scene.name)\" has \(named.count) shots named \(key): give a shot id.")
        }
        guard let index = named.first else {
            throw ShotsMediaError("Scene \"\(scene.name)\" has no shot \(key): give a shot id or name.")
        }
        return index
    }

    private static func frameCount(_ value: String) throws -> Int {
        guard let count = Int(value), FrameGrid.isValid(count) else {
            let nearest = Int(value).map { " The nearest is \(FrameGrid.snap($0))." } ?? ""
            throw UsageError("--frames takes a frame count of the form 17k + 5, such as 22, 124 or 141.\(nearest)")
        }
        return count
    }

    private static func canvas(_ value: String) throws -> ShotCanvas {
        let parts = value.lowercased().split(separator: "x", omittingEmptySubsequences: false)
        let sides = parts.compactMap { Int($0) }
        guard parts.count == 2, sides.count == 2, ShotCanvas(width: sides[0], height: sides[1]).isValid else {
            throw UsageError("--canvas takes WxH in multiples of 32 from 64 to 2048, such as 640x1152.")
        }
        return ShotCanvas(width: sides[0], height: sides[1])
    }

    private static func passes(_ value: String) throws -> ExportOptions {
        let names = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let passes = names.compactMap(PassKind.init(rawValue:))
        guard !names.isEmpty, passes.count == names.count else {
            throw UsageError("--passes takes a comma-separated list of clean, pose, layout and matte.")
        }
        return ExportOptions(passes: Set(passes))
    }

    private static func read(_ path: String) throws -> Data {
        do {
            return try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw ShotsMediaError("\(path) can't be read: \(error.localizedDescription)")
        }
    }
}
