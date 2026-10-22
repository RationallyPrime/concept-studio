import ConceptCore
@testable import ConceptStudio
import Foundation
import Testing

/// Answers the GPU catalog per cloud, as RunPod does: price and count for both clouds, stock for the
/// cloud asked about. Everything else goes to the workflow fixture.
private actor CloudCatalogTransport: HTTPTransport {
    let inner = UnreachableAgentTransport()
    let communityFails: Bool
    private(set) var catalogClouds: [String] = []

    init(communityFails: Bool = false) {
        self.communityFails = communityFails
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        guard let url = request.url, url.path().contains("catalog/gpus") else { return try await inner.send(request) }
        let cloud = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "cloud" }?.value ?? ""
        catalogClouds.append(cloud)
        if communityFails, cloud == "COMMUNITY" { return HTTPResponse(status: 500, body: Data("{}".utf8)) }
        let stock = cloud == "COMMUNITY" ? #"[{"id":"US-TX-9","availability":"HIGH"}]"#
            : #"[{"id":"EU-IS-1","availability":"LOW"}]"#
        let body = #"{"gpus":[{"id":"NVIDIA RTX 5090","name":"RTX 5090","memory":96,"secure":true,"#
            + #""community":true,"price":{"secure":0.89,"community":0.69},"maxCount":{"secure":8,"community":4},"#
            + #""dataCenters":\#(stock)},"#
            + #"{"id":"NVIDIA H100","name":"H100","memory":96,"secure":false,"community":true,"#
            + #""price":{"community":1.5},"maxCount":{"community":2},"dataCenters":\#(stock)}]}"#
        return HTTPResponse(status: 200, body: Data(body.utf8))
    }
}

@Suite("Cloud GPU list")
struct GPUOfferListTests {
    @MainActor @Test func communityRowsCarryTheirOwnPriceAndStockAndRentOnCommunityCloud() async throws {
        let (preferences, suite) = try temporaryPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let transport = CloudCatalogTransport()
        let workspace = makeWorkspace(transport, preferences)
        try workspace.configure(runpodKey: "fixture", hubToken: "", imageName: "")
        workspace.chooseTrainingModel(ungatedModel) // ungated, so Community Cloud stays open
        await workspace.refreshOffers()
        #expect(await Set(transport.catalogClouds) == ["SECURE", "COMMUNITY"])
        workspace.chooseStorage("")
        #expect(workspace.gpuChoices.map(\.id) == ["SECURE/NVIDIA RTX 5090"])

        workspace.includeCommunityCloud = true
        let choices = Dictionary(uniqueKeysWithValues: workspace.gpuChoices.map { ($0.id, $0) })
        #expect(Set(choices.keys) == ["SECURE/NVIDIA RTX 5090", "COMMUNITY/NVIDIA RTX 5090", "COMMUNITY/NVIDIA H100"])
        #expect(choices["SECURE/NVIDIA RTX 5090"]?.stock == .low)
        #expect(choices["COMMUNITY/NVIDIA RTX 5090"]?.stock == .high)

        workspace.selectedGPU = "COMMUNITY/NVIDIA RTX 5090"
        #expect(workspace.quotedHourlyRate == 0.69)
        await workspace.rent()
        workspace.monitorTask?.cancel()
        let body = try #require(await transport.inner.createBodies.first)
        #expect(body["cloud"]?.stringValue == "COMMUNITY")
        #expect(body["gpu"]?.objectValue?["id"]?.stringValue == "NVIDIA RTX 5090")
        await workspace.stopEverything()
    }

    @MainActor @Test func unavailableGPUsStayListedWithTheirReason() {
        let workspace = GPUWorkspace(demoMode: true)
        let needed = workspace.requiredGPUMemoryGB
        workspace.gpuCount = 2
        workspace.offers = [
            offer("fits", memory: needed),
            offer("small", memory: needed - 1),
            offer("sold-out", memory: needed, stock: "NONE"),
            offer("single", memory: needed, maxCount: 1),
        ]
        let reasons = Dictionary(uniqueKeysWithValues: workspace.gpuChoices.map { ($0.offer.gpuID, $0.unavailability) })
        #expect(reasons["fits"] == .some(nil))
        #expect(reasons["small"] == .notEnoughMemory(model: workspace.effectiveModelRow.shortName))
        #expect(reasons["sold-out"] == GPUUnavailability.noStock)
        #expect(reasons["single"] == .notOffered(count: 2))
        #expect(workspace.availableOffers.map(\.gpuID) == ["fits"])

        workspace.inStockOnly = true
        #expect(workspace.gpuChoices.map(\.offer.gpuID) == ["fits", "small", "single"])
        workspace.minimumMemoryFilter = needed
        #expect(workspace.gpuChoices.map(\.offer.gpuID) == ["fits", "single"])
    }

    @MainActor @Test func captioningUsesCaptionModelMemoryInsteadOfTrainingModel() {
        let preferences = IsolatedDefaults()
        defer { preferences.remove() }
        let workspace = GPUWorkspace(demoMode: true, preferences: preferences.defaults)
        workspace.offers = [
            offer("too-small", memory: 24), offer("caption-gpu", memory: 32), offer("training-gpu", memory: 80),
        ]
        workspace.rentsCaptionServer = true
        #expect(workspace.captionModel == ProviderChoices.defaultSelfHostedModel)
        #expect(workspace.requiredGPUMemoryGB == 32)
        #expect(workspace.availableOffers.map(\.gpuID) == ["caption-gpu", "training-gpu"])
        #expect(workspace.gpuChoices.first { $0.offer.gpuID == "too-small" }?.unavailability ==
            .notEnoughMemory(model: ProviderChoices.defaultSelfHostedModel))
        workspace.captionMemoryGB = 48
        #expect(workspace.availableOffers.map(\.gpuID) == ["training-gpu"])
    }

    @MainActor @Test func savedStorageNeedsSecureCloudStockInItsDataCentre() {
        let workspace = GPUWorkspace(demoMode: true)
        workspace.chooseTrainingModel(ungatedModel) // ungated, so Community Cloud stays open
        let needed = workspace.requiredGPUMemoryGB
        workspace.volumes = [.init(id: "ro", name: "Dataset", size: 300, dataCenter: "EU-RO-1")]
        workspace.selectedVolume = "ro"
        workspace.includeCommunityCloud = true
        workspace.offers = [
            offer("beside", memory: needed, dataCenter: "EU-RO-1"),
            offer("elsewhere", memory: needed, dataCenter: "CA-MTL-3"),
            offer("beside", memory: needed, cloud: .community, dataCenter: "EU-RO-1"),
        ]
        let reasons = Dictionary(uniqueKeysWithValues: workspace.gpuChoices.map { ($0.id, $0.unavailability) })
        #expect(reasons["SECURE/beside"] == .some(nil))
        #expect(reasons["SECURE/elsewhere"] == .noStockBesideStorage(dataCenter: "EU-RO-1"))
        #expect(reasons["COMMUNITY/beside"] == .savedStorageIsSecureOnly)

        workspace.chooseStorage("")
        #expect(workspace.availableOffers.map(\.id) == ["SECURE/beside", "SECURE/elsewhere", "COMMUNITY/beside"])
        workspace.selectedGPU = "COMMUNITY/beside"
        workspace.includeCommunityCloud = false
        #expect(workspace.selectedGPU == "SECURE/beside")
    }

    @MainActor @Test func aFailedCommunityCatalogLeavesTheSecureCloudOffers() async throws {
        let (preferences, suite) = try temporaryPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let workspace = makeWorkspace(CloudCatalogTransport(communityFails: true), preferences)
        try workspace.configure(runpodKey: "fixture", hubToken: "", imageName: "")
        workspace.chooseTrainingModel(ungatedModel)
        workspace.includeCommunityCloud = true
        await workspace.refreshOffers()
        workspace.chooseStorage("")
        #expect(workspace.availableOffers.map(\.id) == ["SECURE/NVIDIA RTX 5090"])
    }

    @MainActor @Test func aGatedModelGreysOutCommunityCloudUnlessTheRentalIsForCaptioning() throws {
        let workspace = GPUWorkspace(demoMode: true)
        workspace.includeCommunityCloud = true
        workspace.chooseTrainingModel("black-forest-labs/FLUX.1-dev")
        let needed = workspace.requiredGPUMemoryGB
        workspace.offers = [offer("gpu", memory: needed), offer("gpu", memory: needed, cloud: .community)]
        #expect(workspace.availableOffers.map(\.id) == ["SECURE/gpu"])
        let model = try #require(workspace.exactModelRow).shortName
        #expect(workspace.gpuChoices.last?.unavailability == .gatedModelNeedsHubToken(model: model))

        workspace.rentsCaptionServer = true
        #expect(workspace.availableOffers.map(\.id) == ["SECURE/gpu", "COMMUNITY/gpu"])
    }

    @MainActor @Test func withoutAHubTokenAGatedModelGreysOutEveryCloudGPUUnlessTheRentalIsForCaptioning() throws {
        let (preferences, suite) = try temporaryPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let workspace = makeWorkspace(UnreachableAgentTransport(), preferences)
        workspace.includeCommunityCloud = true
        workspace.chooseTrainingModel("black-forest-labs/FLUX.1-dev")
        let needed = workspace.requiredGPUMemoryGB
        workspace.offers = [offer("gpu", memory: needed), offer("gpu", memory: needed, cloud: .community)]
        let model = try #require(workspace.exactModelRow).shortName
        #expect(workspace.availableOffers.isEmpty)
        #expect(workspace.gpuChoices.map(\.unavailability) == Array(
            repeating: .gatedModelNeedsHubTokenInSettings(model: model), count: 2
        ))

        workspace.rentsCaptionServer = true
        #expect(workspace.availableOffers.map(\.id) == ["SECURE/gpu", "COMMUNITY/gpu"])
        workspace.rentsCaptionServer = false
        workspace.hubToken = "hub-read"
        #expect(workspace.availableOffers.map(\.id) == ["SECURE/gpu"])
    }

    @MainActor @Test func listSortsByTheChosenColumnWithChoosableGPUsFirst() {
        let workspace = GPUWorkspace(demoMode: true)
        let needed = workspace.requiredGPUMemoryGB
        workspace.offers = [
            offer("cheap-small", memory: needed - 1, price: 0.2),
            offer("mid", memory: needed + 40, price: 1.5, stock: "LOW"),
            offer("pricey", memory: needed + 80, price: 3, stock: "MEDIUM"),
            offer("cheap", memory: needed, price: 0.5),
        ]
        let byPrice = workspace.gpuChoices(sortedBy: [KeyPathComparator(\.hourlyPrice)])
        #expect(byPrice.map(\.offer.gpuID) == ["cheap", "mid", "pricey", "cheap-small"])
        let byMemory = workspace.gpuChoices(sortedBy: [KeyPathComparator(\.memory, order: .reverse)])
        #expect(byMemory.map(\.offer.gpuID) == ["pricey", "mid", "cheap", "cheap-small"])
        let byStock = workspace.gpuChoices(sortedBy: [KeyPathComparator(\.stock)])
        #expect(byStock.map(\.offer.gpuID) == ["cheap", "pricey", "mid", "cheap-small"])
    }

    @Test func savedStorageIsRefusedOnCommunityCloudBeforeAnyRequest() async throws {
        let transport = GPUTransport()
        let provider = RunPodProvider(key: "fixture", transport: transport)
        await #expect(throws: (any Error).self) {
            _ = try await provider.create(PodCreation(
                name: "ConceptStudio-fixture",
                offer: offer("gpu", memory: 96, cloud: .community, dataCenter: "EU-RO-1"), count: 1,
                image: "fixture/image", minCudaVersion: "13.0",
                volume: GPUVolume(id: "ro", name: "Dataset", size: 100, dataCenter: "EU-RO-1"), env: [:]
            ))
        }
        #expect(await transport.requests.isEmpty)
    }

    private func offer(
        _ id: String, memory: Int, price: Double = 1, maxCount: Int = 4, cloud: GPUCloud = .secure,
        dataCenter: String = "demo", stock: String = "HIGH"
    ) -> GPUOffer {
        GPUOffer(
            gpuID: id, cloud: cloud, name: id, memory: memory, price: price, maxCount: maxCount,
            dataCenters: [.init(id: dataCenter, availability: stock)]
        )
    }
}
