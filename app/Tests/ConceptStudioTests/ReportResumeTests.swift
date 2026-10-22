import ConceptCore
@testable import ConceptStudio
import Foundation
import Testing

@Suite("Reports after training continuation")
@MainActor
struct ReportResumeTests {
    private func connected(
        project: StudioProject,
        preferences: UserDefaults,
        agent: HistoryAgent
    ) throws -> GPUWorkspace {
        let workspace = try makeReportPreviewWorkspace(project: project, preferences: preferences)
        workspace.pod = RentedPod(id: "fixture", status: "RUNNING", cost: 1, gpu: .init(count: 2))
        workspace.saved = SavedPod(
            pod: workspace.pod!, started: Date(), hourlyRate: 1, budget: 10,
            trainer: "aitoolkit", runID: "example-run-1", volumeID: "retained"
        )
        workspace.agent = agent
        let run = TrainingRun(
            runID: "example-run-1", trainer: "aitoolkit", datasetRepo: "fixture/data", datasetRevision: "revision",
            datasetContainsVideo: false, paramsJSON: JSONValue.object([
                "base_model": .string(workspace.baseModel), "steps": .int(10), "rank": .int(4), "resolution": .int(512),
                "dataset": .object(["path": .string("/workspace/datasets/source")]),
            ]).pythonDumpsData(), volumeID: "retained", startedAt: Date(), updatedAt: Date(),
            result: TrainingResult(
                runID: "example-run-1",
                outputRepo: "fixture/lora",
                destination: .hub,
                volumeID: "retained",
                state: .pushed(repo: "fixture/lora")
            ),
            points: [TrainingPoint(step: 10, loss: 0.2)], estimatedGPUCostUSD: 0.2,
            gpuBudgetUSD: 10, podSpendAtStart: 0
        )
        workspace.runHistory = [run]
        workspace.result = run.result
        workspace.generation = workspace.generations[0]
        return workspace
    }

    @Test(arguments: [TrainingReport.State.complete, .failed], [false, true])
    func resumingInvalidatesEarlierReportOutputsIncludingLostStartAcknowledgement(
        state: TrainingReport.State, lostAcknowledgement: Bool
    ) async throws {
        let project = try await makeDemoProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        let preferences = IsolatedDefaults()
        defer { preferences.remove() }
        let agent = HistoryAgent()
        if lostAcknowledgement { await agent.loseStartAcknowledgements() }
        let workspace = try connected(project: project, preferences: preferences.defaults, agent: agent)
        workspace.trainingReports[0].state = state
        if state == .failed { workspace.trainingReports[0].completedPromptIDs = ["identity"] }
        let group = workspace.selectedReportGroup
        let otherReport = workspace.trainingReports[1]
        let original = workspace.generations[0]
        let image = try #require(workspace.comparisonFile("lora.jpg", in: original))
        let bytes = try Data(contentsOf: image)
        await workspace.resumeRun(workspace.runHistory[0], totalSteps: 20)
        #expect(await agent.starts.contains { $0.service == "trainer-aitoolkit" })
        if lostAcknowledgement { #expect(workspace.message.contains("lost start acknowledgement")) }
        #expect(workspace.trainingReports[0].state == .waiting)
        #expect(workspace.trainingReports[0].samples.isEmpty)
        #expect(workspace.trainingReports[0].completedPromptIDs.isEmpty)
        #expect(workspace.trainingReports[0].groupID == group?.id)
        #expect(workspace.selectedReportGroup == group)
        #expect(workspace.trainingReports[1] == otherReport)
        let retained = try #require(workspace.generations.first { $0.runID == original.runID })
        #expect(retained.reportGroupID == nil && retained.reportPromptIDs == nil)
        #expect(workspace.generation?.reportGroupID == nil && workspace.generation?.reportPromptIDs == nil)
        #expect(retained.state == .saved && retained.folder == original.folder)
        #expect(try Data(contentsOf: image) == bytes)
        #expect(ProjectTrainingRecord.load(from: project.directory).comparisons
            .first { $0.runID == original.runID }?.reportGroupID == nil)
        let artifact = try JSONValue(parsing: Data(contentsOf: project.directory
                .appendingPathComponent("results/example-run-1/report.json")))
        #expect(artifact.objectValue?["report"]?.objectValue?["state"] == .string("waiting"))
    }

    @Test func failedPreparationKeepsThePriorReportAndItsComparisonBindings() async throws {
        let project = try await makeDemoProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        let preferences = IsolatedDefaults()
        defer { preferences.remove() }
        let agent = HistoryAgent()
        let workspace = try connected(project: project, preferences: preferences.defaults, agent: agent)
        workspace.runHistory[0].localInputDigest = "captured-inputs"
        let reports = workspace.trainingReports, comparisons = workspace.generations, current = workspace.generation
        await workspace.resumeRun(workspace.runHistory[0], totalSteps: 20, captureLocal: {
            throw StudioError.message("Synthetic input preparation failure")
        })
        #expect(await agent.starts.isEmpty)
        #expect(workspace.message.contains("Synthetic input preparation failure"))
        #expect(workspace.trainingReports == reports)
        #expect(workspace.generations == comparisons)
        #expect(workspace.generation == current)
    }
}
