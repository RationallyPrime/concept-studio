// Fakes for the GPU workflow tests: a RunPod API and pod agent, a file downloader and a sleep
// assertion counter. Nothing here touches the network.

import ConceptCore
@testable import ConceptStudio
import CryptoKit
import Foundation
import Testing

actor GPUTransport: HTTPTransport {
    var requests: [URLRequest] = []
    let body: Data

    init(_ json: String = "{}") {
        body = Data(json.utf8)
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        return HTTPResponse(status: 200, body: body)
    }
}

func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// A fake RunPod API plus pod agent. `agentAvailable: false` makes the agent proxy answer 522.
actor UnreachableAgentTransport: HTTPTransport {
    private var stopped = false
    private var failedFirstStop: Bool
    private var agentAvailable: Bool
    private var unavailableStatus = 522
    private var eventsMissing = false
    private let inferenceReady: Bool
    private let gpuCount: Int
    private var services: [String: String] = [:]
    private var unavailableServices: Set<String> = []
    private var runIDs: [String: String] = [:]
    private var servedModel = ProviderChoices.defaultModel(for: "vllm")
    private var listedPods: [String] = []
    private var podRemovedOutside = false
    private var runFiles: [RunFile] = []
    private var filesFail = false
    private var listFails = false
    private var hubAccount: String?
    private var communityOffered = false
    private var history: [(Int, Double)] = []
    private(set) var stopCalls = 0
    private(set) var stoppedPods: [String] = []
    private(set) var inferenceRequests: [URLRequest] = []
    private(set) var starts: [URLRequest] = []
    private(set) var agentRequests: [URLRequest] = []
    /// The account's secret store: name → (id, value). Values are kept so tests can check what
    /// was written; the real API never returns them.
    private var secretStore: [String: (id: String, value: String)] = [:]
    private var secretCounter = 0
    private var createFails = false
    private(set) var secretRequests: [String] = []
    private(set) var deletedSecrets: [String] = []
    private(set) var createBodies: [JSONObject] = []

    init(failFirstStop: Bool = false, agentAvailable: Bool = false, inferenceReady: Bool = false, gpuCount: Int = 1) {
        failedFirstStop = !failFirstStop
        self.agentAvailable = agentAvailable
        self.inferenceReady = inferenceReady
        self.gpuCount = gpuCount
    }

    /// RunPod no longer has the pod: someone removed it in the console or with another tool.
    func removePodOutside() {
        podRemovedOutside = true
    }

    func list(_ pods: [String]) {
        listedPods = pods
    }

    func files(_ files: [RunFile]) {
        runFiles = files
    }

    func failFiles(_ fail: Bool) {
        filesFail = fail
    }

    func unavailable(_ names: Set<String>) {
        unavailableServices = names
    }

    func agentReachable(_ available: Bool) {
        agentAvailable = available
    }

    func agentRefuses(_ status: Int) {
        agentAvailable = false
        unavailableStatus = status
    }

    /// The agent answers a run's events with 404, as it does before the trainer creates the run directory.
    func runEventsMissing(_ missing: Bool) {
        eventsMissing = missing
    }

    func failList(_ fail: Bool) {
        listFails = fail
    }

    /// The account `GET huggingface.co/api/whoami-v2` reports; nil answers 401.
    func signIn(_ account: String?) {
        hubAccount = account
    }

    /// The catalog lists its GPU in Community Cloud as well as Secure Cloud.
    func offerCommunityCloud() {
        communityOffered = true
    }

    func curve(_ points: [(Int, Double)]) {
        history = points
    }

    func finish(_ service: String, state: String) {
        services[service] = state
    }

    func seedSecret(_ name: String, value: String) {
        secretCounter += 1
        secretStore[name] = ("sec-\(secretCounter)", value)
    }

    func secretValue(_ name: String) -> String? {
        secretStore[name]?.value
    }

    func failCreate(_ fail: Bool) {
        createFails = fail
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        let url = try #require(request.url)
        if url.host()?.contains("-8000.") == true {
            inferenceRequests.append(request)
            return HTTPResponse(
                status: inferenceReady ? 200 : 503,
                body: JSONValue.object(["data": .array([.object(["id": .string(servedModel)])])]).pythonDumpsData()
            )
        }
        if url.host() == "huggingface.co" {
            guard let hubAccount, request.value(forHTTPHeaderField: "Authorization") != nil else {
                return HTTPResponse(status: 401)
            }
            return HTTPResponse(status: 200, body: JSONValue.object(["name": .string(hubAccount)]).pythonDumpsData())
        }
        if url.host() != "api.runpod.io" {
            guard agentAvailable else { return HTTPResponse(status: unavailableStatus) }
            agentRequests.append(request)
            if eventsMissing, url.path().hasSuffix("/events") { return HTTPResponse(status: 404) }
            return try HTTPResponse(
                status: 200,
                body: JSONValue.object(agentReply(request, url: url)).pythonDumpsData()
            )
        }
        if url.path().contains("/v2/account/secrets") {
            return try secretsReply(request, url: url)
        }
        if url.path().hasSuffix("/v2/pods"), request.httpMethod == "POST" {
            let created = try JSONValue(parsing: #require(request.httpBody)).objectValue
            try createBodies.append(#require(created))
            if createFails { return HTTPResponse(status: 500) }
        }
        if url.path().hasSuffix("action") {
            let action = try JSONValue(parsing: #require(request.httpBody)).objectValue?["action"]?.stringValue
            if action == "start" {
                stopped = false
                return HTTPResponse(status: 200, body: Data(provider(request, url: url).utf8))
            }
            stopCalls += 1
            stoppedPods.append(url.deletingLastPathComponent().lastPathComponent)
            if !failedFirstStop {
                failedFirstStop = true
                return HTTPResponse(status: 503)
            }
            if url.deletingLastPathComponent().lastPathComponent == "test" { stopped = true }
        }
        if podRemovedOutside, url.path().contains("/v2/pods/"), request.httpMethod == "GET" {
            return HTTPResponse(status: 404)
        }
        if listFails, url.path().hasSuffix("/v2/pods"), request.httpMethod != "POST" {
            return HTTPResponse(status: 500)
        }
        return HTTPResponse(status: 200, body: Data(provider(request, url: url).utf8))
    }

    private func agentReply(_ request: URLRequest, url: URL) throws -> JSONObject {
        let path = url.path()
        if url.lastPathComponent == "start" {
            starts.append(request)
            let service = url.deletingLastPathComponent().lastPathComponent
            let params = try JSONValue(parsing: #require(request.httpBody)).objectValue?["params"]?.objectValue
            services[service] = ["pull-dataset", "push-lora"].contains(service) ? "exited" : "running"
            runIDs[service] = params?["run_id"]?.stringValue
            if service == "vllm" { servedModel = params?["model"]?.stringValue ?? servedModel }
        }
        if url.lastPathComponent == "stop" {
            services[url.deletingLastPathComponent().lastPathComponent] = "stopped"
        }
        if url.lastPathComponent == "plan" {
            return [
                "mode": .string(gpuCount == 1 ? "sequential" : "concurrent"),
                "caption": .object(["gpus": .array([.int(0)])]),
                "train": .object(["gpus": .array([.int(gpuCount == 1 ? 0 : 1)])]),
            ]
        }
        if url.lastPathComponent == "gpus", !path.contains("catalog") {
            return ["gpus": .array((0 ..< gpuCount).map { .object([
                "index": .int($0), "name": .string("Test GPU"), "memory_total_mib": .int(81920),
            ]) })]
        }
        if path.hasSuffix("/files") {
            if filesFail { throw StudioError.message("listing failed") }
            // The agent's shape (pod/agent artifacts.py): paths relative to the run's output/.
            return try ["files": JSONValue(parsing: JSONEncoder().encode(runFiles))]
        }
        if path.hasSuffix("/log") { return ["lines": .array([.string("step 1 loss 0.5")])] }
        if path.hasSuffix("/events") { return ["scalars": .object([:])] }
        if path.hasSuffix("scalars/tags") {
            let run = runIDs.values.first ?? "previous-run"
            return ["\(run)/tensorboard": .object(["scraped/loss": .object([:])])]
        }
        if path.hasSuffix("scalars/scalars") {
            throw StudioError.message("answered by scalarsReply")
        }
        return ["services": .array(GPUWorkspace.serviceTitles.keys.sorted().map { name in
            var service: JSONObject = [
                "name": .string(name), "state": .string(services[name] ?? "idle"),
                "available": .bool(!unavailableServices.contains(name)),
            ]
            if let run = runIDs[name] { service["run_id"] = .string(run) }
            return .object(service)
        })]
    }

    /// `GET/POST account/secrets` and `PATCH/DELETE account/secrets/{id}` as the v2 schema shapes them.
    private func secretsReply(_ request: URLRequest, url: URL) throws -> HTTPResponse {
        let method = request.httpMethod ?? "GET"
        let id = url.lastPathComponent == "secrets" ? nil : url.lastPathComponent
        let query = url.query().map { "?" + $0 } ?? ""
        secretRequests.append("\(method) \(url.path().replacingOccurrences(of: "/v2/", with: ""))\(query)")
        func metadata(_ name: String, id: String) -> HTTPResponse {
            let body: JSONObject = ["id": .string(id), "name": .string(name)]
            return HTTPResponse(status: 200, body: JSONValue.object(body).pythonDumpsData())
        }
        switch (method, id) {
        case ("GET", nil):
            let wanted = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first { $0.name == "name" }?.value?.lowercased()
            let entries: [JSONValue] = secretStore.sorted { $0.key < $1.key }
                .filter { wanted == nil || $0.key.lowercased() == wanted }
                .map { .object(["id": .string($0.value.id), "name": .string($0.key)]) }
            return HTTPResponse(status: 200, body: JSONValue.object(["secrets": .array(entries)]).pythonDumpsData())
        case ("POST", nil):
            let body = try JSONValue(parsing: #require(request.httpBody)).objectValue
            let name = try #require(body?["name"]?.stringValue)
            let value = try #require(body?["value"]?.stringValue)
            if secretStore[name] != nil { return HTTPResponse(status: 409) }
            seedSecret(name, value: value)
            let stored = try #require(secretStore[name])
            return metadata(name, id: stored.id)
        case let ("PATCH", id?):
            guard let name = secretStore.first(where: { $0.value.id == id })?.key else {
                return HTTPResponse(status: 404)
            }
            let patch = try JSONValue(parsing: #require(request.httpBody)).objectValue
            let value = try #require(patch?["value"]?.stringValue)
            secretStore[name] = (id, value)
            return metadata(name, id: id)
        case let ("DELETE", id?):
            guard let name = secretStore.first(where: { $0.value.id == id })?.key else {
                return HTTPResponse(status: 404)
            }
            secretStore[name] = nil
            deletedSecrets.append(name)
            return HTTPResponse(status: 204)
        default:
            return HTTPResponse(status: 405)
        }
    }

    private func provider(_ request: URLRequest, url: URL) -> String {
        if url.path().contains("catalog/gpus") {
            let community = communityOffered
                ? #""community":true,"price":{"secure":1,"community":0.5},"maxCount":{"secure":4,"community":4},"#
                : #""price":{"secure":1},"maxCount":{"secure":4},"#
            return #"{"gpus":[{"id":"test","name":"Test GPU","memory":80,"secure":true,"# + community
                + #""dataCenters":[{"id":"EU-IS-1","availability":"HIGH"}]}]}"#
        }
        if url.path().hasSuffix("network-volumes") {
            return #"{"networkVolumes":[{"id":"test","name":"Test","size":100,"dataCenter":"EU-IS-1"}]}"#
        }
        if url.path().hasSuffix("/v2/pods"), request.httpMethod != "POST" {
            return #"{"pods":["# + listedPods.joined(separator: ",")
                + #"],"pagination":{"nextCursor":null,"hasNextPage":false}}"#
        }
        return "{\"id\":\"test\",\"status\":\"\(stopped ? "EXITED" : "RUNNING")\",\"cost\":1,"
            + "\"gpu\":{\"count\":\(gpuCount)},\"name\":\"ConceptStudio-test\","
            + "\"mounts\":{\"network\":[{\"volumeId\":\"test\",\"path\":\"/workspace\"}]}}"
    }
}

/// The scalars route answers with a bare JSON array, which `agentReply` cannot return.
actor CurveTransport: HTTPTransport {
    let inner: UnreachableAgentTransport
    let rows: String

    init(_ inner: UnreachableAgentTransport, rows: String) {
        self.inner = inner
        self.rows = rows
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        if request.url?.path().hasSuffix("scalars/scalars") == true {
            return HTTPResponse(status: 200, body: Data(rows.utf8))
        }
        return try await inner.send(request)
    }
}

actor FakeDownloader: FileDownloading {
    private var contents: [String: Data]
    private(set) var requests: [URLRequest] = []

    init(_ contents: [String: Data]) {
        self.contents = contents
    }

    /// File bodies by last path component.
    func serve(_ contents: [String: Data]) {
        self.contents = contents
    }

    func download(_ request: URLRequest, to destination: URL) async throws -> Int {
        requests.append(request)
        guard let name = request.url?.lastPathComponent, let data = contents[name] else { return 404 }
        try data.write(to: destination)
        return 200
    }
}

@MainActor
final class SleepCounter {
    var begun = 0
    var ended = 0

    var assertion: SleepAssertion {
        SleepAssertion(begin: { self.begun += 1; return NSObject() }, end: { _ in self.ended += 1 })
    }
}

/// An aitoolkit model at FLUX.1-dev's 32 GB that downloads without a Hub token: a gated model cannot be
/// rented for or trained without one.
let ungatedModel = "Alpha-VLLM/Lumina-Image-2.0"

@MainActor
func makeWorkspace(
    _ transport: any HTTPTransport, _ preferences: UserDefaults,
    downloader: any FileDownloading = FakeDownloader([:]), sleep: SleepCounter = SleepCounter(),
    readAgentToken: @escaping (String) throws -> String? = { _ in nil },
    saveAgentToken: @escaping (String, String) throws -> Void = { _, _ in },
    deleteAgentToken: @escaping (String) throws -> Void = { _ in }
) -> GPUWorkspace {
    let workspace = GPUWorkspace(
        demoMode: false, transport: transport, preferences: preferences, readAgentToken: readAgentToken,
        saveAgentToken: saveAgentToken, deleteAgentToken: deleteAgentToken, downloader: downloader,
        uploader: RecordingUploader(), keepAwake: sleep.assertion
    )
    // These service fixtures test training lifecycle without a project captioner/class-image generation.
    workspace.regularizationOn = false
    return workspace
}

func temporaryPreferences() throws -> (UserDefaults, String) {
    let suite = "GPUWorkflowTests." + UUID().uuidString
    return try (#require(UserDefaults(suiteName: suite)), suite)
}

@MainActor
func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0 ..< 300 where !condition() {
        try await Task.sleep(for: .milliseconds(10))
    }
}

func trainerParams(_ transport: UnreachableAgentTransport, _ trainer: String) async throws -> JSONObject {
    let start = try #require(await transport.starts
        .first { $0.url?.path() == "/services/trainer-\(trainer)/start" })
    let body = try #require(start.httpBody)
    return try #require(JSONValue(parsing: body).objectValue?["params"]?.objectValue)
}
