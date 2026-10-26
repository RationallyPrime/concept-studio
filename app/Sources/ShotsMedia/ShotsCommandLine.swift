import Foundation
import PrevisCore

/// All of `shots-export`'s logic, so tests run it in-process. Blockout and document input land in B4.
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
        var options: [String: String] = [:]
        var flags: Set<String> = []
        var remaining = arguments[...]
        while let argument = remaining.popFirst() {
            switch argument {
            case "--sample": flags.insert(argument)
            case "--out", "--blockout", "--document", "--scene", "--shot", "--frames", "--canvas", "--passes":
                guard let value = remaining.popFirst() else { return fail("\(argument) needs a value.") }
                options[argument] = value
            default:
                return fail("Unknown argument \(argument).")
            }
        }
        if options["--blockout"] != nil || options["--document"] != nil {
            return fail("Blockout and document input arrive with B4; only --sample works so far.")
        }
        guard flags.contains("--sample"), let out = options["--out"] else { return fail(nil) }
        do {
            guard let scene = ShotsSamples.twoPersonWalk().scenes.first, let shot = scene.shots.first else {
                throw ShotsMediaError("The built-in sample has no shot to export.")
            }
            let package = try await ShotExporter(catalog: ContentCatalog.bundled()).export(
                scene: scene,
                shotID: shot.id,
                options: .standard,
                to: FolderDestination(parent: URL(fileURLWithPath: out, isDirectory: true)),
                progress: { _ in }
            )
            FileHandle.standardOutput.write(Data((package.url.path + "\n").utf8))
            return 0
        } catch {
            FileHandle.standardError.write(Data("shots-export: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    private static func fail(_ message: String?) -> Int32 {
        FileHandle.standardError.write(Data(((message.map { "shots-export: \($0)\n" } ?? "") + usage).utf8))
        return 2
    }
}
