import ConceptCore
@testable import ConceptStudio
import Foundation
import Testing

actor StorageTransport: HTTPTransport {
    private(set) var requests: [URLRequest] = []
    private var cleaned = false
    func send(_ request: URLRequest) throws -> HTTPResponse {
        requests.append(request)
        let path = request.url?.path() ?? ""
        if path.hasSuffix("/start") {
            cleaned = true
            return HTTPResponse(status: 201, body: Data("{}".utf8))
        }
        if path.hasSuffix("/services") {
            return HTTPResponse(status: 200, body: Data(
                #"{"services":[{"name":"cleanup-datasets","state":"exited","group_alive":false}]}"#.utf8
            ))
        }
        return HTTPResponse(status: 200, body: JSONValue.object([
            "total_bytes": .int(1000), "used_bytes": .int(cleaned ? 200 : 400),
            "free_bytes": .int(cleaned ? 800 : 600), "datasets_bytes": .int(cleaned ? 100 : 300),
            "reclaimable_dataset_bytes": .int(cleaned ? 0 : 200),
        ]).pythonDumpsData())
    }
}

@Suite("GPU storage usage and completed dataset cleanup")
struct GPUStorageTests {
    @MainActor @Test
    func typedAuthenticatedUsageAndCleanupUseCPUServiceOnly() async throws {
        let (preferences, suite) = try temporaryPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let transport = StorageTransport()
        let workspace = makeWorkspace(transport, preferences)
        workspace.pod = RentedPod(id: "offline", status: "RUNNING", cost: 1, gpu: .init(count: 1))
        workspace.agent = try PodAgentClient(
            baseURL: #require(URL(string: "https://offline-8800.proxy.runpod.net")), token: "synthetic",
            transport: transport
        )
        await workspace.refreshStorage()
        #expect(workspace.storage?.reclaimableDatasetBytes == 200)
        await workspace.cleanupDatasets()
        #expect(workspace.storage?.freeBytes == 800)
        #expect(workspace.storage?.reclaimableDatasetBytes == 0)
        let requests = await transport.requests
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic" })
        let starts = requests.filter { $0.httpMethod == "POST" }
        #expect(starts.count == 1)
        let start = try #require(starts.first)
        #expect(start.url?.path() == "/services/cleanup-datasets/start")
        let data = try #require(start.httpBody)
        let body = try JSONValue(parsing: data).objectValue
        #expect(body?["gpus"] == .array([]))
        #expect(body?["params"] == .object([:]))
        #expect(workspace.message.contains("Models") || workspace.message.contains("models"))
    }

    @MainActor @Test
    func keptStorageShowsDailyCostFromSavedVolumeTierAndSize() {
        let workspace = GPUWorkspace(demoMode: true)
        var saved = SavedPod(
            pod: .init(id: "kept", status: "EXITED", cost: 0, gpu: .init(count: 1)),
            started: Date(),
            hourlyRate: 1,
            budget: 10,
            trainer: "aitoolkit",
            runID: "",
            volumeID: "network-volume"
        )
        saved.networkVolume = GPUVolume(
            id: "network-volume",
            name: "Cache",
            size: 300,
            dataCenter: "EU-RO-1",
            type: "STANDARD"
        )
        #expect(workspace.keptStorageCost(saved).contains("$0.70/day"))
        saved.networkVolume?.type = "HIGH_PERFORMANCE"
        #expect(workspace.keptStorageCost(saved).contains("$1.40/day"))
        saved.networkVolume = nil
        #expect(workspace.keptStorageCost(saved).contains("unavailable"))
    }

    @MainActor @Test
    func noConnectionDoesNotAttemptCleanup() async throws {
        let (preferences, suite) = try temporaryPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let transport = StorageTransport()
        let workspace = makeWorkspace(transport, preferences)
        await workspace.cleanupDatasets()
        #expect(await transport.requests.isEmpty)
        #expect(workspace.message.contains("Connect"))
    }
}
