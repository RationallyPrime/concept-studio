import ConceptCore
@testable import ConceptStudio
import Foundation
import Testing

@MainActor @Suite("Installed GPU tools gate app actions")
struct GPUServiceAvailabilityTests {
    private func connected(
        folder: URL, preferences: UserDefaults, transport: UnreachableAgentTransport,
        agent: HistoryAgent? = nil
    ) -> GPUWorkspace {
        let gpu = makeWorkspace(transport, preferences)
        gpu.chooseTrainingModel("Qwen/Qwen-Image-2.1")
        gpu.regularizationOn = false
        gpu.projectFolder = folder
        gpu.provider = RunPodProvider(key: "fixture", transport: transport)
        let pod = RentedPod(id: "test", status: "RUNNING", cost: 1, gpu: .init(count: 2))
        gpu.pod = pod
        gpu.saved = SavedPod(
            pod: pod, started: Date(), hourlyRate: 1, budget: 10, trainer: "aitoolkit",
            runID: "", volumeID: "storage"
        )
        if let agent { gpu.agent = agent } else { gpu.connectAgent(pod) }
        return gpu
    }

    private func savedRun() -> TrainingRun {
        let params: JSONObject = [
            "base_model": .string("Qwen/Qwen-Image-2.1"), "steps": .int(200), "rank": .int(16),
            "resolution": .int(512), "profile": .string("flux-image"),
            "triggers": .array([.string("NORA7")]),
            "dataset": .object(["path": .string("/workspace/datasets/saved-run")]),
        ]
        return TrainingRun(
            runID: "saved-run", trainer: "aitoolkit", datasetRepo: "fixture/data", datasetContainsVideo: false,
            paramsJSON: JSONValue.object(params).pythonDumpsData(), volumeID: "storage",
            startedAt: Date(), updatedAt: Date(), result: TrainingResult(
                runID: "saved-run", outputRepo: "fixture/model", destination: .hub,
                volumeID: "storage", state: .pushed(repo: "fixture/model")
            ), points: [.init(step: 200, loss: 0.1)],
            checkpoints: [.init(path: "final.safetensors", size: 7, sha256: sha256(Data("weights".utf8)))],
            gpuBudgetUSD: 10, podSpendAtStart: 0
        )
    }

    @Test(arguments: ["trainer-aitoolkit", "pull-dataset", "draw-regularization"])
    func trainingRefusesMissingToolsBeforeCaptureUploadOrAdmission(_ missing: String) async throws {
        let defaults = IsolatedDefaults()
        defer { defaults.remove() }
        let folder = temporaryTestDirectory("unavailable-training")
        defer { try? FileManager.default.removeItem(at: folder) }
        let transport = UnreachableAgentTransport(agentAvailable: true)
        await transport.unavailable([missing])
        let gpu = connected(folder: folder, preferences: defaults.defaults, transport: transport)
        gpu.regularizationOn = missing == "draw-regularization"
        gpu.ownRegularizationImages = false
        #expect(gpu.usesLocalDataset)
        var captured = false
        await gpu.train(datasetRepo: "", captureLocal: {
            captured = true
            throw StudioError.message("The unavailable action reached input capture")
        })
        #expect(!captured)
        #expect(gpu.failure == gpu.trainingUnavailableReason)
        #expect(gpu.failure == gpu.serviceUnavailableReason(missing))
        #expect(gpu.result == nil && gpu.runID.isEmpty && gpu.runHistory.isEmpty)
        #expect(gpu.reportGroups.isEmpty)
        #expect(await transport.starts.isEmpty)
        #expect(try await (#require(gpu.uploader as? RecordingUploader)).requests.isEmpty)
        #expect(ProjectTrainingRecord.load(from: folder).runs.isEmpty)
    }

    @Test(arguments: ["trainer-aitoolkit", "pull-dataset"])
    func resumeCannotMutateTheSavedRunOrCaptureInputsWhenToolsAreMissing(_ missing: String) async {
        let defaults = IsolatedDefaults()
        defer { defaults.remove() }
        let folder = temporaryTestDirectory("unavailable-resume")
        defer { try? FileManager.default.removeItem(at: folder) }
        let transport = UnreachableAgentTransport(agentAvailable: true)
        let agent = HistoryAgent()
        await agent.unavailable([missing])
        let gpu = connected(folder: folder, preferences: defaults.defaults, transport: transport, agent: agent)
        var run = savedRun()
        run.localInputDigest = "unchanged-inputs"
        gpu.runHistory = [run]
        gpu.saveProjectRecord()
        let before = ProjectTrainingRecord.load(from: folder)
        var captured = false
        await gpu.resumeRun(run, totalSteps: 400, captureLocal: {
            captured = true
            throw StudioError.message("The unavailable Resume reached input capture")
        })
        #expect(!captured)
        #expect(gpu.failure == gpu.resumeUnavailableReason(run))
        #expect(gpu.failure == gpu.serviceUnavailableReason(missing))
        #expect(gpu.runHistory == [run])
        #expect(gpu.result == nil && gpu.runID.isEmpty)
        #expect(ProjectTrainingRecord.load(from: folder) == before)
        #expect(await agent.starts.isEmpty)
    }

    @Test func generationStopsBeforeCreatingComparisonState() async {
        let defaults = IsolatedDefaults()
        defer { defaults.remove() }
        let folder = temporaryTestDirectory("unavailable-generation")
        defer { try? FileManager.default.removeItem(at: folder) }
        let transport = UnreachableAgentTransport(agentAvailable: true)
        let agent = HistoryAgent()
        await agent.unavailable(["generate-aitoolkit"])
        let gpu = connected(folder: folder, preferences: defaults.defaults, transport: transport, agent: agent)
        let run = savedRun()
        gpu.runHistory = [run]
        await gpu.generateComparison(run: run, checkpoint: run.checkpoints[0], prompts: ["NORA7 outdoors"], seeds: [42])
        #expect(gpu.failure == gpu.serviceUnavailableReason("generate-aitoolkit"))
        #expect(gpu.generation == nil && gpu.generations.isEmpty)
        #expect(await agent.starts.isEmpty)
        #expect(await agent.listedRunIDs.isEmpty)
    }

    @Test(arguments: ["generate-aitoolkit", "vllm"])
    func reportsStopBeforeBudgetStateOrReferenceUploads(_ missing: String) async throws {
        let defaults = IsolatedDefaults()
        defer { defaults.remove() }
        let project = try await makeDemoProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        let transport = UnreachableAgentTransport(agentAvailable: true)
        await transport.unavailable([missing])
        let gpu = connected(folder: project.directory, preferences: defaults.defaults, transport: transport)
        let run = savedRun()
        gpu.runHistory = [run]
        let groupID = try await gpu.prepareTrainingReport()
        gpu.attachTrainingReport(runID: run.runID, groupID: groupID)
        let before = gpu.trainingReports
        await gpu.runTrainingReport(run.runID)
        #expect(gpu.failure == gpu.reportUnavailableReason(run.trainer))
        #expect(gpu.trainingReports == before)
        #expect(gpu.runHistory == [run])
        #expect(gpu.generation == nil && gpu.generations.isEmpty)
        #expect(await transport.starts.isEmpty)
        #expect(try await (#require(gpu.uploader as? RecordingUploader)).requests.isEmpty)
    }

    @Test func upscaleAndCleanupRefuseBeforeSendingInputsOrStartingServices() async throws {
        let defaults = IsolatedDefaults()
        defer { defaults.remove() }
        let folder = temporaryTestDirectory("unavailable-maintenance")
        defer { try? FileManager.default.removeItem(at: folder) }
        let transport = UnreachableAgentTransport(agentAvailable: true)
        await transport.unavailable(["upscale-media", "cleanup-datasets"])
        let gpu = connected(folder: folder, preferences: defaults.defaults, transport: transport)
        var progress: [String] = []
        do {
            _ = try await gpu.upscale(
                [.init(sampleID: "sample.jpg", file: folder.appendingPathComponent("not-read.jpg"))],
                model: .standard, target: UpscaleTarget(shortSide: 1024), into: folder
            ) { progress.append($0) }
            Issue.record("Unavailable Upscale started")
        } catch {
            #expect(error.localizedDescription == gpu.upscaleUnavailableReason)
        }
        #expect(progress.isEmpty)
        #expect(try await (#require(gpu.uploader as? RecordingUploader)).requests.isEmpty)
        await gpu.cleanupDatasets()
        #expect(gpu.failure == gpu.serviceUnavailableReason("cleanup-datasets"))
        #expect(await transport.starts.isEmpty)
    }

    @Test(arguments: [false, true])
    func missingPublisherRemovesAutomaticPublishingFromNewAndResumedRuns(_ resume: Bool) async throws {
        let defaults = IsolatedDefaults()
        defer { defaults.remove() }
        let project = try await makeDemoProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        let transport = UnreachableAgentTransport(agentAvailable: true)
        await transport.unavailable(["push-lora"])
        let gpu = connected(folder: project.directory, preferences: defaults.defaults, transport: transport)
        gpu.hubToken = "fixture"
        gpu.datasetItemCount = project.images.count
        if resume {
            var run = savedRun()
            var params = run.params
            params["hub"] = .object([
                "repo_id": .string("fixture/model"), "private": .bool(true), "push_on_finish": .bool(true),
            ])
            run.paramsJSON = JSONValue.object(params).pythonDumpsData()
            gpu.runHistory = [run]
            await gpu.resumeRun(run, totalSteps: 400)
        } else {
            await gpu.train(datasetRepo: "fixture/data", output: HubDestination(repo: "fixture/model"))
        }
        #expect(gpu.failure == nil)
        #expect(gpu.result?.destination == .download)
        #expect(try await trainerParams(transport, "aitoolkit")["hub"] == nil)
        await gpu.stopEverything()
    }

    @Test func missingPublisherStillDeliversTheModelToTheMac() async throws {
        let defaults = IsolatedDefaults()
        defer { defaults.remove() }
        let folder = temporaryTestDirectory("unavailable-publisher")
        defer { try? FileManager.default.removeItem(at: folder) }
        let transport = UnreachableAgentTransport(agentAvailable: true)
        let agent = HistoryAgent()
        await agent.unavailable(["push-lora", "trainer-aitoolkit", "generate-aitoolkit"])
        await agent.serve(["final.safetensors": Data("weights".utf8)])
        let gpu = connected(folder: folder, preferences: defaults.defaults, transport: transport, agent: agent)
        gpu.hubToken = "fixture"
        var run = savedRun()
        run.result?.state = .pending
        gpu.runHistory = [run]
        gpu.result = run.result
        gpu.runID = run.runID
        await gpu.retrieveResult()
        let destination = folder.appendingPathComponent("results/saved-run")
        #expect(gpu.failure == nil)
        #expect(gpu.result?.state == .saved(folder: destination.path))
        #expect(try Data(contentsOf: destination.appendingPathComponent("final.safetensors")) == Data("weights".utf8))
        #expect(await agent.starts.isEmpty)
        #expect(await agent.downloadedRunIDs == [run.runID])
    }

    @Test func unknownMissingAndLegacyInventoryStayDistinctAndRestartClearsIt() async throws {
        let defaults = IsolatedDefaults()
        defer { defaults.remove() }
        let folder = temporaryTestDirectory("service-inventory")
        defer { try? FileManager.default.removeItem(at: folder) }
        let transport = UnreachableAgentTransport(agentAvailable: true)
        let gpu = connected(folder: folder, preferences: defaults.defaults, transport: transport)
        let unknown = try #require(gpu.serviceUnavailableReason("tensorboard"))
        gpu.updateServiceState([])
        let missing = try #require(gpu.serviceUnavailableReason("tensorboard"))
        gpu.updateServiceState([.init(name: "tensorboard", state: "idle", groupAlive: false)])
        let legacy = try #require(gpu.serviceUnavailableReason("tensorboard"))
        #expect(unknown != missing && unknown != legacy && missing != legacy)
        _ = try await gpu.requireServices(["tensorboard"], from: #require(gpu.agent))
        #expect(gpu.serviceUnavailableReason("tensorboard") == nil)
        await gpu.stopEverything()
        #expect(gpu.serviceInventory == nil)
        await transport.agentReachable(false)
        await gpu.startStoppedComputer()
        gpu.monitorTask?.cancel()
        await gpu.monitorTask?.value
        #expect(gpu.hasRunningPod)
        #expect(gpu.serviceInventory == nil)
        #expect(gpu.serviceUnavailableReason("tensorboard") == unknown)
        await gpu.stopEverything()
    }
}
