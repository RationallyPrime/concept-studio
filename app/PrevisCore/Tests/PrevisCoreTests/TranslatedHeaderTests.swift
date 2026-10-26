import Foundation
@testable import PrevisCore
import Testing

/// A6: every translated file carries its header, naming Blockout, the pinned commit, the licence and its author.
struct TranslatedHeaderTests {
    /// The files that translate Blockout code, with the Blockout source each names. Every other file under Sources is
    /// Shots' own (documents, values, decoding, import, bodies, evaluation values, camera-move wiring, sample data).
    private static let translated: [String: String] = [
        "ActionPaths.swift": "action-presets.ts", "AttachmentGraph.swift": "evaluate.ts",
        "Attachments.swift": "store.ts",
        "CameraMovePresets.swift": "camera-moves.ts", "Framing.swift": "camera.ts", "Kernels.swift": "easing",
        "Motions.swift": "sequences.ts", "PersonRig.swift": "builders.ts", "Plans.swift": "evaluate",
        "QuadrupedRig.swift": "builders.ts", "ShotEvaluator.swift": "evaluate.ts", "Warnings.swift": "gaits.ts",
    ]

    private static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/PrevisCore")

    private func header(_ name: String) throws -> String {
        let text = try String(contentsOf: Self.sources.appendingPathComponent(name), encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: false).prefix(6)
            .filter { $0.hasPrefix("//") }.map { $0.dropFirst(2).trimmingCharacters(in: .whitespaces) }
            .joined(separator: " ")
    }

    @Test func everyTranslatedFileNamesItsSourceTheCommitTheLicenceAndTheAuthor() throws {
        for (name, source) in Self.translated {
            let header = try header(name)
            #expect(
                header.hasPrefix("Translated from Blockout (https://github.com/wassermanproductions/blockout)"),
                "\(name)"
            )
            #expect(header.contains(source), "\(name) names \(source)")
            #expect(header.contains("3f2d0564"), "\(name) names the pinned commit")
            #expect(header.contains("Apache-2.0"), "\(name) names the licence")
            #expect(header.contains("Sam Wasserman"), "\(name) credits the author")
        }
    }

    @Test func aFileThatClaimsToBeTranslatedIsInTheAuditedList() throws {
        let files = try FileManager.default.contentsOfDirectory(atPath: Self.sources.path)
            .filter { $0.hasSuffix(".swift") }
        #expect(files.count > Self.translated.count)
        for name in files where try header(name).hasPrefix("Translated from") {
            #expect(Self.translated[name] != nil, "\(name) carries a translation header but is not in the audited list")
        }
    }

    @Test func theBundledNoticeNamesTheSourceCommit() throws {
        let notice = try String(contentsOf: Self.sources.appendingPathComponent("Resources/NOTICE"), encoding: .utf8)
        #expect(notice.contains("3f2d0564fd575f70fc28e9bfaa7e94b05e3955d9"))
        #expect(notice.contains("Sam Wasserman"))
    }
}
