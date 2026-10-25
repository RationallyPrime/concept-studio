import ConceptCore
@testable import ConceptStudio
import Foundation
import Testing

/// No account or GPU calls: records the native agent contract and supplies synthetic file bytes.
actor HistoryAgent: PodAgent {
    struct Start { let service: String; let gpus: [Int]; let params: JSONObject }
    private(set) var starts: [Start] = []
    private(set) var listedRunIDs: [String] = []
    private(set) var downloadedRunIDs: [String] = []
    private(set) var uploads: [String: Data] = [:]
    var files: [RunFile] = []
    var bodies: [String: Data] = [:]
    var logBodies: [String: Data] = [:]
    var damageDownloads = false
    var loseStartReply = false
    private var unavailableServices: Set<String> = []
    private var hubTokenSupport: Bool? = true

    func reportHubTokenSupport(_ supported: Bool?) {
        hubTokenSupport = supported
    }

    func unavailable(_ names: Set<String>) {
        unavailableServices = names
    }

    private var pauseProgress = false
    private var progressWaiter: CheckedContinuation<Void, Never>?
    private var progressRelease: CheckedContinuation<Void, Never>?
    private var pausePlan = false
    private var planWaiter: CheckedContinuation<Void, Never>?
    private var planRelease: CheckedContinuation<Void, Never>?

    func pauseNextPlanRead() {
        pausePlan = true
    }

    func waitForPausedPlanRead() async {
        if planRelease != nil { return }
        await withCheckedContinuation { planWaiter = $0 }
    }

    func releasePlanRead() {
        planRelease?.resume()
        planRelease = nil
    }

    func pauseNextProgressRead() {
        pauseProgress = true
    }

    func waitForPausedProgressRead() async {
        if progressRelease != nil { return }
        await withCheckedContinuation { progressWaiter = $0 }
    }

    func releaseProgressRead() {
        progressRelease?.resume()
        progressRelease = nil
    }

    func loseStartAcknowledgements() {
        loseStartReply = true
    }

    func gpus() -> [AgentGPU] {
        (0 ... 1).map { .init(index: $0, name: "Synthetic 80 GB GPU", memoryTotalMiB: 81920) }
    }

    func upload(name: String, fileName: String, from file: URL, size: Int64) throws {
        let data = try Data(contentsOf: file)
        guard data.count == size else { throw StudioError.message("Synthetic upload changed") }
        uploads[fileName] = data
    }

    func plan() async -> TrainingPlan {
        if pausePlan {
            pausePlan = false
            await withCheckedContinuation { continuation in
                planRelease = continuation
                planWaiter?.resume()
                planWaiter = nil
            }
        }
        return TrainingPlan(mode: "concurrent", caption: .init(gpus: [0]), train: .init(gpus: [1]))
    }

    func services() -> [AgentService] {
        GPUWorkspace.serviceTitles.keys.sorted().map { name in
            let start = starts.last { $0.service == name }
            return AgentService(
                name: name,
                state: start == nil ? "idle" : (["pull-dataset", "push-lora"].contains(name) ? "exited" : "running"),
                groupAlive: false,
                runID: start?.params["run_id"]?.stringValue,
                available: !unavailableServices.contains(name), supportsHFToken: hubTokenSupport
            )
        }
    }

    func start(_ service: String, gpus: [Int], params: JSONObject) throws {
        starts.append(Start(service: service, gpus: gpus, params: params))
        if loseStartReply, service.hasPrefix("trainer-") || service.hasPrefix("generate-") {
            throw StudioError.message("Synthetic lost start acknowledgement")
        }
    }

    func stop(_ service: String) {}
    func runLog(runID: String) -> String {
        "Synthetic offline log"
    }

    func latest(runID: String) async -> TrainingPoint? {
        if pauseProgress {
            pauseProgress = false
            await withCheckedContinuation { continuation in
                progressRelease = continuation
                progressWaiter?.resume()
                progressWaiter = nil
            }
        }
        return nil
    }

    func history(runID: String) -> [TrainingPoint] {
        []
    }

    func runFiles(runID: String) -> [RunFile] {
        listedRunIDs.append(runID)
        return files
    }

    func runConfiguration(runID: String) -> AgentRunConfiguration {
        AgentRunConfiguration(config: [:], dataset: ["revision": .string("resolved-revision")])
    }

    func serve(_ bodies: [String: Data], damaged: Bool = false) {
        self.bodies = bodies
        damageDownloads = damaged
        files = bodies.map { RunFile(path: $0.key, size: $0.value.count, sha256: sha256($0.value)) }
    }

    func download(runID: String, path: String, to destination: URL) throws {
        downloadedRunIDs.append(runID)
        try (damageDownloads ? Data("damaged".utf8) : bodies[path] ?? Data()).write(to: destination)
    }

    func serveLogs(_ bodies: [String: Data]) {
        logBodies = bodies
    }

    func runLogFiles(runID: String) -> [RunFile] {
        logBodies.map { RunFile(path: $0.key, size: $0.value.count, sha256: sha256($0.value)) }
    }

    func downloadLogFile(runID: String, path: String, to destination: URL) throws {
        try (logBodies[path] ?? Data()).write(to: destination)
    }
}
