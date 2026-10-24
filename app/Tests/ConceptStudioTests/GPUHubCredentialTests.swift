import ConceptCore
@testable import ConceptStudio
import Foundation
import Testing

private actor HubAccessFixture {
    private(set) var reads = 0
    var failAfter: Int?

    init(failAfter: Int? = nil) {
        self.failAfter = failAfter
    }

    func token() throws -> String {
        reads += 1
        if let failAfter, reads > failAfter { throw StudioError.message("Sign in with Hugging Face again.") }
        return "oauth-fixture-access-\(reads)"
    }
}

@MainActor @Suite("GPU OAuth access-token lifetime")
struct GPUHubCredentialTests {
    private func connected(_ defaults: UserDefaults, agent: any PodAgent, folder: URL? = nil) -> GPUWorkspace {
        let gpu = makeWorkspace(GPUTransport(), defaults)
        gpu.projectFolder = folder
        gpu.pod = RentedPod(id: "fixture", status: "RUNNING", cost: 1, gpu: .init(count: 2))
        gpu.saved = SavedPod(
            pod: gpu.pod!, started: Date(), hourlyRate: 1, budget: 10, trainer: "aitoolkit",
            runID: "", volumeID: "storage"
        )
        gpu.agent = agent
        return gpu
    }

    private func run() -> TrainingRun {
        let params: JSONObject = [
            "run_id": .string("saved-run"), "base_model": .string("black-forest-labs/FLUX.1-dev"),
            "steps": .int(200), "rank": .int(16), "resolution": .int(512),
            "triggers": .array([.string("NORA7")]), "profile": .string("flux-image"),
            "dataset": .object(["path": .string("/workspace/datasets/saved-run")]),
            "hub": .object([
                "repo_id": .string("fixture/model"),
                "private": .bool(true),
                "push_on_finish": .bool(true),
            ]),
        ]
        return TrainingRun(
            runID: "saved-run", trainer: "aitoolkit", datasetRepo: "fixture/data", datasetContainsVideo: false,
            paramsJSON: JSONValue.object(params).pythonDumpsData(), volumeID: "storage", startedAt: Date(),
            updatedAt: Date(),
            result: TrainingResult(
                runID: "saved-run", outputRepo: "fixture/model", destination: .hub,
                volumeID: "storage", state: .pushed(repo: "fixture/model")
            ), points: [.init(step: 200, loss: 0.1)],
            checkpoints: [.init(path: "final.safetensors", size: 7, sha256: sha256(Data("weights".utf8)))],
            gpuBudgetUSD: 10, podSpendAtStart: 0
        )
    }

    @Test(arguments: [false, true])
    func unsupportedAgentFailsBeforeReadingCredential(explicitFalse: Bool) async throws {
        let defaults = IsolatedDefaults()
        defer { defaults.remove() }
        let agent = HistoryAgent(), tokens = HubAccessFixture()
        await agent.reportHubTokenSupport(explicitFalse ? false : nil)
        let gpu = connected(defaults.defaults, agent: agent)
        gpu.hubOAuthToken = { try await tokens.token() }
        gpu.hubToken = "never-fall-back-to-manual"
        await #expect(throws: StudioError.self) {
            try await gpu.paramsWithFreshHubToken(
                ["model": .string("fixture/model")], service: "vllm", agent: agent
            )
        }
        #expect(await tokens.reads == 0)
        #expect(await agent.starts.isEmpty)
    }

    @Test(arguments: ["upscale-media", "vllm"])
    func upscaleRejectsUnsupportedOAuthBeforeInputOrCaptionEffects(_ unsupported: String) async throws {
        let defaults = IsolatedDefaults()
        defer { defaults.remove() }
        let folder = temporaryTestDirectory("oauth-upscale-admission")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let input = folder.appendingPathComponent("sample.jpg")
        try Data("synthetic source".utf8).write(to: input)
        let retained = unsupported == "vllm"
        let agent = UpscaleAgent(
            unsupportedHubServices: [unsupported], concurrent: retained, captionRunning: !retained
        )
        let tokens = HubAccessFixture()
        let gpu = connected(defaults.defaults, agent: agent)
        gpu.hubOAuthToken = { try await tokens.token() }
        gpu.keepCaptionServer = retained
        // The action must refresh an older inventory that still enabled the button.
        await gpu.updateServiceState(agent.services().map { original in
            var service = original
            service.supportsHFToken = true
            return service
        })
        #expect(gpu.upscaleUnavailableReason == nil)
        var progress: [String] = []
        do {
            _ = try await gpu.upscale(
                [.init(sampleID: "sample.jpg", file: input)], model: .standard,
                target: UpscaleTarget(shortSide: 1024), into: folder.appendingPathComponent("out")
            ) { progress.append($0) }
            Issue.record("Upscale used an image without the required OAuth service capability")
        } catch {
            #expect(error.localizedDescription == gpu.serviceUnavailableReason(unsupported))
        }
        #expect(gpu.upscaleUnavailableReason != nil)
        #expect(progress.isEmpty)
        #expect(await agent.uploads.isEmpty)
        #expect(await agent.starts.isEmpty)
        #expect(await agent.stops.isEmpty)
        #expect(await tokens.reads == 0)
    }

    @Test(arguments: ["manual", "community", "anonymous"])
    func oauthCapabilityDoesNotBlockOtherCredentialsOrLocalServices(_ connection: String) async throws {
        let defaults = IsolatedDefaults()
        defer { defaults.remove() }
        let folder = temporaryTestDirectory("legacy-upscale-admission")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let input = folder.appendingPathComponent("sample.jpg")
        try Data("synthetic source".utf8).write(to: input)
        let agent = UpscaleAgent(
            unsupportedHubServices: ["upscale-media", "vllm", "tensorboard", "cleanup-datasets"], captionRunning: true
        )
        let tokens = HubAccessFixture()
        let gpu = connected(defaults.defaults, agent: agent)
        gpu.keepCaptionServer = false
        if connection == "manual" { gpu.hubToken = "manual-fixture" }
        if connection == "community" {
            gpu.hubOAuthToken = { try await tokens.token() }
            gpu.saved?.hubTokenOnPod = false
        }
        let outcome = try await gpu.upscale(
            [.init(sampleID: "sample.jpg", file: input)], model: .standard,
            target: UpscaleTarget(shortSide: 1024), into: folder.appendingPathComponent("out")
        ) { _ in }
        #expect(outcome.results["sample.jpg"] != nil)
        #expect(await agent.uploads.count == 1)
        #expect(await agent.starts.map(\.service) == ["upscale-media"])
        #expect(await agent.stops == ["vllm"])
        #expect(await agent.starts.first?.params["hf_token"] == nil)
        #expect(await tokens.reads == 0)
        // Noncredentialed tools remain usable even with OAuth on an eligible Secure Cloud pod.
        gpu.hubOAuthToken = { try await tokens.token() }
        gpu.saved?.hubTokenOnPod = true
        try await gpu.requireServices(["tensorboard", "cleanup-datasets"], from: agent)
        #expect(gpu.serviceUnavailableReason("tensorboard") == nil)
        #expect(gpu.serviceUnavailableReason("cleanup-datasets") == nil)
        #expect(await tokens.reads == 0)
    }

    @Test func capabilityMustBelongToRequestedService() async throws {
        let defaults = IsolatedDefaults()
        defer { defaults.remove() }
        let agent = HistoryAgent(), tokens = HubAccessFixture()
        let gpu = connected(defaults.defaults, agent: agent)
        gpu.hubOAuthToken = { try await tokens.token() }
        await #expect(throws: StudioError.self) {
            try await gpu.paramsWithFreshHubToken([:], service: "unknown-service", agent: agent)
        }
        #expect(await tokens.reads == 0)
        let canonical: JSONObject = ["model": .string("fixture/model")]
        let request = try await gpu.paramsWithFreshHubToken(canonical, service: "vllm", agent: agent)
        #expect(request["hf_token"] == .string("oauth-fixture-access-1"))
        #expect(canonical["hf_token"] == nil)
        #expect(await agent.starts.isEmpty)
    }

    @Test func legacyServiceInventoryDecodesWithoutCapability() throws {
        let legacy = Data(#"{"name":"vllm","state":"idle","available":true}"#.utf8)
        #expect(try JSONDecoder().decode(AgentService.self, from: legacy).supportsHFToken == nil)
        let current = Data(#"{"name":"vllm","state":"idle","supports_hf_token":true}"#.utf8)
        #expect(try JSONDecoder().decode(AgentService.self, from: current).supportsHFToken == true)
    }

    @Test func rentalTrainingAndDeferredPublishingUseFreshAccessWithoutSavingIt() async throws {
        let defaults = IsolatedDefaults()
        defer { defaults.remove() }
        let tokens = HubAccessFixture()
        let transport = UnreachableAgentTransport(agentAvailable: true, inferenceReady: true)
        let gpu = makeWorkspace(transport, defaults.defaults)
        try gpu.configure(
            runpodKey: "provider-fixture", hubToken: "", imageName: "test",
            hubOAuthToken: { try await tokens.token() }
        )
        #expect(gpu.usesHubOAuth && gpu.hasHubCredential && gpu.hubToken.isEmpty)
        await gpu.refreshOffers()
        await gpu.rent()
        gpu.monitorTask?.cancel()
        await gpu.monitorTask?.value
        #expect(await transport.secretValue(PodSecrets.hubTokenName) == "oauth-fixture-access-1")
        await gpu.train(datasetRepo: "fixture/data", output: HubDestination(repo: "fixture/model"))
        #expect(gpu.failure == nil)
        let start = try await trainerParams(transport, "aitoolkit")
        #expect(start["hf_token"] == .string("oauth-fixture-access-3"))
        #expect(start["hub"]?.objectValue?["push_on_finish"] == .bool(false))
        #expect(gpu.runHistory.first?.params["hf_token"] == nil)
        #expect(gpu.runHistory.first?.params["hub"]?.objectValue?["push_on_finish"] == .bool(false))
        #expect(gpu.result?.destination == .hub)
        let id = gpu.runID
        let weights = Data("weights".utf8)
        await transport.files([RunFile(path: "final.safetensors", size: weights.count, sha256: sha256(weights))])
        await transport.finish("trainer-aitoolkit", state: "exited")
        gpu.isBusy = true // Observe settlement before automatic retrieval starts.
        try await gpu.settleResult(#require(gpu.agent), services: [
            AgentService(name: "trainer-aitoolkit", state: "exited", groupAlive: false, runID: id),
        ])
        #expect(gpu.result?.state == .pending)
        gpu.isBusy = false
        await gpu.retrieveResult()
        #expect(gpu.result?.state == .pushed(repo: "fixture/model"))
        let push = try #require(await transport.starts.last { $0.url?.path() == "/services/push-lora/start" })
        let params = try JSONValue(parsing: #require(push.httpBody)).objectValue?["params"]?.objectValue
        #expect(params?["hf_token"] == .string("oauth-fixture-access-4"))
        let saved = try JSONEncoder().encode(gpu.runHistory)
        #expect(try !#require(String(bytes: saved, encoding: .utf8)?.contains("oauth-fixture-access")))
        let savedPod = try #require(defaults.defaults.data(forKey: GPUWorkspace.activePodKey))
        #expect(try !#require(String(bytes: savedPod, encoding: .utf8)?.contains("oauth-fixture-access")))
        await gpu.stopEverything()
    }

    @Test func resumeUsesCurrentOAuthAndKeepsCanonicalParamsSecretFree() async throws {
        let defaults = IsolatedDefaults()
        defer { defaults.remove() }
        let folder = temporaryTestDirectory("oauth-resume")
        defer { try? FileManager.default.removeItem(at: folder) }
        let agent = HistoryAgent(), tokens = HubAccessFixture()
        let gpu = connected(defaults.defaults, agent: agent, folder: folder)
        gpu.hubOAuthToken = { try await tokens.token() }
        let saved = run()
        gpu.runHistory = [saved]
        await gpu.resumeRun(saved, totalSteps: 400)
        #expect(gpu.failure == nil)
        let start = try #require(await agent.starts.last { $0.service == "trainer-aitoolkit" })
        #expect(start.params["resume"] == .bool(true))
        #expect(start.params["hf_token"] == .string("oauth-fixture-access-1"))
        #expect(start.params["hub"]?.objectValue?["push_on_finish"] == .bool(false))
        let records = ProjectTrainingRecord.load(from: folder)
        #expect(records.runs.first?.params["hf_token"] == nil)
        #expect(records.runs.first?.params["hub"]?.objectValue?["push_on_finish"] == .bool(false))
        #expect(gpu.result?.destination == .hub)
    }

    @Test func renewalFailureCannotStartTrainerOrUsePastedFallback() async {
        let defaults = IsolatedDefaults()
        defer { defaults.remove() }
        let agent = HistoryAgent(), tokens = HubAccessFixture(failAfter: 1)
        let gpu = connected(defaults.defaults, agent: agent)
        gpu.hubToken = "manual-must-not-be-used"
        gpu.hubOAuthToken = { try await tokens.token() }
        await gpu.train(datasetRepo: "fixture/data", output: HubDestination(repo: "fixture/model"))
        #expect(gpu.failure?.contains("Sign in with Hugging Face again") == true)
        #expect(await agent.starts.map(\.service) == ["pull-dataset"])
        #expect(gpu.result?.state == .failed)
        #expect(gpu.runHistory.first?.params["hf_token"] == nil)
    }

    @Test func communityRentalNeverRequestsOrTransfersOAuthToken() async throws {
        let defaults = IsolatedDefaults()
        defer { defaults.remove() }
        let transport = UnreachableAgentTransport(agentAvailable: true)
        await transport.offerCommunityCloud()
        let tokens = HubAccessFixture()
        let gpu = makeWorkspace(transport, defaults.defaults)
        try gpu.configure(
            runpodKey: "provider-fixture", hubToken: "", imageName: "test", hubOAuthToken: { try await tokens.token() }
        )
        gpu.chooseTrainingModel(ungatedModel)
        gpu.includeCommunityCloud = true
        await gpu.refreshOffers()
        gpu.chooseStorage("")
        gpu.selectedGPU = "COMMUNITY/test"
        await gpu.rent()
        gpu.monitorTask?.cancel()
        await gpu.monitorTask?.value
        #expect(gpu.failure == nil && gpu.pod != nil)
        #expect(await tokens.reads == 0)
        #expect(await transport.secretValue(PodSecrets.hubTokenName) == nil)
        #expect(await transport.createBodies.first?["env"]?.objectValue?["HF_TOKEN"] == nil)
        #expect(!gpu.cloudGPUHoldsHubToken && gpu.usesLocalDataset)
        let params = try await gpu.paramsWithFreshHubToken(
            ["run_id": .string("fixture")], service: "vllm", agent: #require(gpu.agent)
        )
        #expect(params["hf_token"] == nil)
        #expect(await tokens.reads == 0)
        await gpu.stopEverything()
    }

    @Test func tokenFreeLocalInstallAndManualServiceParamsRemainUnchanged() async throws {
        let defaults = IsolatedDefaults()
        defer { defaults.remove() }
        let project = try await captionedUploadProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        let snapshot = try await LocalTrainingDataset.prepare(projectFolder: project.directory)
        defer { snapshot.remove() }
        let agent = DatasetUploadAgent(), tokens = HubAccessFixture()
        let gpu = connected(defaults.defaults, agent: agent)
        gpu.hubOAuthToken = { try await tokens.token() }
        try await gpu.installTrainingDataset(snapshot, repo: "", revision: nil, name: "fixture", agent: agent)
        let start = try #require(await agent.starts.first)
        #expect(start.params["local_name"] == .string("fixture"))
        #expect(start.params["hf_token"] == nil)
        #expect(await tokens.reads == 0)
        gpu.hubOAuthToken = nil
        gpu.hubToken = "manual-fixture"
        let params: JSONObject = ["model": .string("fixture/model")]
        #expect(try await gpu.paramsWithFreshHubToken(params, service: "vllm", agent: agent) == params)
        #expect(try await gpu.freshHubToken() == "manual-fixture")
    }

    @Test func expiredPublicationStillSavesWeightsLocally() async throws {
        let defaults = IsolatedDefaults()
        defer { defaults.remove() }
        let folder = temporaryTestDirectory("oauth-preservation")
        defer { try? FileManager.default.removeItem(at: folder) }
        let agent = HistoryAgent(), tokens = HubAccessFixture(failAfter: 0)
        let gpu = connected(defaults.defaults, agent: agent, folder: folder)
        gpu.hubOAuthToken = { try await tokens.token() }
        var saved = run()
        saved.result?.state = .pending
        gpu.runHistory = [saved]
        gpu.result = saved.result
        let weights = Data("weights".utf8)
        await agent.serve(["final.safetensors": weights])
        await gpu.retrieveResult()
        guard case let .saved(path) = gpu.result?.state else { Issue.record("Weights were not saved"); return }
        #expect(try Data(contentsOf: URL(fileURLWithPath: path).appendingPathComponent("final.safetensors")) == weights)
        #expect(await agent.starts.isEmpty)
        #expect(await tokens.reads == 1)
    }

    @Test(arguments: [false, true])
    func unreadableAccountDoesNotSilentlyChooseLocalDeliveryForOAuth(oauth: Bool) async throws {
        let defaults = IsolatedDefaults()
        defer { defaults.remove() }
        let gpu = connected(defaults.defaults, agent: HistoryAgent(), folder: temporaryTestDirectory("hub-account"))
        gpu.hubToken = "manual-fixture"
        if oauth { gpu.hubOAuthToken = { "oauth-fixture" } }
        if oauth {
            await #expect(throws: StudioError.self) { try await gpu.suggestedOutputRepo() }
        } else {
            #expect(try await gpu.suggestedOutputRepo() == nil)
        }
    }
}
