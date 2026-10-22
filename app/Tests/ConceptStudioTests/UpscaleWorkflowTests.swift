import ConceptCore
@testable import ConceptStudio
import Foundation
import Testing

/// A cloud GPU that upscales the first upload and reports the second as failed, as `upscale_media.py` logs it.
actor UpscaleAgent: PodAgent {
    private(set) var uploads: [(stage: String, name: String)] = []
    private(set) var starts: [HistoryAgent.Start] = []
    let result = Data("upscaled bytes".utf8)

    func upload(name: String, fileName: String, from file: URL, size: Int64) async throws {
        uploads.append((name, fileName))
    }

    func plan() -> TrainingPlan {
        TrainingPlan(mode: "sequential", caption: .init(gpus: [0]), train: .init(gpus: [0]))
    }

    func services() -> [AgentService] {
        starts.map { AgentService(name: $0.service, state: "exited", groupAlive: false, runID: nil) }
    }

    func start(_ service: String, gpus: [Int], params: JSONObject) {
        starts.append(.init(service: service, gpus: gpus, params: params))
    }

    func stop(_ service: String) {}
    func runLog(runID: String) -> String {
        "[upscale] ready 1/2\n[upscale] failed u0002.jpg: SeedVR2 wrote no result\n[upscale] ready 1/2"
    }

    func latest(runID: String) -> TrainingPoint? {
        nil
    }

    func history(runID: String) -> [TrainingPoint] {
        []
    }

    func runFiles(runID: String) -> [RunFile] {
        [RunFile(path: "u0001.png", size: result.count, sha256: sha256(result), modifiedAt: Date())]
    }

    func download(runID: String, path: String, to destination: URL) throws {
        try result.write(to: destination)
    }
}

@Suite("SeedVR2 upscaling")
struct UpscaleWorkflowTests {
    /// A pending result for the project's first image, written where a finished upscale leaves it.
    private func pendingResult(in project: StudioProject, for id: String) throws -> PendingUpscale {
        let pending = PendingUpscale(
            sourceID: id, resultPath: "upscaled/run/u0001.png", model: .standard, shortSide: 1024, created: Date()
        )
        let url = pending.resultURL(in: project.directory)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("upscaled".utf8).write(to: url)
        return pending
    }

    @Test func keptResultReplacesTheSampleAndTheOriginalComesBackAfterReopening() async throws {
        var project = try await makeDemoProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        project.job = try Job(concepts: [Concept(trigger: "NORA7", targetConcept: .fullIdentity)])
        let original = try #require(project.images.first)
        let originalBytes = try Data(contentsOf: original.url)
        try AtomicFile.write(
            text: "NORA7 sits on a bench.",
            to: original.url.deletingPathExtension()
                .appendingPathExtension("txt")
        )
        try project.job.setMapping(["NORA7": "the woman on the bench"], for: original.id)
        let pending = try pendingResult(in: project, for: original.id)
        project.mediaState.pendingUpscales = [pending]

        try project.keepUpscale(pending)
        let kept = Sources.stem(of: original.id) + ".png"
        #expect(project.images.contains { $0.id == kept } && !project.images.contains { $0.id == original.id })
        #expect(try Data(contentsOf: project.imagesDirectory.appendingPathComponent(kept)) == Data("upscaled".utf8))
        #expect(project.job.mapping(for: kept)?["NORA7"] == "the woman on the bench")
        #expect(project.mediaState.pendingUpscales.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: pending.resultURL(in: project.directory).path))

        var reopened = try await StudioProject.open(at: project.directory)
        #expect(reopened.mediaState.upscaled[kept]?.originalID == original.id)
        try reopened.revertUpscale(kept)
        let restored = try #require(reopened.images.first { $0.id == original.id })
        #expect(try Data(contentsOf: restored.url) == originalBytes)
        #expect(restored.caption == "NORA7 sits on a bench.")
        #expect(!reopened.images.contains { $0.id == kept })
        #expect(reopened.job.mapping(for: original.id)?["NORA7"] == "the woman on the bench")
        #expect(try await StudioProject.open(at: project.directory).mediaState.upscaled.isEmpty)
    }

    @Test func discardLeavesTheOriginalAlone() async throws {
        var project = try await makeDemoProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        let original = try #require(project.images.first)
        let pending = try pendingResult(in: project, for: original.id)
        project.mediaState.pendingUpscales = [pending]
        try project.discardUpscale(original.id)
        #expect(project.images.contains { $0.id == original.id })
        #expect(try await StudioProject.open(at: project.directory).mediaState.pendingUpscales.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: pending.resultURL(in: project.directory).path))
    }

    @Test func aResultNeverTakesTheNameOfAnExcludedSample() async throws {
        let project = try await makeDemoProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        let jpg = try #require(project.images.map(\.id).first { $0.hasSuffix(".jpg") })
        let png = Sources.stem(of: jpg) + ".png"
        #expect(project.upscaledName(for: jpg, resultExtension: "png") == png)
        try FileManager.default.createDirectory(at: project.excludedDirectory, withIntermediateDirectories: true)
        try Data("other".utf8).write(to: project.excludedDirectory.appendingPathComponent(png))
        let reopened = try await StudioProject.open(at: project.directory)
        #expect(reopened.upscaledName(for: jpg, resultExtension: "png") == Sources.stem(of: jpg) + "-upscaled.png")
    }

    @MainActor @Test func cloudGPUUpscaleSendsTheTargetSizeAndReturnsCheckedResults() async throws {
        let (preferences, suite) = try temporaryPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let workspace = makeWorkspace(GPUTransport(), preferences)
        let agent = UpscaleAgent()
        workspace.pod = RentedPod(id: "offline", status: "RUNNING", cost: 0.69, gpu: .init(count: 1))
        workspace.agent = agent
        let folder = temporaryTestDirectory("upscale")
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("inputs")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let inputs = try ["first.webp", "second.jpg"].map { name in
            let url = source.appendingPathComponent(name)
            try Data(name.utf8).write(to: url)
            return UpscaleInput(sampleID: name, file: url)
        }
        let outcome = try await workspace.upscale(
            inputs, model: .large, target: UpscaleTarget(shortSide: 768), into: folder.appendingPathComponent("out")
        ) { _ in }

        let uploads = await agent.uploads
        #expect(uploads.map(\.name) == ["u0001.webp", "u0002.jpg"])
        let start = try #require(await agent.starts.first)
        #expect(start.service == "upscale-media" && start.gpus == [0])
        #expect(start.params["upload"]?.stringValue == uploads.first?.stage)
        #expect(start.params["model"]?.stringValue == "7b")
        #expect(start.params["resolution"]?.intValue == 768 && start.params["max_resolution"]?.intValue == 1536)
        let result = try #require(outcome.results["first.webp"])
        #expect(try Data(contentsOf: result) == Data("upscaled bytes".utf8))
        #expect(outcome.failures == ["second.jpg": "SeedVR2 wrote no result"])
        #expect(!workspace.isBusy)
        #expect(await UpscaleProgress.parse(log: agent.runLog(runID: "x"))?.text
            == "Upscaling on the cloud GPU: 1 of 2 ready")
    }

    @MainActor @Test func upscalingWaitsForARunningCloudGPUThatIsNotTraining() throws {
        let (preferences, suite) = try temporaryPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let workspace = makeWorkspace(GPUTransport(), preferences)
        #expect(workspace.upscaleUnavailableReason?.contains("Rent one") == true)
        workspace.pod = RentedPod(id: "offline", status: "RUNNING", cost: 0, gpu: .init(count: 1))
        workspace.agent = UpscaleAgent()
        #expect(workspace.upscaleUnavailableReason == nil)
        workspace.trainingState = "running"
        #expect(workspace.upscaleUnavailableReason?.contains("training") == true)
    }

    @Test func belowTargetUsesTheShortSide() {
        let target = UpscaleTarget(shortSide: 1024)
        #expect(target.isBelow(ImageAnalysis(width: 1920, height: 1000)))
        #expect(!target.isBelow(ImageAnalysis(width: 1024, height: 1400)))
        #expect(!target.isBelow(ImageAnalysis()))
        #expect(!target.isBelow(nil))
    }
}
