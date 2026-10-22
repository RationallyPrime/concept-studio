import ConceptCore
@testable import ConceptStudio
import Foundation
import Testing

private actor ReportReplyClient: ModelClient {
    nonisolated let requestedModel = "test-captioner"
    private(set) var messages: [ChatMessage] = []
    private(set) var settings: RequestSettings?

    func request(
        instructions: String, messages: [ChatMessage], output: OutputRequest, settings: RequestSettings,
        onPartialText: (@Sendable (String) async -> Void)?
    ) async throws -> ModelReply {
        self.messages = messages
        self.settings = settings
        return ModelReply(
            text: #"{"score":0.75,"explanation":"The setting and action match."}"#,
            servedModel: requestedModel
        )
    }
}

@Suite("Frozen post-training reports")
@MainActor
struct TrainingReportTests {
    private func workspace(_ project: StudioProject, preferences: UserDefaults) -> GPUWorkspace {
        let workspace = makeWorkspace(GPUTransport(), preferences)
        workspace.chooseTrainingModel("black-forest-labs/FLUX.1-dev")
        workspace.projectFolder = project.directory
        return workspace
    }

    @Test func categoryDraftsUseOnlyAttributesAbsentFromCaptionsAndKeepEveryConcept() throws {
        let concepts = try TargetConcept.allCases.enumerated().map {
            try Concept(trigger: "SUBJECT\($0.offset)", targetConcept: $0.element)
        }
        let job = try Job(profile: "plain", concepts: concepts)
        let captions = ["A person in a yellow raincoat holds a cup in a snowy garden beside a teapot."]
        let prompts = ReportPrompts.draft(job: job, captions: captions)
        #expect(prompts.filter { $0.kind == .concept }.count == concepts.count)
        #expect(prompts.filter { $0.kind == .bleed }.count == 2)
        #expect(prompts.count > 6)
        for prompt in prompts {
            #expect(!prompt.text.isEmpty)
            #expect(prompt.heldOutAttributes.allSatisfy { prompt.text.contains($0) })
            #expect(!prompt.text.contains("raincoat"))
            #expect(!prompt.text.contains("snowy"))
            #expect(!prompt.text.contains("teapot"))
            if prompt.kind == .bleed { #expect(!prompt.text.contains(prompt.trigger)) }
        }
    }

    @Test func unavailableAttributesLeaveAnEditableBlankWithoutInventedHeldOutClaims() throws {
        let job = try Job(profile: "plain", concepts: [Concept(trigger: "OBJECT7", targetConcept: .object)])
        let captions = ["snow winter library harbour sunrise archway greenhouse"]
        let prompt = try #require(ReportPrompts.draft(job: job, captions: captions).first)
        #expect(prompt.text.isEmpty)
        #expect(prompt.heldOutAttributes.isEmpty)
    }

    @Test(arguments: [false, true])
    func switchingAdultPolicyRequiresNewManualPromptsEvenAfterAGroupWasUsed(frozen: Bool) async throws {
        var project = try await makeDemoProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        let preferences = IsolatedDefaults()
        defer { preferences.remove() }
        let workspace = workspace(project, preferences: preferences.defaults)
        try await workspace.prepareReportDraft()
        let original = try #require(workspace.selectedReportGroup)
        #expect(!original.needsPrompts)
        if frozen { _ = try await workspace.prepareTrainingReport() }
        project.job.adultContent = true
        try project.save()
        try await workspace.prepareReportDraft()
        let manual = try #require(workspace.selectedReportGroup)
        #expect(manual.id != original.id)
        #expect(manual.manualPrompts)
        #expect(manual.prompts.allSatisfy { $0.text.isEmpty && $0.heldOutAttributes.isEmpty })
        await #expect(throws: StudioError.self) { try await workspace.prepareTrainingReport() }
        for prompt in manual.prompts {
            workspace.editReportPrompt(prompt.id, text: "A fully clothed adult in a quiet library.")
        }
        #expect(try await workspace.prepareTrainingReport() == manual.id)
        #expect(workspace.selectedReportGroup?.frozenAt != nil)
    }

    @Test func settingsReferencesAndUsedPromptGroupStayFrozenAcrossEditsAndReload() async throws {
        var project = try await makeDemoProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        let preferences = IsolatedDefaults()
        defer { preferences.remove() }
        project.job.endpoints = try Endpoints(captioner: EndpointSpec(
            kind: "vllm", model: "test-captioner", baseURL: "https://caption.invalid/v1",
            settings: ["extra_body": .object([
                "chat_template_kwargs": .object(["enable_thinking": .bool(false)]),
                "temperature": .double(0.7), "seed": .int(999),
            ])]
        ))
        try project.save()
        let workspace = workspace(project, preferences: preferences.defaults)
        _ = try await workspace.prepareTrainingReport()
        let group = try #require(workspace.selectedReportGroup)
        #expect(group.frozenAt != nil)
        #expect(group.settings.judgeRequestSettings.temperature == 0)
        #expect(group.settings.judgeRequestSettings.seed == 42)
        #expect(group.settings.judgeRequestSettings.extraBody["seed"] == nil)
        #expect(group.settings.judgeRequestSettings.extraBody["temperature"] == nil)
        #expect(group.settings.judgeRequestSettings.extraBody["chat_template_kwargs"] == .object([
            "enable_thinking": .bool(false),
        ]))
        let reference = try #require(workspace.reportReferenceURLs(group, category: .facialIdentity)["NORA7"]?.first)
        let frozenBytes = try Data(contentsOf: reference)
        try Data("changed source reference".utf8).write(to: project.referenceURL(for: "NORA7"))
        #expect(try Data(contentsOf: reference) == frozenBytes)
        workspace.editReportPrompt(group.prompts[0].id, text: "A new prompt.")
        let edited = try #require(workspace.selectedReportGroup)
        #expect(edited.id != group.id)
        #expect(edited.frozenAt == nil)
        #expect(edited.references.isEmpty)
        #expect(edited.prompts[0].heldOutAttributes.isEmpty)
        #expect(workspace.reportGroups.first { $0.id == group.id } == group)
        let record = ProjectTrainingRecord.load(from: project.directory)
        #expect(record.reportGroups == workspace.reportGroups)
        #expect(record.selectedReportGroupID == edited.id)
        try Data("changed frozen reference".utf8).write(to: reference)
        #expect(throws: StudioError.self) {
            try workspace.reportReferenceURLs(group, category: .facialIdentity)
        }
    }

    @Test func motionGroupsRequestClipsAndImageOnlyRowsExplainWhyTheyCannotScoreMotion() async throws {
        var project = try await makeDemoProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        let preferences = IsolatedDefaults()
        defer { preferences.remove() }
        project.job = try Job(profile: "plain", concepts: [Concept(trigger: "DANCE7", targetConcept: .motion)])
        try project.save()
        let workspace = workspace(project, preferences: preferences.defaults)
        try await workspace.prepareReportDraft()
        #expect(workspace.reportAvailability?.contains("motion report needs a video") == true)
        #expect(try await workspace.prepareTrainingReport() == nil)
        workspace.chooseTrainingModel("Comfy-Org/MiniMax-H3")
        try await workspace.prepareReportDraft()
        #expect(workspace.reportAvailability == nil)
        #expect(workspace.selectedReportGroup?.settings.frames == 39)
        #expect(try await workspace.prepareTrainingReport() != nil)
    }

    @Test func reportJudgeReceivesTheWholeClipAndFrozenCaptionerSettings() async throws {
        let folder = temporaryTestDirectory("report-judge")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let clip = folder.appendingPathComponent("motion.mp4")
        let bytes = Data("synthetic clip payload".utf8)
        try bytes.write(to: clip)
        let client = ReportReplyClient()
        let settings = RequestSettings(temperature: 0, seed: 42, extraBody: [
            "chat_template_kwargs": .object(["enable_thinking": .bool(false)]),
        ])
        let judge = ReportJudge(endpoint: ResolvedEndpoint(client: client, settings: settings))
        let score = try await judge.score(file: clip, prompt: "DANCE7 performed outdoors.")
        #expect(score.score == 0.75)
        #expect(await client.messages.flatMap(\.content).contains(.video(data: bytes, mediaType: "video/mp4")))
        #expect(await client.settings == settings)
    }

    @Test func missingFaceMetricsRemainMissingAndCoverageCountsOnlyMeasuredSamples() {
        let missing = ReportSample(
            comparisonID: "render", promptID: "identity", seed: 42, basePath: "base.png", loraPath: "lora.png",
            identity: ReportMetric(base: nil, lora: nil, note: "No face detected.")
        )
        var report = TrainingReport(runID: "run", groupID: "group", samples: [missing])
        #expect(report.mean(\.identity).value == nil)
        #expect(report.mean(\.identity).count == 0)
        var measured = missing
        measured.identity = ReportMetric(base: 0.1, lora: 0.55, note: nil)
        report.samples.append(measured)
        #expect(report.mean(\.identity).value == 0.55)
        #expect(report.mean(\.identity).count == 1)
    }

    @Test func reportUsesTheTrainingRunBudgetAfterTrainingAndHonoursAnExplicitIncrease() throws {
        let preferences = IsolatedDefaults()
        defer { preferences.remove() }
        let workspace = makeWorkspace(GPUTransport(), preferences.defaults)
        workspace.pod = RentedPod(id: "offline-test", status: "RUNNING", cost: 1, gpu: .init(count: 1))
        workspace.selectedVolume = "storage"
        let run = TrainingRun(
            runID: "report-run", trainer: "aitoolkit", datasetRepo: "", datasetRevision: nil,
            datasetContainsVideo: false, paramsJSON: Data("{}".utf8), volumeID: workspace.currentVolumeID,
            startedAt: Date(), updatedAt: Date(), gpuBudgetUSD: 0, podSpendAtStart: 0
        )
        workspace.runHistory = [run]
        workspace.trainingState = "stopped" // A retained pod can resume the report after training was stopped.
        workspace.activeReportRunID = run.runID
        #expect(workspace.activeBudgetedRun?.runID == run.runID)
        #expect(throws: StudioError.self) { try workspace.requireReportBudget(run) }
        #expect(workspace.raiseRunBudget(to: 10, runID: run.runID))
        try workspace.requireReportBudget(run)
        workspace.activeReportRunID = nil
        #expect(workspace.activeBudgetedRun == nil)
    }

    @Test func reportSegmentsPreserveTrainingCostAcrossDifferentPodCountersAndReload() async throws {
        let project = try await makeDemoProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        let preferences = IsolatedDefaults()
        defer { preferences.remove() }
        let workspace = workspace(project, preferences: preferences.defaults)
        workspace.pod = RentedPod(id: "new-pod", status: "RUNNING", cost: 1, gpu: .init(count: 1))
        workspace.saved = try SavedPod(
            pod: #require(workspace.pod), started: Date(), hourlyRate: 0, budget: 10,
            trainer: "aitoolkit", runID: "report-run", volumeID: "retained"
        )
        workspace.saved?.accruedGPUCostUSD = 0.25
        workspace.runHistory = [TrainingRun(
            runID: "report-run", trainer: "aitoolkit", datasetRepo: "", datasetRevision: nil,
            datasetContainsVideo: false, paramsJSON: Data("{}".utf8), volumeID: "retained",
            startedAt: Date(), updatedAt: Date(), estimatedGPUCostUSD: 4.2,
            gpuBudgetUSD: 10, previousGPUCostUSD: 2.1, podSpendAtStart: 7.8
        )]
        workspace.beginReportBudget("report-run")
        #expect(workspace.runHistory[0].previousGPUCostUSD == 4.2)
        #expect(workspace.runHistory[0].podSpendAtStart == 0.25)
        workspace.saved?.accruedGPUCostUSD = 0.75
        workspace.finishReportBudget()
        #expect(abs((workspace.runHistory[0].estimatedGPUCostUSD ?? 0) - 4.7) < 0.0001)
        workspace.loadProjectRecord()
        workspace.saved?.accruedGPUCostUSD = 0.1
        workspace.beginReportBudget("report-run")
        #expect(workspace.runHistory[0].podSpendAtStart == 0.1)
        workspace.saved?.accruedGPUCostUSD = 0.3
        workspace.finishReportBudget()
        #expect(abs((ProjectTrainingRecord.load(from: project.directory).runs[0].estimatedGPUCostUSD ?? 0)
                - 4.9) < 0.0001)
    }

    @Test func interruptedReportOffersContinuationAndKeepsItsDownloadedOutputs() async throws {
        let project = try await makeDemoProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        let preferences = IsolatedDefaults()
        defer { preferences.remove() }
        let workspace = try makeReportPreviewWorkspace(project: project, preferences: preferences.defaults)
        workspace.trainingReports[0].state = .running
        let samples = workspace.trainingReports[0].samples
        let comparisons = workspace.generations
        #expect(workspace.saveProjectRecord())
        workspace.loadProjectRecord()
        #expect(workspace.trainingReports[0].state == .waiting)
        #expect(workspace.trainingReports[0].samples == samples)
        #expect(workspace.generations == comparisons)
        #expect(workspace.reportTask == nil)
    }

    @Test func reportBudgetStopCancelsGenerationWithoutJoiningItsOwnTask() async throws {
        let project = try await makeDemoProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        let preferences = IsolatedDefaults()
        defer { preferences.remove() }
        let workspace = workspace(project, preferences: preferences.defaults)
        let transport = UnreachableAgentTransport()
        workspace.provider = RunPodProvider(key: "synthetic", transport: transport)
        workspace.pod = RentedPod(id: "test", status: "RUNNING", cost: 1, gpu: .init(count: 1))
        workspace.saved = try SavedPod(
            pod: #require(workspace.pod), started: Date(), hourlyRate: 1, budget: 20,
            trainer: "aitoolkit", runID: "finished-run", volumeID: "retained"
        )
        let agent = HistoryAgent()
        await agent.serve(["finished.safetensors": Data("synthetic checkpoint".utf8)])
        workspace.agent = agent
        let groupID = try #require(try await workspace.prepareTrainingReport())
        workspace.runHistory = [TrainingRun(
            runID: "finished-run", trainer: "aitoolkit", datasetRepo: "", datasetRevision: nil,
            datasetContainsVideo: false,
            paramsJSON: JSONValue.object(["base_model": .string(workspace.baseModel)]).pythonDumpsData(),
            volumeID: "retained", startedAt: Date(), updatedAt: Date(), estimatedGPUCostUSD: 0.1,
            gpuBudgetUSD: 1, podSpendAtStart: 0
        )]
        workspace.attachTrainingReport(runID: "finished-run", groupID: groupID)
        let task = Task { await workspace.runTrainingReport("finished-run") }
        defer { task.cancel() }
        for _ in 0 ..< 100 where await agent.starts.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await agent.starts.contains { $0.service == "generate-aitoolkit" })
        workspace.saved?.accruedGPUCostUSD = 2
        for _ in 0 ..< 150 where workspace.hasRunningPod || workspace.isBusy {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(!workspace.isBusy, "Budget stop must unwind the report operation instead of awaiting itself.")
        await task.value
        #expect(!workspace.hasRunningPod)
        #expect(workspace.trainingReports[0].state == .failed)
        #expect(workspace.activeReportRunID == nil)
        #expect((workspace.runHistory[0].estimatedGPUCostUSD ?? 0) >= 2)
    }
}
