import ConceptCore
@testable import ConceptStudio
import Foundation
import Testing

@Suite("Comparisons after the training GPU is gone")
struct PortableComparisonTests {
    @MainActor @Test(arguments: [false, true], [false, true])
    func missingWeightsUsePublishedOrLocalWeights(local: Bool, matchingVolume: Bool) async throws {
        let (preferences, suite) = try temporaryPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let project = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: project) }
        let workspace = makeWorkspace(GPUTransport(), preferences)
        let agent = HistoryAgent()
        workspace.projectFolder = project
        workspace.pod = RentedPod(id: "new-gpu", status: "RUNNING", cost: 1, gpu: .init(count: 2))
        workspace.saved = try SavedPod(
            pod: #require(workspace.pod), started: Date(), hourlyRate: 1, budget: 10,
            trainer: "aitoolkit", runID: "", volumeID: "new-storage"
        )
        workspace.agent = agent
        workspace.hubToken = "fixture-token"
        let originalVolume = matchingVolume ? "new-storage" : "deleted-storage"
        var run = TrainingRun(
            runID: "saved-run", trainer: "aitoolkit", datasetRepo: "fixture/data", datasetContainsVideo: false,
            paramsJSON: JSONValue.object([
                "run_id": .string("saved-run"), "base_model": .string("black-forest-labs/FLUX.1-dev"),
                "resolution": .int(512), "rank": .int(16),
            ]).pythonDumpsData(),
            volumeID: originalVolume, startedAt: Date(), updatedAt: Date(),
            result: TrainingResult(
                runID: "saved-run", outputRepo: "fixture/lora", destination: .hub, volumeID: originalVolume,
                state: .pushed(repo: "fixture/lora")
            ), podSpendAtStart: 0
        )
        if local {
            let folder = try workspace.resultsFolder(for: run.runID)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("synthetic local LoRA".utf8).write(to: folder.appendingPathComponent("final.safetensors"))
            run.localFolder = folder.path
        }
        workspace.runHistory = [run]
        let checkpoint = try await workspace.comparisonCheckpoint(for: run, agent: agent)
        #expect(checkpoint.path == (local ? "final.safetensors" : "published.safetensors"))
        await workspace.generateComparison(run: run, checkpoint: checkpoint, prompts: ["NORA7 outdoors"], seeds: [42])
        #expect(workspace.failure == nil)
        let start = try #require(await agent.starts.last)
        #expect(start.service == "generate-aitoolkit")
        let source = try #require(start.params["source"]?.objectValue)
        #expect(source["config"]?.objectValue?["base_model"]?.stringValue == run.baseModel)
        if local {
            #expect(source["upload"]?.stringValue != nil)
            #expect(await agent.uploads["comparison-lora.safetensors"] == Data("synthetic local LoRA".utf8))
        } else {
            #expect(source["repo"]?.stringValue == "fixture/lora")
        }
        #expect(workspace.generation?.volumeID == "new-storage")
        #expect(workspace.runHistory[0].volumeID == run.volumeID)
    }
}
