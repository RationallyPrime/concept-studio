import ConceptCore
@testable import ConceptStudio
import Foundation
import Testing

private actor ClassImageCaptionClient: ModelClient {
    nonisolated let requestedModel = "class-image-test"
    private(set) var instructions: [String] = []

    func request(
        instructions: String, messages: [ChatMessage], output: OutputRequest, settings: RequestSettings,
        onPartialText: (@Sendable (String) async -> Void)? = nil
    ) async throws -> ModelReply {
        self.instructions.append(instructions)
        return ModelReply(
            text: Caption(caption: "A person outdoors in daylight.").jsonValue.pythonDumps(),
            servedModel: requestedModel
        )
    }
}

@Suite("regularisation model coverage and supplied images")
@MainActor
struct RegularizationTests {
    @Test func everyModelDeclaresSupportAndGeneratedRowsStartEnabled() throws {
        let table = ModelTable.shared
        let generated = Set(table.models.filter { $0.regularization?.mode == .generate }.map(\.id))
        #expect(generated == ["flux1-dev", "z-image", "qwen-image-2.1", "minimax-h3"])
        for row in table.models {
            let offer = try #require(row.regularization)
            #expect(!offer.note.isEmpty)
            let workspace = GPUWorkspace(demoMode: true)
            workspace.chooseTrainingModel(row.modelRef)
            #expect((workspace.regularizationOffer != nil) == (row.trainer == "aitoolkit"))
            #expect(workspace.usesRegularization == (offer.mode == .generate))
            #expect(workspace.ownRegularizationImages == (offer.mode == .folder))
        }
    }

    @Test func h3CarriesGeneratedDefaultsAndSuppliedFolderRequiresSelection() throws {
        let (preferences, suite) = try temporaryPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let workspace = GPUWorkspace(demoMode: false, preferences: preferences)
        workspace.chooseTrainingModel("Comfy-Org/MiniMax-H3")
        workspace.triggerWords = "NORA7"
        workspace.conceptClassNouns = ["NORA7": "person"]
        let block = try #require(workspace.regularizationBlock(triggers: ["NORA7"]))
        #expect(block["source"] == .string("generate"))
        #expect(block["images"] == .int(16))
        #expect(block["generation"]?.objectValue?["steps"] == .int(28))
        workspace.ownRegularizationImages = true
        #expect(throws: StudioError.self) { try workspace.validateTrainingAids() }
        workspace.regularizationRemotePath = "/workspace/datasets/classes"
        try workspace.validateTrainingAids()
        #expect(workspace.regularizationBlock(triggers: ["NORA7"])?["path"] == .string(
            "/workspace/datasets/classes"
        ))
        #expect(try workspace.captioningForRegularization(nil) == nil)
    }

    @Test func suppliedImagesAreCaptionedUploadedAndLeaveOriginalSidecarsUntouched() async throws {
        let folder = temporaryTestDirectory("regularisation-source")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let bytes = try MediaFixtures.encoded(MediaFixtures.image(), type: .png)
        try bytes.write(to: folder.appendingPathComponent("original.png"))
        try Data("PRIVATE_CLASS_OWNER42 old caption".utf8).write(to: folder.appendingPathComponent("original.txt"))
        let (preferences, suite) = try temporaryPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let workspace = makeWorkspace(UnreachableAgentTransport(), preferences)
        workspace.regularizationFolder = folder
        workspace.ownRegularizationImages = true
        workspace.regularizationOn = true
        let client = ClassImageCaptionClient()
        let skill = try Skills.load()
        let captioning = try RegularizationCaptioning(
            captioner: RegularizationCaptioner(
                captioner: ResolvedEndpoint(client: client), skill: skill, profile: "plain",
                profileText: skill.profile("plain"), classNouns: ["person"]
            ), usesPodCaptionServer: false
        )
        let agent = H3TestAgent()
        workspace.agent = agent
        let params: JSONObject = ["regularization": .object([
            "source": .string("folder"), "path": .string(""), "weight": .double(0.7),
        ])]
        let result = try await workspace.captionedRegularization(
            params, plan: agent.plan(), captioning: captioning, agent: agent
        )
        let block = try #require(result["regularization"]?.objectValue)
        #expect(block["path"]?.stringValue?.hasPrefix("/workspace/datasets/class-") == true)
        #expect(block["weight"] == .double(0.7))
        let uploads = await agent.uploads
        #expect(uploads.contains { $0.name == "class-000001.png" && $0.data == bytes })
        #expect(uploads.contains { $0.name == "class-000001.txt"
                && String(data: $0.data, encoding: .utf8) == "A person outdoors in daylight."
        })
        #expect(await agent.starts.map(\.service) == ["pull-dataset"])
        #expect(await client.instructions.count == 1)
        #expect(await client.instructions.allSatisfy { !$0.contains("PRIVATE_CLASS_OWNER42") })
        #expect(try Data(contentsOf: folder.appendingPathComponent("original.png")) == bytes)
        #expect(try String(contentsOf: folder.appendingPathComponent("original.txt"), encoding: .utf8)
            == "PRIVATE_CLASS_OWNER42 old caption")
    }

    @Test func unusableClassImagesStayOutOfTrainingSnapshot() throws {
        let samples = [
            Sample(sampleID: "kept.png", data: Data([1]), suffix: ".png"),
            Sample(sampleID: "skipped.png", data: Data([2]), suffix: ".png"),
        ]
        let snapshot = try RegularizationImages.snapshot(samples: samples, captions: ["kept.png": "A person."])
        defer { snapshot.remove() }
        #expect(snapshot.itemCount == 1)
        #expect(Set(snapshot.files.map(\.name)) == ["kept.png", "kept.txt", "metadata.jsonl"])
        #expect(throws: StudioError.self) { try RegularizationImages.snapshot(samples: samples, captions: [:]) }
    }
}
