@testable import ConceptStudio
import Foundation
import PrevisCore
import Testing

@Suite("Shots file preservation")
struct ShotsDocumentFileTests {
    @Test func newerVersionStaysInPlaceAndOpensReadOnly() throws {
        let directory = temporaryTestDirectory("Shots-newer")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = ShotsDocumentFile.url(in: directory)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("{\"version\":\(ShotsDocument.currentVersion + 1),\"future\":true}".utf8)
        try original.write(to: url)

        let loaded = try ShotsDocumentFile.load(from: url)

        #expect(loaded.readOnly)
        #expect(loaded.notice != nil)
        #expect(try Data(contentsOf: url) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
            == ["shots.json"])
    }

    @Test func corruptBytesArePreservedBeforeReturningAnEmptyDocument() throws {
        let directory = temporaryTestDirectory("Shots-corrupt")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = ShotsDocumentFile.url(in: directory)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("unfinished blocking {".utf8)
        try original.write(to: url)

        let loaded = try ShotsDocumentFile.load(from: url)

        #expect(!loaded.readOnly)
        #expect(loaded.notice != nil)
        #expect(loaded.document.scenes.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        let files = try FileManager.default.contentsOfDirectory(
            at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil
        )
        let backup = try #require(files.first { $0.lastPathComponent.hasPrefix("shots.json.unreadable-") })
        #expect(try Data(contentsOf: backup) == original)
    }

    @Test func savingAndReopeningPreservesTheSampleDocument() throws {
        let directory = temporaryTestDirectory("Shots-roundtrip")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = ShotsDocumentFile.url(in: directory)
        let sample = ShotsSamples.twoPersonWalk()

        try ShotsDocumentFile.save(sample, to: url)
        let loaded = try ShotsDocumentFile.load(from: url)

        #expect(!loaded.readOnly)
        #expect(loaded.notice == nil)
        #expect(loaded.document == sample)
    }
}
