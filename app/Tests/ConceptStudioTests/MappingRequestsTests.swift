import ConceptCore
@testable import ConceptStudio
import Foundation
import ImageIO
import Testing

@Suite("mapping requests")
struct MappingRequestsTests {
    @Test func batchesPreserveOrderAndIsolateClips() {
        let images = ["a.png", "b.png", "c.mp4", "d.png", "e.png", "f.png", "g.png", "h.png"].map {
            ProjectImage(url: URL(fileURLWithPath: "/tmp/" + $0))
        }
        #expect(MappingRequests.batches(images, size: 4).map { $0.map(\.id) } == [
            ["a.png", "b.png"], ["c.mp4"], ["d.png", "e.png", "f.png", "g.png"], ["h.png"],
        ])
        #expect(MappingRequests.batches(images, size: 1).count == images.count)
    }

    @Test func retryPolicyDoesNotRetryPermissionsOrInvalidRequests() {
        #expect(MappingRequests.isTransient(ModelError.http(status: 429, body: "rate limited")))
        #expect(MappingRequests.isTransient(URLError(.networkConnectionLost)))
        #expect(!MappingRequests.isTransient(ModelError.http(status: 401, body: "unauthorized")))
        #expect(!MappingRequests.isTransient(ModelError.http(status: 400, body: "invalid")))
        #expect(!MappingRequests.isTransient(CancellationError()))
    }

    @Test @MainActor func contactSheetsHaveExpectedDimensions() async throws {
        let project = try await makeDemoProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        for count in [1, 4, 9] {
            guard case let .image(data, _) = try MappingRequests.contactSheet(Array(project.images.prefix(count)))
            else {
                Issue.record("Expected an encoded contact sheet"); return
            }
            let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
            let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            let side = Int(Double(count).squareRoot()) * MappingRequests.tilePixels
            #expect(image.width == side)
            #expect(image.height == side)
        }
    }
}

private actor MappingReplyClient: ModelClient {
    nonisolated let requestedModel = "mapping-test"
    var replies: [Result<ModelReply, ModelError>]
    var count = 0

    init(_ replies: [Result<ModelReply, ModelError>]) {
        self.replies = replies
    }

    func request(
        instructions: String, messages: [ChatMessage], output: OutputRequest, settings: RequestSettings,
        onPartialText: (@Sendable (String) async -> Void)?
    ) async throws -> ModelReply {
        count += 1
        return try replies.removeFirst().get()
    }
}

@MainActor
extension MappingRequestsTests {
    @Test func answersAreKeyedByTileRatherThanResponseOrder() async throws {
        let project = try await makeDemoProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        let client = MappingReplyClient([.success(ModelReply(text: """
        {"tiles":[{"tile":2,"description":"second scene","locators":[{"trigger":"NORA7","locator":"on the right"}]},
        {"tile":1,"description":"first scene","locators":[{"trigger":"NORA7","locator":"on the left"}]}]}
        """, servedModel: "test"))])
        let assistant = StudioAssistant(endpoint: ResolvedEndpoint(client: client), demo: false)
        let images = Array(project.images.prefix(2))
        let result = try await assistant.proposeMappingSheet(
            images: images,
            references: [:],
            concepts: project.job.concepts
        )
        #expect(result[images[0].id]?.mapping["NORA7"] == "on the left")
        #expect(result[images[1].id]?.description == "second scene")
    }

    @Test func aDroppedSheetRetriesMembersAndKeepsSuccessfulResults() async throws {
        let project = try await makeDemoProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        let client = MappingReplyClient([
            .failure(.transport("connection lost")),
            .success(ModelReply(text: """
            {"tiles":[{"tile":1,"description":"first scene","locators":[{"trigger":"NORA7","locator":"the person"}]}]}
            """, servedModel: "test")),
            .failure(.http(status: 401, body: "unauthorized")),
        ])
        let assistant = StudioAssistant(endpoint: ResolvedEndpoint(client: client), demo: false)
        let images = Array(project.images.prefix(2))
        let result = await assistant.mappingResult(images: images, references: [:], concepts: project.job.concepts)
        #expect(result.suggestions[images[0].id]?.mapping["NORA7"] == "the person")
        #expect(result.failures == [images[1].id])
        #expect(await client.count == 3)
    }
}

@MainActor
extension MappingRequestsTests {
    @Test func cancellationRetainsCompletedSingleImageRetries() async throws {
        let project = try await makeDemoProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        let client = MappingReplyClient([
            .failure(.transport("connection lost")),
            .success(ModelReply(text: """
            {"tiles":[{"tile":1,"description":"first scene","locators":[{"trigger":"NORA7","locator":"the person"}]}]}
            """, servedModel: "test")),
        ])
        let assistant = StudioAssistant(endpoint: ResolvedEndpoint(client: client), demo: false)
        let images = Array(project.images.prefix(2))
        let work = Task {
            await assistant.mappingResult(images: images, references: [:], concepts: project.job.concepts)
        }
        while await client.count < 2 {
            try await Task.sleep(for: .milliseconds(20))
        }
        work.cancel()
        let result = await work.value
        #expect(result.suggestions[images[0].id]?.mapping["NORA7"] == "the person")
        #expect(result.failures == [images[1].id])
        #expect(await client.count == 2)
    }
}

@MainActor
extension MappingRequestsTests {
    @Test func invalidTileNumberIsRetriedBeforeIndexingTheImage() async throws {
        let project = try await makeDemoProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        let client = MappingReplyClient([
            .success(ModelReply(text: """
            {"tiles":[{"tile":99,"description":"wrong tile number","locators":[]}]}
            """, servedModel: "test")),
            .success(ModelReply(text: """
            {"tiles":[{"tile":1,"description":"correct tile number","locators":[]}]}
            """, servedModel: "test")),
        ])
        let assistant = StudioAssistant(endpoint: ResolvedEndpoint(client: client), demo: false)
        let image = try #require(project.images.first)
        let result = try await assistant.proposeMappingSheet(
            images: [image],
            references: [:],
            concepts: project.job.concepts
        )
        #expect(result[image.id]?.description == "correct tile number")
        #expect(await client.count == 2)
    }
}
