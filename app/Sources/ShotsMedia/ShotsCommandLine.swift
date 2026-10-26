import Foundation

/// All of `shots-export`'s logic, so tests run it in-process. Input modes land in B3 and B4.
public enum ShotsCommandLine {
    static let usage = """
    usage: shots-export --sample --out <dir>
           shots-export --blockout <project.json> [--scene <id|index>] [--shot <id|name>] --out <dir>
           shots-export --document <shots.json> --shot <id> --out <dir>
           Blockout input also takes [--frames N] [--canvas WxH] [--passes clean,pose,layout,matte].
    Writes one validated shot package and prints its path. No input mode is implemented yet.

    """

    @MainActor public static func run(arguments: [String]) async -> Int32 {
        FileHandle.standardError.write(Data(usage.utf8))
        return 2
    }
}
