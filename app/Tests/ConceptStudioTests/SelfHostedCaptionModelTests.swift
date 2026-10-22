import ConceptCore
@testable import ConceptStudio
import Foundation
import Testing

@MainActor
@Suite("Self-hosted caption model")
struct SelfHostedCaptionModelTests {
    private func vllmStarts(_ transport: UnreachableAgentTransport) async -> [String?] {
        await transport.starts.filter { $0.url?.path() == "/services/vllm/start" }.map { request in
            try? JSONValue(parsing: request.httpBody ?? Data()).objectValue?["params"]?
                .objectValue?["model"]?.stringValue
        }
    }

    @Test func theCloudGPUStartsTheModelChosenOnCaptioning() async throws {
        let (preferences, suite) = try temporaryPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let session = makeTestSession(preferences: preferences)
        let transport = UnreachableAgentTransport(agentAvailable: true, inferenceReady: true)
        session.gpu = makeWorkspace(transport, preferences)
        try session.gpu.configure(runpodKey: "fake", hubToken: "fake", imageName: "test")
        session.endpointKind = "vllm"
        session.modelName = "Qwen/Qwen2.5-VL-7B-Instruct"
        await session.gpu.refreshOffers()
        await session.gpu.rent()

        session.usePodCaptionServer()
        await session.task?.value
        #expect(session.errorMessage == nil)
        #expect(session.usingPodCaptioner)
        #expect(session.modelName == "Qwen/Qwen2.5-VL-7B-Instruct")
        #expect(try session.endpoint().requested == "Qwen/Qwen2.5-VL-7B-Instruct")
        #expect(await vllmStarts(transport) == ["Qwen/Qwen2.5-VL-7B-Instruct"])

        // A new choice restarts the running server with it rather than waiting on the old model.
        session.modelName = "Qwen/Qwen3-VL-4B-Instruct"
        session.usePodCaptionServer()
        await session.task?.value
        #expect(session.errorMessage == nil)
        #expect(await transport.agentRequests.contains { $0.url?.path() == "/services/vllm/stop" })
        #expect(await vllmStarts(transport) == ["Qwen/Qwen2.5-VL-7B-Instruct", "Qwen/Qwen3-VL-4B-Instruct"])
        // The same model is kept running during training, and remembered for the next workspace.
        #expect(session.gpu.captionModel == "Qwen/Qwen3-VL-4B-Instruct")
        #expect(makeWorkspace(transport, preferences).captionModel == "Qwen/Qwen3-VL-4B-Instruct")
        await session.gpu.stopEverything()
    }

    @Test func otherProvidersLeaveTheSelfHostedModelAlone() throws {
        let (preferences, suite) = try temporaryPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let session = makeTestSession(preferences: preferences)
        #expect(session.gpu.captionModel == ProviderChoices.defaultModel(for: "vllm"))
        session.endpointKind = "vllm"
        session.modelName = "someone/unmeasured-vl"
        session.endpointKind = "openrouter"
        session.providerChanged(from: "vllm", to: "openrouter")
        #expect(session.modelName == ProviderChoices.defaultModel(for: "openrouter"))
        #expect(session.gpu.captionModel == "someone/unmeasured-vl")
        // Returning to the provider offers the self-hosted choice again, not the shipped default.
        session.endpointKind = "vllm"
        session.providerChanged(from: "openrouter", to: "vllm")
        #expect(session.modelName == "someone/unmeasured-vl")
        // An unmeasured model starts with the measured Qwen3-VL-8B server settings.
        let measured = GPUWorkspace.captionServerSettings(for: "Qwen/Qwen3-VL-8B-Instruct")
        #expect(session.gpu.captionStartParams == measured.params(model: "someone/unmeasured-vl"))
    }
}

@Suite("Built-in skills")
struct BundledSkillTests {
    @Test func theBundledDefaultSkillIsListedWithEveryFile() throws {
        let skills = BundledSkill.all()
        let skill = try #require(skills.first { $0.name == Skills.defaultSkillName })
        #expect(skill.files.first?.path == "SKILL.md")
        let skillMD = ConceptCore.defaultSkillURL.appendingPathComponent("SKILL.md")
        #expect(try skill.files.first?.text == String(contentsOf: skillMD, encoding: .utf8))
        let paths = Set(skill.files.map(\.path))
        let profiles = try Skills.load().profiles()
        #expect(!profiles.isEmpty)
        for profile in profiles {
            #expect(paths.contains("references/profiles/\(profile).md"))
        }
    }

    @Test func skillsAddedBesideTheDefaultAppearInOrder() throws {
        let root = temporaryTestDirectory("BundledSkills")
        defer { try? FileManager.default.removeItem(at: root) }
        let files = [
            "second-skill/references/profiles/prose.md", "second-skill/references/notes.md",
            "second-skill/SKILL.md", "first-skill/SKILL.md", "not-a-skill/README.md",
        ]
        for file in files {
            let url = root.appendingPathComponent(file)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(file.utf8).write(to: url)
        }
        let skills = BundledSkill.all(in: root)
        #expect(skills.map(\.name) == ["first-skill", "second-skill"])
        #expect(skills.last?.files.map(\.path) == ["SKILL.md", "references/notes.md", "references/profiles/prose.md"])
        #expect(skills.last?.files.last?.text == "second-skill/references/profiles/prose.md")
    }
}
