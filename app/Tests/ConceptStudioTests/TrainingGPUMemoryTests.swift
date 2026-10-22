import ConceptCore
@testable import ConceptStudio
import Foundation
import Testing

@Suite("Training memory after a captioning rental")
@MainActor
struct TrainingGPUMemoryTests {
    private nonisolated static let largeModels = ["Tongyi-MAI/Z-Image", "Qwen/Qwen-Image-2.1"]

    private func connected(
        model: String, project: StudioProject, preferences: UserDefaults, agent: H3TestAgent
    ) -> GPUWorkspace {
        let workspace = makeWorkspace(GPUTransport(), preferences)
        // The training model is already selected when the user rents for captioning.
        workspace.chooseTrainingModel(model)
        workspace.regularizationOn = false
        workspace.rentsCaptionServer = true
        workspace.captionMemoryGB = 32
        workspace.projectFolder = project.directory
        workspace.pod = RentedPod(id: "caption-gpu", status: "RUNNING", cost: 1, gpu: .init(count: 1))
        workspace.saved = SavedPod(
            pod: workspace.pod!, started: Date(), hourlyRate: 1, budget: 10,
            trainer: "aitoolkit", runID: "", volumeID: "storage"
        )
        workspace.agent = agent
        return workspace
    }

    @Test(arguments: largeModels, [false, true])
    func actualTrainingMemoryGatesPreparationAndSubmission(model: String, enoughMemory: Bool) async throws {
        let project = try await captionedUploadProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        let preferences = IsolatedDefaults()
        defer { preferences.remove() }
        let agent = H3TestAgent()
        let fittingMemory = model == "Tongyi-MAI/Z-Image" ? 97887 : 81920
        await agent.setMemory(enoughMemory ? fittingMemory : 32623)
        let workspace = connected(model: model, project: project, preferences: preferences.defaults, agent: agent)
        let row = workspace.effectiveModelRow
        #expect(!row.gpu.verifyOnPod)
        #expect(workspace.requiredGPUMemoryGB == 32)
        var captured = false
        await workspace.train(datasetRepo: "", captureLocal: {
            captured = true
            return try await LocalTrainingDataset.prepare(projectFolder: project.directory)
        })
        #expect(captured == enoughMemory)
        let starts = await agent.starts
        if enoughMemory {
            #expect(workspace.failure == nil)
            #expect(starts.contains { $0.service == "trainer-aitoolkit" })
            #expect(workspace.runHistory.count == 1)
        } else {
            #expect(starts.isEmpty)
            #expect(await agent.uploads.isEmpty)
            #expect(workspace.runHistory.isEmpty)
            #expect(workspace.trainingReports.isEmpty)
            #expect(workspace.failure?.contains(row.shortName) == true)
            #expect(workspace.failure?.contains("Rent a cloud GPU with at least \(row.gpu.minVRAMGB) GB") == true)
        }
    }

    @Test func fittingCaptionGPUCanStillTrainASmallerRow() async throws {
        let project = try await captionedUploadProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        let preferences = IsolatedDefaults()
        defer { preferences.remove() }
        let agent = H3TestAgent()
        // A nominal 32 GB card need not report a full 32 GiB after firmware reservations.
        await agent.setMemory(32623)
        let workspace = connected(
            model: ungatedModel, project: project, preferences: preferences.defaults, agent: agent
        )
        await workspace.train(datasetRepo: "")
        #expect(workspace.failure == nil)
        #expect(workspace.trainingState == "running")
        #expect(await agent.starts.contains { $0.service == "trainer-aitoolkit" })
    }

    @Test(arguments: largeModels)
    func resumeChecksTheSavedModelsMemoryBeforeCaptureOrStateChanges(model: String) async throws {
        let project = try await captionedUploadProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        let preferences = IsolatedDefaults()
        defer { preferences.remove() }
        let agent = H3TestAgent()
        await agent.setMemory(32623)
        let workspace = connected(
            model: ungatedModel, project: project, preferences: preferences.defaults, agent: agent
        )
        let run = TrainingRun(
            runID: "saved-large-run", trainer: "aitoolkit", datasetRepo: "", datasetContainsVideo: false,
            localInputDigest: "saved-input-digest", paramsJSON: JSONValue.object([
                "base_model": .string(model), "steps": .int(10), "rank": .int(4), "resolution": .int(1024),
            ]).pythonDumpsData(), volumeID: "storage", startedAt: Date(), updatedAt: Date(),
            result: TrainingResult(
                runID: "saved-large-run", outputRepo: "", destination: .download,
                volumeID: "storage", state: .saved(folder: project.directory.path)
            ), points: [TrainingPoint(step: 10, loss: 0.2)], gpuBudgetUSD: 10, podSpendAtStart: 0
        )
        var report = TrainingReport(runID: run.runID, groupID: "frozen")
        report.state = .complete
        workspace.runHistory = [run]
        workspace.result = run.result
        workspace.trainingReports = [report]
        var captured = false
        await workspace.resumeRun(run, totalSteps: 20, captureLocal: {
            captured = true
            throw StudioError.message("Input capture must not start on this undersized GPU.")
        })
        #expect(!captured)
        #expect(await agent.starts.isEmpty)
        #expect(await agent.uploads.isEmpty)
        #expect(workspace.runHistory == [run])
        #expect(workspace.result == run.result)
        #expect(workspace.trainingReports == [report])
        #expect(workspace.failure?.contains("\(run.effectiveModelRow().gpu.minVRAMGB) GB") == true)
    }
}
