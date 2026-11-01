import Foundation
import PrevisCore
@testable import ShotsMedia
import Testing

/// What the export reports while it runs, for Lane C to show, and what cancelling it leaves behind.
@Suite("export progress and cancellation", .enabled(if: renderingEnabled))
@MainActor
struct ExportProgressTests {
    /// One step for each video, in turn, naming the actor whose matte it is, then the check of the whole package.
    /// The fraction never goes back, and it ends at 1.
    @Test func progressGoesThroughEachVideoInTurnThenTheCheck() async throws {
        let parent = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: parent) }
        var reports: [ExportProgress] = []
        let exported = try await exportSmallSample(to: parent) { reports.append($0) }
        let steps = Self.steps(reports)
        let videos = exported.manifest.files.filter { $0.path.hasSuffix(".mp4") }
        #expect(steps.count == videos.count + 1 && Set(steps).count == steps.count, "\(steps)")
        for matte in videos where matte.role == .matte {
            let name = try #require(matte.entityName)
            #expect(steps.count { $0.contains(name) } == 1, "\(name): \(steps)")
        }
        let fractions = reports.map(\.fractionCompleted)
        #expect(zip(fractions, fractions.dropFirst()).allSatisfy { $0 <= $1 }, "\(fractions)")
        #expect(fractions.first.map { $0 > 0 } == true && fractions.last == 1, "\(fractions)")
    }

    /// Cancelling during any step, the check of the package included, throws `CancellationError` and leaves
    /// neither a staging folder nor a package.
    @Test func cancellingDuringAnyStepLeavesNothingBehind() async throws {
        let parent = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: parent) }
        var reports: [ExportProgress] = []
        _ = try await exportSmallSample(to: parent.appendingPathComponent("whole")) { reports.append($0) }
        let steps = Self.steps(reports)
        try #require(steps.count > 2)
        for (index, step) in steps.enumerated() {
            let folder = parent.appendingPathComponent("cancelled-\(index)")
            let box = ExportTaskBox()
            box.task = Task {
                try await exportSmallSample(to: folder) { if $0.step == step { box.task?.cancel() } }
            }
            let task = try #require(box.task)
            await #expect(throws: CancellationError.self, "cancelled during \(step)") { try await task.value }
            #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == [], "cancelled during \(step)")
        }
    }

    /// The steps in the order they were first reported, each once.
    private static func steps(_ reports: [ExportProgress]) -> [String] {
        reports.map(\.step).reduce(into: []) { steps, step in if steps.last != step { steps.append(step) } }
    }
}
