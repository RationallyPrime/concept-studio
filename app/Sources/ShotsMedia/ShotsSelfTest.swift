import Foundation

/// The sandbox spike: renders and encodes the sample inside the app and prints a JSON report.
/// Lane C wires `--shots-self-test` to it. Lands in B2; until then it reports that and fails.
@MainActor public enum ShotsSelfTest {
    public static func run() async -> Int32 {
        let report = #"{"ok":false,"reason":"The Shots self-test is not implemented yet."}"#
        FileHandle.standardOutput.write(Data((report + "\n").utf8))
        return 1
    }
}
