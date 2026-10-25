import ConceptCore
@testable import ConceptStudio
import Foundation
import Testing

private struct NewProjectModelsTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        #expect(request.url?.path == "/v1/models")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-plan-token")
        return HTTPResponse(status: 200, body: Data(
            #"{"models":[{"slug":"plan-model","display_name":"Plan model","visibility":"list"}]}"#.utf8
        ))
    }
}

@Suite("new project defaults")
@MainActor
struct NewProjectDefaultsTests {
    @Test(arguments: [
        ("Hákon Krea 2", "hakon-krea-2-lora"),
        ("Þórður Ægir Örn", "thordur-aegir-orn-lora"),
        ("Ha\u{301}kon Krea 2", "hakon-krea-2-lora"),
        ("Straße", "strasse-lora"),
        ("--a..b  c__", "a.b-c-lora"),
        ("", "concept-lora"),
    ])
    func modelRepositoryNamesTransliterateLetters(project: String, expected: String) {
        #expect(GPUWorkspace.repoName(project: project) == expected)
    }

    @Test func newProjectUsesConnectedChatGPTInsteadOfPreviousCloudGPU() async throws {
        let preferences = IsolatedDefaults()
        defer { preferences.remove() }
        preferences.defaults.set("vllm", forKey: "endpointKind")
        preferences.defaults.set("previous-pod-model", forKey: "modelName")
        preferences.defaults.set("https://old-server.example/v1", forKey: "vllmBaseURL")
        let manager = try chatGPT(preferences: preferences.defaults)
        let session = makeTestSession(preferences: preferences.defaults, chatGPT: manager)
        #expect(manager.accounts.isEmpty)
        let previous = temporaryTestDirectory("previous-project")
        let next = temporaryTestDirectory("new-project")
        defer {
            try? FileManager.default.removeItem(at: previous)
            try? FileManager.default.removeItem(at: next)
        }
        var project = try StudioProject.create(at: previous)
        project.job.endpoints = try Endpoints(captioner: EndpointSpec(
            kind: "vllm", model: "previous-pod-model", baseURL: "https://old-server.example/v1"
        ))
        try project.save()
        session.openProject(url: previous)
        await session.task?.value
        #expect(session.endpointKind == "vllm")

        session.createProject(at: next)
        await session.task?.value

        #expect(session.errorMessage == nil)
        #expect(session.project?.directory == next)
        #expect(session.endpointKind == "openai")
        #expect(session.openAIUsesChatGPT)
        #expect(session.modelName == "plan-model")
        #expect(session.criticKind == "openai")
        #expect(session.criticModel == "plan-model")
        #expect(!session.usingPodCaptioner)
        #expect(session.requestBaseURL.isEmpty)
        #expect(try session.endpoint().client is ChatGPTModelClient)
        await session.closeProject()
    }

    @Test func newProjectKeepsRememberedConnectedAPIProvider() async throws {
        let preferences = IsolatedDefaults()
        defer { preferences.remove() }
        preferences.defaults.set("anthropic", forKey: "endpointKind")
        preferences.defaults.set("chosen-model", forKey: "modelName")
        let manager = try chatGPT(preferences: preferences.defaults)
        let session = makeTestSession(
            preferences: preferences.defaults, secrets: MemorySecretStore(["anthropic": "fixture-key"]),
            chatGPT: manager
        )
        let folder = temporaryTestDirectory("new-project-api")
        defer { try? FileManager.default.removeItem(at: folder) }
        session.createProject(at: folder)
        await session.task?.value
        #expect(session.errorMessage == nil)
        #expect(session.endpointKind == "anthropic")
        #expect(session.modelName == "chosen-model")
        #expect(manager.availableModels.isEmpty)
        await session.closeProject()
    }

    @Test func newProjectSelectsConfiguredKeyWhenRememberedProviderIsDisconnected() async {
        let preferences = IsolatedDefaults()
        defer { preferences.remove() }
        preferences.defaults.set("vllm", forKey: "endpointKind")
        let manager = ChatGPTAccounts(
            preferences: preferences.defaults, loadCredentials: { nil }, saveCredentials: { _ in }
        )
        let session = makeTestSession(
            preferences: preferences.defaults, secrets: MemorySecretStore(["gateway": "fixture-key"]),
            chatGPT: manager
        )
        let folder = temporaryTestDirectory("new-project-key")
        defer { try? FileManager.default.removeItem(at: folder) }
        session.createProject(at: folder)
        await session.task?.value
        #expect(session.errorMessage == nil)
        #expect(session.endpointKind == "gateway/anthropic")
        #expect(session.modelName == ProviderChoices.defaultModel(for: "gateway/anthropic"))
        await session.closeProject()
    }

    @Test func newProjectOpeningExistingFolderKeepsItsSavedCaptioner() async throws {
        let preferences = IsolatedDefaults()
        defer { preferences.remove() }
        let manager = try chatGPT(preferences: preferences.defaults)
        let session = makeTestSession(preferences: preferences.defaults, chatGPT: manager)
        let folder = temporaryTestDirectory("existing-project")
        defer { try? FileManager.default.removeItem(at: folder) }
        var project = try StudioProject.create(at: folder)
        project.job.endpoints = try Endpoints(captioner: EndpointSpec(
            kind: "vllm", model: "saved-model", baseURL: "https://saved-server.example/v1"
        ))
        try project.save()
        session.createProject(at: folder)
        await session.task?.value
        #expect(session.errorMessage == nil)
        #expect(session.endpointKind == "vllm")
        #expect(session.modelName == "saved-model")
        #expect(session.requestBaseURL == "https://saved-server.example/v1")
        #expect(manager.accounts.isEmpty)
        await session.closeProject()
    }

    private func chatGPT(preferences: UserDefaults) throws -> ChatGPTAccounts {
        let state = ChatGPTSavedState(hostID: "urn:uuid:new-project-fixture", registrations: [
            ChatGPTRegistration(
                clientID: "oaiapp_project_fixture", subject: "fixture", email: "fixture@example.invalid",
                tokens: ChatGPTTokens(
                    accessToken: "fixture-plan-token", refreshToken: "fixture-refresh", idToken: "fixture-id",
                    scopes: [ChatGPTAuth.directScope], expiresAt: Date().addingTimeInterval(3600), nonce: "fixture"
                )
            ),
        ])
        let credentials = try MemoryChatGPTCredentials(state)
        return ChatGPTAccounts(
            preferences: preferences, transport: NewProjectModelsTransport(),
            loadCredentials: { credentials.load() }, saveCredentials: { credentials.save($0) }
        )
    }
}
