import ConceptCore
@testable import ConceptStudio
import CryptoKit
import Foundation
import Testing

@Suite("GPU workflow")
struct GPUWorkflowTests {
    private func expectCaptionStart(_ request: URLRequest, model: String) throws {
        #expect(request.url?.path() == "/services/vllm/start")
        let body = try JSONValue(parsing: #require(request.httpBody)).objectValue
        #expect(body?["gpus"] == .array([.int(0)]))
        let params = try #require(body?["params"]?.objectValue)
        #expect(params["model"]?.stringValue == model)
        #expect(params["max_model_len"]?.intValue == 16384)
        let isCapQwen = model == ProviderChoices.defaultSelfHostedModel
        #expect(params["max_num_seqs"]?.intValue == (isCapQwen ? 4 : 2))
        #expect(params["gpu_memory_utilization"]?.doubleValue == (isCapQwen ? 0.90 : 0.85))
        #expect(params["extra_args"] == .array([.string("--enforce-eager"), .string("--max-num-batched-tokens=4096")]))
    }

    @MainActor @Test(arguments: [false, true], ["aitoolkit", "ltx"])
    func concurrentTrainingStartsOrReusesCaptionServer(_ captionEarlier: Bool, trainerName: String) async throws {
        let (preferences, suite) = try temporaryPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let transport = UnreachableAgentTransport(agentAvailable: true, inferenceReady: true, gpuCount: 2)
        let workspace = makeWorkspace(transport, preferences)
        try workspace.configure(runpodKey: "provider-only", hubToken: "hub-only", imageName: "test")
        workspace.gpuCount = 2
        workspace.trainer = trainerName
        if !captionEarlier { workspace.captionModel = "Qwen/alternate-caption-model" }
        workspace.keepCaptionServer = true
        await workspace.refreshOffers()
        await workspace.rent()
        if captionEarlier { #expect(await workspace.startCaptioning()) }
        await workspace.train(datasetRepo: "test/images")
        let starts = await transport.starts
        let captionStarts = starts.filter { $0.url?.path() == "/services/vllm/start" }
        #expect(captionStarts.count == 1)
        try expectCaptionStart(#require(captionStarts.first), model: workspace.captionModel)
        let trainer = try #require(starts.first { $0.url?.path() == "/services/trainer-\(trainerName)/start" })
        let body = try JSONValue(parsing: #require(trainer.httpBody)).objectValue
        #expect(body?["gpus"] == .array([.int(1)]))
        let params = try #require(body?["params"]?.objectValue)
        #expect(params["resolution"]?.intValue == 512)
        #expect(params["sample_every"]?.intValue == 0)
        #expect(params["rank"]?.intValue == 16)
        // Signed in, but the Hub account could not be read (whoami 401): downloaded, not pushed.
        #expect(params["hub"] == nil)
        if trainerName == "ltx" {
            #expect(params["base_model"]?.stringValue == "Lightricks/LTX-2.3")
            let extra = try #require(params["extra"]?.objectValue)
            #expect(extra["optimization"] == .object(["optimizer_type": .string("adamw8bit")]))
            #expect(extra["acceleration"] == .object([
                "quantization": .string("int8-quanto"), "load_text_encoder_in_8bit": .bool(true),
                "offload_optimizer_during_validation": .bool(true),
            ]))
            #expect(extra["preprocess"] == .object(["args": .array([
                .string("--load-text-encoder-in-8bit"), .string("--vae-tiling"), .string("--skip-audio"),
            ])]))
        } else {
            #expect(params["extra"] == .object(["training_seed": .int(42)]))
        }
        #expect(workspace.trainingState == "running")
        #expect(workspace.result?.state == .training)
        await workspace.stopEverything()
    }

    @MainActor @Test
    func stoppedComputerIsKeptWhenRentingAnotherAndCanBeRestarted() async throws {
        let workspace = GPUWorkspace(demoMode: true)
        workspace.rentsCaptionServer = true
        await workspace.refreshOffers()
        await workspace.rent()
        workspace.monitorTask?.cancel()
        let first = try #require(workspace.pod?.id)
        await workspace.stopEverything()
        workspace.rentsCaptionServer = false
        workspace.gpuCount = 2
        await workspace.rent()
        workspace.monitorTask?.cancel()
        let second = try #require(workspace.pod?.id)
        #expect(second != first)
        #expect(workspace.saved?.rentsCaptionServer == false)
        #expect(workspace.keptPods.first?.rentsCaptionServer == true)
        #expect(workspace.keptPods.map(\.pod.id) == [first])
        #expect(workspace.hasRunningPod)
        await workspace.startKeptPod(id: first)
        workspace.monitorTask?.cancel()
        #expect(workspace.pod?.id == first)
        #expect(workspace.rentsCaptionServer)
        #expect(workspace.keptPods.first?.rentsCaptionServer == false)
        #expect(workspace.hasRunningPod)
        #expect(workspace.keptPods.map(\.pod.id) == [second])
        #expect(workspace.keptPods.allSatisfy { !$0.pod.isRunning })
        await workspace.removeKeptPod(id: second)
        #expect(workspace.keptPods.isEmpty)
        await workspace.stopEverything()
    }

    @MainActor @Test
    func removingMissingKeptPodClearsRecordAndCredentials() async throws {
        let (preferences, suite) = try temporaryPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let transport = UnreachableAgentTransport()
        var removedAccounts: [String] = []
        let workspace = makeWorkspace(transport, preferences, deleteAgentToken: { removedAccounts.append($0) })
        try workspace.configure(runpodKey: "fixture", hubToken: "fixture", imageName: "fixture")
        await workspace.refreshOffers()
        await workspace.rent()
        workspace.monitorTask?.cancel()
        let id = try #require(workspace.pod?.id)
        let secret = try #require(workspace.saved?.agentSecret)
        await workspace.stopEverything()
        await workspace.keepStoppedPod()
        #expect(workspace.keptPods.count == 1)
        await transport.removePodOutside()
        await workspace.removeKeptPod(id: id)
        #expect(workspace.failure == nil)
        #expect(workspace.keptPods.isEmpty)
        #expect(removedAccounts == ["pod.\(id)"])
        #expect(await transport.deletedSecrets.contains(secret))
        let persisted = try #require(preferences.data(forKey: GPUWorkspace.keptPodsKey))
        #expect(try JSONDecoder().decode([SavedPod].self, from: persisted).isEmpty)
        #expect(workspace.message.contains("no longer tracks it"))
    }

    @MainActor @Test
    func offersMustHaveStockBesideTheSelectedStorage() async {
        let workspace = GPUWorkspace(demoMode: true)
        await workspace.refreshOffers()
        #expect(workspace.availableOffers.count == 1)
        workspace.volumes.append(GPUVolume(id: "elsewhere", name: "Elsewhere", size: 100, dataCenter: "other"))
        workspace.selectedVolume = "elsewhere"
        workspace.selectAvailableOffer()
        #expect(workspace.availableOffers.isEmpty)
        #expect(workspace.selectedGPU.isEmpty)
        #expect(workspace.quotedHourlyRate == 0)
        await workspace.rent()
        #expect(workspace.pod == nil)
        workspace.selectedVolume = "demo-volume"
        workspace.offers[0].dataCenters = [.init(id: "demo", availability: "NONE")]
        workspace.selectAvailableOffer()
        #expect(workspace.availableOffers.isEmpty)
    }

    @MainActor @Test
    func undersizedGPUsCannotBeRentedForTheIncludedModels() async {
        let workspace = GPUWorkspace(demoMode: true)
        await workspace.refreshOffers()
        workspace.offers = [24, 32].map { memory in
            GPUOffer(
                gpuID: "gpu-\(memory)", name: "GPU", memory: memory, price: 1, maxCount: 4,
                dataCenters: [.init(id: "demo", availability: "HIGH")]
            )
        }
        #expect(workspace.availableOffers.map(\.gpuID) == ["gpu-32"])
        workspace.selectedGPU = "SECURE/gpu-24"
        await workspace.rent()
        #expect(workspace.pod == nil)
        workspace.selectAvailableOffer()
        #expect(workspace.selectedGPU == "SECURE/gpu-32")
        await workspace.rent()
        #expect(workspace.hasRunningPod)
        await workspace.stopEverything()
    }

    @MainActor @Test
    func trainerDefaultsApplyBeforeAnyTrainingViewExists() {
        let workspace = GPUWorkspace(demoMode: true)
        workspace.trainer = "ltx"
        #expect(workspace.baseModel == "Lightricks/LTX-2.3")
        workspace.baseModel = "custom/model"
        workspace.trainer = "ltx"
        #expect(workspace.baseModel == "custom/model")
        workspace.trainer = "aitoolkit"
        #expect(workspace.baseModel == "black-forest-labs/FLUX.1-dev")
    }

    @MainActor @Test
    func restoredBudgetStillStopsWhenAgentKeyCannotBeRead() async throws {
        let (preferences, suite) = try temporaryPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let saved = SavedPod(
            pod: RentedPod(id: "test", status: "RUNNING", cost: 1, gpu: .init(count: 1)),
            started: Date().addingTimeInterval(-7200), hourlyRate: 1, budget: 1,
            trainer: "aitoolkit", runID: "previous-run"
        )
        try preferences.set(JSONEncoder().encode(saved), forKey: GPUWorkspace.activePodKey)
        let transport = UnreachableAgentTransport()
        let workspace = makeWorkspace(
            transport, preferences, readAgentToken: { _ in throw StudioError.message("Keychain unavailable") }
        )
        #expect(throws: StudioError.self) {
            try workspace.configure(runpodKey: "test", hubToken: "test", imageName: "test")
        }
        #expect(workspace.hasRunningPod)
        #expect(workspace.runID == "previous-run")
        try await waitUntil { !workspace.hasRunningPod }
        #expect(workspace.pod?.status == "EXITED")
        #expect(await transport.stopCalls == 1)
    }

    @MainActor @Test(arguments: [true, false])
    func captionReadinessUsesItsOwnKeyAndCanBeCancelled(_ ready: Bool) async throws {
        let (preferences, suite) = try temporaryPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let transport = UnreachableAgentTransport(agentAvailable: true, inferenceReady: ready)
        let workspace = makeWorkspace(transport, preferences)
        try workspace.configure(runpodKey: "provider-only", hubToken: "hub-only", imageName: "test")
        await workspace.refreshOffers()
        await workspace.rent()
        let starting = Task { await workspace.startCaptioning() }
        for _ in 0 ..< 100 {
            if await !transport.inferenceRequests.isEmpty { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        if !ready { starting.cancel() }
        #expect(await starting.value == ready)
        #expect(!workspace.isBusy)
        let request = try #require(await transport.inferenceRequests.first)
        #expect(request.url?.absoluteString == "https://test-8000.proxy.runpod.net/v1/models")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + workspace.agentToken)
        try expectCaptionStart(#require(await transport.starts.first), model: workspace.captionModel)
        await workspace.stopEverything()
        #expect(!workspace.hasRunningPod)
    }

    @MainActor @Test
    func captionStartupWaitsForBootAndAppTrafficPreventsIdleStop() async throws {
        let (preferences, suite) = try temporaryPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let transport = UnreachableAgentTransport(inferenceReady: true)
        let workspace = makeWorkspace(transport, preferences)
        try workspace.configure(runpodKey: "test", hubToken: "test", imageName: "test")
        await workspace.refreshOffers()
        await workspace.rent()
        workspace.monitorTask?.cancel()
        let starting = Task { await workspace.startCaptioning() }
        try await waitUntil { workspace.captionStartupProgress != nil }
        #expect(workspace.failure == nil)
        await transport.agentReachable(true)
        #expect(await starting.value)
        #expect(workspace.captionStartupProgress == nil)
        #expect(workspace.agentReadyAt != nil)
        workspace.idleMinutes = 1
        workspace.beginAppWork()
        workspace.lastActivity = .distantPast
        await workspace.refresh()
        #expect(workspace.hasRunningPod)
        workspace.endAppWork()
        #expect(Date().timeIntervalSince(workspace.lastActivity) < 1)
        await workspace.stopEverything()
    }

    @MainActor @Test
    func budgetWatchSurvivesFailedKeychainAndEmergencyStop() async throws {
        let (preferences, suite) = try temporaryPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let transport = UnreachableAgentTransport(failFirstStop: true)
        let workspace = makeWorkspace(
            transport, preferences, saveAgentToken: { _, _ in throw StudioError.message("Keychain unavailable") }
        )
        try workspace.configure(runpodKey: "test", hubToken: "test", imageName: "test")
        await workspace.refreshOffers()
        workspace.budget = 0.000000001
        await workspace.rent()
        try await waitUntil { !workspace.hasRunningPod }
        #expect(workspace.pod?.status == "EXITED")
        #expect(await transport.stopCalls >= 2)
    }

    @Test(arguments: ["EXITED", "ERROR", "TERMINATED"])
    func stoppedProviderStatesDoNotRequireAnInvalidStopAction(_ status: String) {
        let pod = RentedPod(id: "pod1", status: status, cost: 0, gpu: .init(count: 1))
        #expect(!pod.isRunning)
    }

    @MainActor @Test
    func demoTrainsPublishesAndStopsWithoutNetwork() async throws {
        let transport = GPUTransport()
        let workspace = GPUWorkspace(demoMode: true, transport: transport)
        try workspace.configure(runpodKey: "must-not-use", hubToken: "must-not-use", imageName: "live-image")
        await workspace.refreshOffers()
        workspace.gpuCount = 2
        await workspace.rent()
        #expect(workspace.hasRunningPod)
        await workspace.refresh()
        #expect(workspace.plan?.mode == "concurrent")
        #expect(workspace.plan?.train?.gpus == [1])
        await workspace.train(datasetRepo: "demo/images", output: HubDestination(repo: "demo/result"))
        #expect(!workspace.runID.isEmpty)
        // The demo run ends after eight progress reads. A slow CI machine can spend a refresh elsewhere,
        // so refresh until the run has ended and its result settled, within a fixed bound.
        for _ in 0 ..< 50 where workspace.trainingState != "exited" || workspace.result?.state == .training {
            await workspace.refresh()
        }
        #expect(!workspace.points.isEmpty)
        #expect(workspace.trainingState == "exited")
        #expect(workspace.result?.state == .pushed(repo: "demo/result"))
        #expect(workspace.runHistory.last?.datasetRepo == "demo/images")
        #expect(workspace.runHistory.last?.params["seed"] == .int(42))
        workspace.projectFolder = nil // the view's initial destination hook also assigns nil in the demo
        #expect(workspace.runHistory.count == 1)
        await workspace.stopEverything()
        #expect(!workspace.hasRunningPod)
        #expect(await transport.requests.isEmpty)
    }

    @MainActor @Test
    func spendingCapStopsTheActualProviderState() async throws {
        let workspace = GPUWorkspace(demoMode: true)
        await workspace.refreshOffers()
        workspace.budget = 1
        await workspace.rent()
        try await workspace.enforceLimits(now: Date().addingTimeInterval(7200))
        #expect(workspace.pod?.status == "EXITED")
        #expect(workspace.message.contains("spending limit"))
    }

    @MainActor @Test
    func theBudgetCanOnlyBeRaisedWhileRunning() async throws {
        let workspace = GPUWorkspace(demoMode: true)
        await workspace.refreshOffers()
        workspace.budget = 5
        #expect(!workspace.raiseBudget(to: 10))
        await workspace.rent()
        #expect(!workspace.raiseBudget(to: 4))
        #expect(!workspace.raiseBudget(to: .infinity))
        #expect(workspace.activeBudget == 5)
        #expect(workspace.raiseBudget(to: 10))
        #expect(workspace.activeBudget == 10)
        // $1.50/hour: six hours is $9, under the raised limit; seven is $10.50, over it.
        try await workspace.enforceLimits(now: Date().addingTimeInterval(6 * 3600))
        #expect(workspace.hasRunningPod)
        try await workspace.enforceLimits(now: Date().addingTimeInterval(7 * 3600))
        #expect(!workspace.hasRunningPod)
    }

    @Test
    func captionServerSettingsComeFromTheMeasuredTable() {
        let measured = GPUWorkspace.captionServerSettings(for: "Qwen/Qwen3-VL-8B-Instruct")
        #expect(measured.maxNumSeqs == 2)
        #expect(GPUWorkspace.captionServerSettings(for: "someone/unmeasured") == measured)
        #expect(measured.params(model: "someone/unmeasured")["model"]?.stringValue == "someone/unmeasured")
        let capQwen = GPUWorkspace.captionServerSettings(for: ProviderChoices.defaultSelfHostedModel)
        #expect(capQwen.maxModelLen == 16384)
        #expect(capQwen.maxNumSeqs == 4)
        #expect(capQwen.gpuMemoryUtilization == 0.90)
        #expect(capQwen.extraArgs == ["--enforce-eager", "--max-num-batched-tokens=4096"])
    }

    @Test
    func podNamesCarryTheProject() {
        #expect(PodNaming.name(project: "My Project!") == "ConceptStudio-My-Project")
        #expect(PodNaming.name(project: "") == "ConceptStudio")
        #expect(RentedPod(id: "a", status: "RUNNING", cost: 0, gpu: .init(count: 1), name: "ConceptStudio")
            .isFromThisApp)
        #expect(!RentedPod(id: "a", status: "RUNNING", cost: 0, gpu: .init(count: 1), name: "ConceptStudioX")
            .isFromThisApp)
    }

    @Test(arguments: ["aitoolkit", "ltx", "musubi"])
    func creationUsesV2GPUFieldsAndOnlyAuthenticatedPublishedPorts(_ trainer: String) async throws {
        let transport = GPUTransport(#"{"id":"pod1","status":"STARTING","cost":1,"gpu":{"count":2}}"#)
        let provider = RunPodProvider(key: "runpod-key", transport: transport)
        let offer = GPUOffer(gpuID: "gpu-id", name: "GPU", memory: 80, price: 1, maxCount: 4)
        let pod = try await provider.create(PodCreation(
            name: PodNaming.name(project: "nora"), offer: offer, count: 2, image: "own/image:verified",
            minCudaVersion: GPUWorkspace.minimumCUDA(trainer),
            volume: GPUVolume(id: "volume", name: "Data", size: 100, dataCenter: "EU-IS-1"),
            env: [
                "PODAGENT_TOKEN": PodSecrets.reference("conceptstudio_agent_test"),
                "HF_TOKEN": PodSecrets.reference(PodSecrets.hubTokenName),
            ]
        ))
        let request = try #require(await transport.requests.first)
        #expect(request.url?.absoluteString == "https://api.runpod.io/v2/pods")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer runpod-key")
        let body = try JSONValue(parsing: #require(request.httpBody)).objectValue
        #expect(body?["name"]?.stringValue == "ConceptStudio-nora")
        #expect(body?["gpu"]?.objectValue?["count"]?.intValue == 2)
        // Both trainer images carry CUDA 13 wheels and need an R580+ (CUDA 13.0) host driver.
        #expect(body?["gpu"]?.objectValue?["minCudaVersion"]?.stringValue == "13.0")
        #expect(body?["gpu"]?.objectValue?["minRamPerGpu"]?.intValue == 60)
        #expect(body?["ports"]?.arrayValue?.compactMap(\.stringValue) == ["8800/http", "8000/http", "22/tcp"])
        #expect(body?["mounts"]?.objectValue?["network"]?.arrayValue?.first?.objectValue?["path"]?.stringValue
            == "/workspace")
        // Credentials reach the pod as secret references, never as values (POD-SPEC §1).
        #expect(body?["env"]?.objectValue?["HF_TOKEN"]?.stringValue == "{{ RUNPOD_SECRET_conceptstudio_hf_token }}")
        #expect(body?["env"]?.objectValue?["PODAGENT_TOKEN"]?.stringValue
            == "{{ RUNPOD_SECRET_conceptstudio_agent_test }}")
        #expect(provider.url(for: pod, port: PodPort.agent).absoluteString == "https://pod1-8800.proxy.runpod.net")
        _ = try? await provider.offers(count: 1, minCudaVersion: GPUWorkspace.minimumCUDA(trainer))
        let query = try #require(await transport.requests.last?.url?.query())
        #expect(query.contains("minCudaVersion=13.0"))
    }
}
