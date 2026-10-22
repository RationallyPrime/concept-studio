import AppKit
@testable import ConceptStudio
import Foundation
import Testing

@Suite("on-device image suggestions")
struct VisionInspectorTests {
    @Test(.timeLimit(.minutes(1)))
    func separateInspectorsCompleteConcurrentNativeRequestsWithoutStarvingAsyncWork() async throws {
        let directory = temporaryTestDirectory("concurrent-vision")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = directory.appendingPathComponent("synthetic.png")
        try MediaEditor.png(MediaFixtures.image(width: 640, height: 512)).write(to: image)
        let completed = try await withThrowingTaskGroup(of: Int.self) { group in
            for index in 1 ... 8 {
                group.addTask {
                    let result = try await VisionInspector().analyze([image])
                    #expect(result[image.lastPathComponent]?.width == 640)
                    return index
                }
            }
            group.addTask { await Task.yield(); return 0 }
            var results: [Int] = []
            for try await result in group {
                results.append(result)
            }
            return results
        }
        #expect(completed.sorted() == Array(0 ... 8))
    }

    @Test func pixelEquivalentReencodingIsSimilarButDistinctIllustrationsAreNot() async throws {
        let project = try await makeDemoProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        let original = try #require(project.images.first?.url)
        let bitmap = try #require(NSBitmapImageRep(data: Data(contentsOf: original)))
        let reencoded = try #require(bitmap.representation(using: .png, properties: [:]))
        let copy = project.imagesDirectory.appendingPathComponent("same-pixels.png")
        let originalBytes = try Data(contentsOf: original)
        #expect(reencoded != originalBytes)
        try reencoded.write(to: copy)
        let inspector = VisionInspector()
        let analyses = try await inspector.analyze(project.images.map(\.url) + [copy])
        for image in project.images {
            #expect(analyses[image.id]?.warnings.contains { $0.contains("Visually similar") } == false)
        }
        #expect(analyses["same-pixels.png"]?.warnings.contains {
            $0.contains("Visually similar")
        } == true)
    }
}
