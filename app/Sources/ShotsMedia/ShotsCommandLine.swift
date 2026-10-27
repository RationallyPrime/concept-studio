import Foundation
import PrevisCore

/// All of `shots-export`'s logic, so tests run it in-process.
public enum ShotsCommandLine {
    static let usage = """
    usage: shots-export --sample --out <dir>
           shots-export --blockout <project.json> [--scene <id|index>] [--shot <id|name>] --out <dir>
           shots-export --document <shots.json> --shot <id> --out <dir>
           Blockout input also takes [--frames N] [--canvas WxH] [--passes clean,pose,layout,matte].
    Writes one validated shot package and prints its path.

    """

    /// 0 when a valid package was written, 1 when the export failed, 2 for a usage error.
    @MainActor public static func run(arguments: [String]) async -> Int32 {
        do {
            let job = try Job(arguments: arguments)
            let catalog = try ContentCatalog.bundled()
            let (scene, shotID) = try job.shot(catalog: catalog)
            let package = try await ShotExporter(catalog: catalog).export(
                scene: scene,
                shotID: shotID,
                options: job.options,
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
    ]

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
        switch (sample, values["--blockout"], values["--document"]) {
        case (true, nil, nil):
            input = .sample
        case let (false, path?, nil):
            input = .blockout(path: path, scene: values["--scene"], shot: values["--shot"])
        case let (false, nil, path?):
            guard let shot = values["--shot"] else { throw UsageError("--document needs --shot <id>.") }
            input = .document(path: path, shot: shot)
        default:
            throw UsageError("Choose exactly one of --sample, --blockout and --document.")
        }
        if case .blockout = input {
            frameCount = try values["--frames"].map(Self.frameCount)
            canvas = try values["--canvas"].map(Self.canvas)
            options = try values["--passes"].map(Self.passes) ?? .standard
        } else if let option = ["--scene", "--frames", "--canvas", "--passes"].first(where: { values[$0] != nil }) {
            throw UsageError("\(option) applies to Blockout input only.")
        } else if input == .sample, values["--shot"] != nil {
            throw UsageError("--sample exports the sample's one shot, so it takes no --shot.")
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
