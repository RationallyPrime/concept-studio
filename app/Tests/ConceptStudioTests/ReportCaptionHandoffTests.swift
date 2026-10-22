import ConceptCore
@testable import ConceptStudio
import Foundation
import Testing

private actor ReportHandoffTransport: HTTPTransport {
    let inner = UnreachableAgentTransport(agentAvailable: true, inferenceReady: true)
    var failingModel: String?
    var observeChoice: (@MainActor @Sendable () -> [String])?
    var onJudge: (@MainActor @Sendable () -> Void)?
    private(set) var starts: [String] = []
    private(set) var observedChoices: [[String]] = []

    func configure(
        failingModel: String? = nil, observeChoice: @escaping @MainActor @Sendable () -> [String],
        onJudge: (@MainActor @Sendable () -> Void)? = nil
    ) {
        self.failingModel = failingModel
        self.observeChoice = observeChoice
        self.onJudge = onJudge
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        if request.url?.path().hasSuffix("/services/vllm/start") == true {
            let body = try JSONValue(parsing: request.httpBody ?? Data())
            let model = body.objectValue?["params"]?.objectValue?["model"]?.stringValue ?? ""
            starts.append(model)
            if let observeChoice { await observedChoices.append(observeChoice()) }
            if model == failingModel { throw StudioError.message("Selected caption model could not restart.") }
        }
        if request.url?.path().hasSuffix("/chat/completions") == true {
            if let onJudge { await onJudge() }
            return HTTPResponse(status: 200, body: JSONValue.object([
                "model": .string("frozen/judge"), "choices": .array([.object([
                    "message": .object(["content": .string(#"{"score":0.8,"explanation":"Matched."}"#)]),
                ])]),
            ]).pythonDumpsData())
        }
        return try await inner.send(request)
    }
}

@Suite("Report caption-server handoff")
@MainActor
struct ReportCaptionHandoffTests {
    private func connected(
        project: StudioProject, preferences: UserDefaults, transport: ReportHandoffTransport,
        judge: String, mismatchedPrompt: Bool = false
    ) async throws -> GPUWorkspace {
        let workspace = makeWorkspace(transport, preferences)
        workspace.chooseTrainingModel("black-forest-labs/FLUX.1-dev")
        workspace.projectFolder = project.directory
        workspace.captionModel = "selected/caption-model"
        workspace.rentsCaptionServer = true
        try workspace.configure(runpodKey: "fixture", hubToken: "fixture", imageName: "fixture")
        await workspace.refreshOffers()
        await workspace.rent()
        workspace.monitorTask?.cancel()
        let prompt = ReportPrompt(
            id: "object", trigger: "OBJECT7", category: .object, kind: .concept,
            text: "OBJECT7 in a garden.", heldOutAttributes: []
        )
        let group = TrainingReportGroup(
            id: "frozen", name: "Frozen group", prompts: [prompt], seeds: [42],
            settings: ReportRenderSettings(
                trainer: workspace.trainer, baseModel: workspace.baseModel, resolution: 512,
                inferenceSteps: 20, guidanceScale: 4, frames: 1, frameRate: 24,
                judgeModel: judge, judgeExtraBodyJSON: Data("{}".utf8)
            ), captionDigest: "fixture", manualPrompts: false, frozenAt: Date(), createdAt: Date()
        )
        workspace.reportGroups = [group]
        workspace.trainingReports = [TrainingReport(runID: "finished-run", groupID: group.id)]
        workspace.runHistory = [TrainingRun(
            runID: "finished-run", trainer: workspace.trainer, datasetRepo: "", datasetRevision: nil,
            datasetContainsVideo: false, paramsJSON: JSONValue.object([
                "base_model": .string(workspace.baseModel),
            ]).pythonDumpsData(), volumeID: workspace.currentVolumeID, startedAt: Date(), updatedAt: Date(),
            estimatedGPUCostUSD: 0, gpuBudgetUSD: 10, podSpendAtStart: 0
        )]
        let folder = try workspace.resultsFolder(for: "saved-comparison")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let pixels = try MediaEditor.png(MediaFixtures.image(width: 20, height: 20))
        for name in ["base.png", "lora.png"] {
            try pixels.write(to: folder.appendingPathComponent(name))
        }
        let manifest: JSONObject = ["state": .string("complete"), "pairs": .array([.object([
            "prompt": .string(mismatchedPrompt ? "Wrong prompt" : prompt.text), "seed": .int(42),
            "base_path": .string("base.png"), "lora_path": .string("lora.png"),
        ])])]
        try JSONValue.object(manifest).pythonDumpsData().write(to: folder.appendingPathComponent("comparison.json"))
        workspace.generations = [GeneratedComparison(
            runID: "saved-comparison", sourceRunID: "finished-run", checkpoint: "model.safetensors",
            trainer: workspace.trainer, volumeID: workspace.currentVolumeID, startedAt: Date(), state: .saved,
            folder: folder.path, reportGroupID: group.id, reportPromptIDs: [prompt.id], paramsJSON: Data("{}".utf8)
        )]
        return workspace
    }

    @Test(arguments: [false, true], [false, true])
    func finishedReportRestoresTheCurrentChoiceWithoutPersistingItsJudge(
        sameModel: Bool, changedDuringReport: Bool
    ) async throws {
        let project = try await makeDemoProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        let preferences = IsolatedDefaults()
        defer { preferences.remove() }
        let transport = ReportHandoffTransport()
        let judge = sameModel ? "selected/caption-model" : "frozen/judge"
        let workspace = try await connected(
            project: project, preferences: preferences.defaults, transport: transport, judge: judge
        )
        await transport.configure(observeChoice: {
            [workspace.captionModel, preferences.defaults.string(forKey: GPUWorkspace.captionModelKey) ?? ""]
        }, onJudge: {
            if changedDuringReport { workspace.captionModel = "new/current-choice" }
        })
        await workspace.runTrainingReport("finished-run")
        let selected = changedDuringReport ? "new/current-choice" : "selected/caption-model"
        #expect(workspace.trainingReports[0].state == .complete)
        #expect(workspace.trainingReports[0].samples[0].adherence?.lora == 0.8)
        #expect(workspace.captionModel == selected)
        #expect(preferences.defaults.string(forKey: GPUWorkspace.captionModelKey) == selected)
        #expect(await transport.starts == (judge == selected ? [judge] : [judge, selected]))
        #expect(await transport.observedChoices.first == ["selected/caption-model", "selected/caption-model"])
        let request = try URLRequest(url: #require(workspace.captionEndpoint).appendingPathComponent("models"))
        let response = try await transport.send(request)
        #expect(try JSONValue(parsing: response.body).objectValue?["data"]?.arrayValue?.first?
            .objectValue?["id"]?.stringValue == selected)
        #expect(workspace.activeReportRunID == nil && workspace.appWorkInFlight == 0)
        await workspace.stopEverything()
    }

    @Test(arguments: [false, true])
    func failedReportOrRestoreKeepsOutputsAndTheSelectedModel(restoreFails: Bool) async throws {
        let project = try await makeDemoProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        let preferences = IsolatedDefaults()
        defer { preferences.remove() }
        let transport = ReportHandoffTransport()
        let workspace = try await connected(
            project: project, preferences: preferences.defaults, transport: transport,
            judge: "frozen/judge", mismatchedPrompt: !restoreFails
        )
        await transport.configure(
            failingModel: restoreFails ? "selected/caption-model" : nil,
            observeChoice: { [workspace.captionModel] }
        )
        await workspace.runTrainingReport("finished-run")
        #expect(workspace.trainingReports[0].state == .failed)
        #expect(workspace.captionModel == "selected/caption-model")
        #expect(await transport.starts == ["frozen/judge", "selected/caption-model"])
        #expect(workspace.captionServerActive == !restoreFails)
        #expect(workspace.comparisonFile("lora.png", in: workspace.generations[0]) != nil)
        #expect(workspace.activeReportRunID == nil && workspace.appWorkInFlight == 0)
        if restoreFails { #expect(workspace.trainingReports[0].samples.count == 1) }
        await workspace.stopEverything()
    }

    @Test(arguments: [false, true])
    func cancelledOrExhaustedHandoffNeverStartsAnotherModel(cancelled: Bool) async throws {
        let project = try await makeDemoProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        let preferences = IsolatedDefaults()
        defer { preferences.remove() }
        let transport = ReportHandoffTransport()
        let workspace = try await connected(
            project: project, preferences: preferences.defaults, transport: transport, judge: "frozen/judge"
        )
        let agent = try #require(workspace.agent)
        if !cancelled { workspace.runHistory[0].gpuBudgetUSD = 0 }
        let task = Task {
            try await workspace.reconcileReportCaptionServer(
                group: workspace.reportGroups[0], run: workspace.runHistory[0], agent: agent
            )
        }
        if cancelled { task.cancel() }
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(await transport.starts.isEmpty)
        #expect(workspace.captionServerActive == false)
        #expect(workspace.captionModel == "selected/caption-model")
        await workspace.stopEverything()
    }
}
