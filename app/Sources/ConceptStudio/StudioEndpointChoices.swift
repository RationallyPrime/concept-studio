import ConceptCore
import Foundation

/// The captioning providers the app offers, in menu order, with their display names and default
/// models. Views list providers from here; nothing else hard-codes provider vocabulary.
enum ProviderChoices {
    static let defaultSelfHostedModel = "RationallyPrime/CapQwen3.6-27B-BLIP3o-Long-Caption-Distilled-FP8-NVFP4"

    struct Provider: Equatable, Identifiable {
        let kind: String
        let title: String
        let defaultModel: String
        var id: String {
            kind
        }
    }

    static let all: [Provider] = [
        Provider(kind: "openrouter", title: "OpenRouter gateway", defaultModel: "google/gemini-3.8-flash"),
        Provider(kind: "vercel", title: "Vercel AI Gateway", defaultModel: "google/gemini-3.8-flash"),
        Provider(kind: "gateway/anthropic", title: "Pydantic AI Gateway", defaultModel: "claude-sonnet-4-6"),
        Provider(kind: "google", title: "Google Gemini", defaultModel: "gemini-3.8-flash"),
        Provider(kind: "anthropic", title: "Anthropic Claude", defaultModel: "claude-sonnet-4-6"),
        Provider(kind: "openai", title: "OpenAI", defaultModel: "gpt-5.2"),
        Provider(kind: "vllm", title: "My cloud GPU / custom server", defaultModel: defaultSelfHostedModel),
    ]

    /// The provider a fresh install starts with.
    static let defaultKind = "openrouter"

    static var kinds: [String] {
        all.map(\.kind)
    }

    static func title(_ kind: String) -> String {
        all.first { $0.kind == kind }?.title ?? kind
    }

    static func defaultModel(for kind: String) -> String {
        all.first { $0.kind == kind }?.defaultModel ?? ""
    }

    /// CapQwen's measured caption path disables reasoning. An explicit request setting always wins.
    static func captionSettings(kind: String, model: String, settings: JSONObject) -> JSONObject {
        guard kind == "vllm", model == defaultSelfHostedModel else { return settings }
        if let extra = settings["extra_body"], extra.objectValue == nil { return settings }
        var result = settings
        var extra = settings["extra_body"]?.objectValue ?? [:]
        if let template = extra["chat_template_kwargs"], template.objectValue == nil { return settings }
        var template = extra["chat_template_kwargs"]?.objectValue ?? [:]
        if template["enable_thinking"] == nil { template["enable_thinking"] = .bool(false) }
        extra["chat_template_kwargs"] = .object(template)
        result["extra_body"] = .object(extra)
        return result
    }
}

@MainActor
extension StudioSession {
    static let defaultPodImageName =
        "ghcr.io/rationallyprime/concept-captioner-pod-{trainer}:v0.3.14-20261024"

    /// Builds before 2026-10-12 saved the shipped default image as the training-image preference,
    /// where it read as a manual override. Once per install, a stored value that is exactly such a
    /// default (this registry path with the `{trainer}` placeholder, any tag) is cleared to mean
    /// automatic. Anything else, and anything entered after the migration, is kept.
    static let podImageMigrationKey = "ConceptStudio.shippedDefaultPodImageCleared"

    nonisolated static func isShippedDefaultPodImage(_ name: String) -> Bool {
        name.range(
            of: #"\Aghcr\.io/rationallyprime/concept-captioner-pod-\{trainer\}:[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}\z"#,
            options: .regularExpression
        ) != nil
    }

    private func loadPodImageChoice() {
        var stored = preferences.string(forKey: "podImage") ?? ""
        if !preferences.bool(forKey: Self.podImageMigrationKey) {
            if Self.isShippedDefaultPodImage(stored) {
                stored = ""
                preferences.set("", forKey: "podImage")
            }
            preferences.set(true, forKey: Self.podImageMigrationKey)
        }
        podImageName = stored
    }

    var vllmTargetURL: String {
        requestBaseURL.isEmpty ? customBaseURL : requestBaseURL
    }

    var criticTargetURL: String {
        criticRequestBaseURL.isEmpty ? customBaseURL : criticRequestBaseURL
    }

    func loadSavedChoices() {
        endpointKind = preferences.string(forKey: "endpointKind") ?? ProviderChoices.defaultKind
        modelName = preferences.string(forKey: "modelName") ?? defaultModel(for: endpointKind)
        openAIUsesChatGPT = preferences.bool(forKey: "openAIUsesChatGPT")
        criticKind = endpointKind
        criticModel = modelName
        customBaseURL = preferences.string(forKey: "vllmBaseURL") ?? ""
        loadPodImageChoice()
        volumeID = preferences.string(forKey: "volumeID") ?? ""
        sshPublicKey = preferences.string(forKey: PodSSH.preferenceKey) ?? ""
        requestBaseURL = ""
        criticRequestBaseURL = ""
        usingPodCaptioner = false
        useCritic = false
    }

    /// A new project starts with a connected account, rather than a previous project's temporary GPU.
    /// Keep a remembered API provider when its key is configured; otherwise prefer enabled ChatGPT plan
    /// access, then another configured API provider, and finally a configured custom server.
    func loadConnectedCaptionChoices() async {
        await chatGPT.load()
        guard !Task.isCancelled else { return }
        let planReady = chatGPTReady
        let configured = ProviderChoices.kinds.filter { kind in
            guard kind != "vllm" else { return false }
            if kind == "openai", openAIUsesChatGPT { return planReady }
            let account = String(kind.split(separator: "/").first ?? "")
            return (try? secrets.read(account))?.isBlank == false
        }
        let selected = if configured.contains(endpointKind) {
            endpointKind
        } else if planReady {
            "openai"
        } else {
            configured.first ?? (customBaseURL.isBlank ? ProviderChoices.defaultKind : "vllm")
        }
        let changedProvider = selected != endpointKind
        endpointKind = selected
        if selected == "openai", planReady,
           changedProvider || openAIUsesChatGPT || !configured.contains("openai") {
            openAIUsesChatGPT = true
            if chatGPT.availableModels.isEmpty { await chatGPT.refreshModels() }
            guard !Task.isCancelled else { return }
            if !chatGPT.availableModels.contains(where: { $0.slug == modelName }) {
                modelName = chatGPT.availableModels.first?.slug ?? ""
            }
        } else if changedProvider || modelName.isBlank {
            modelName = defaultModel(for: selected)
        }
        criticKind = endpointKind
        criticModel = modelName
    }

    /// The default model for `kind` as this session sees it: for vllm, the remembered self-hosted model.
    func defaultModel(for kind: String) -> String {
        kind == "vllm" ? gpu.captionModel : ProviderChoices.defaultModel(for: kind)
    }

    /// "My cloud GPU / custom server" has one model choice, the one made on Captioning. It is also the model the
    /// cloud GPU's caption server starts, including the one kept running during training, so the GPU
    /// workspace follows it.
    func followSelfHostedModel() {
        let model = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard endpointKind == "vllm", !model.isEmpty, gpu.captionModel != model else { return }
        gpu.captionModel = model
    }

    var projectUsesAnotherSelfHostedModel: Bool {
        !demoMode && endpointKind == "vllm" && project?.job.endpoints?.captioner.kind == "vllm"
            && modelName != ProviderChoices.defaultSelfHostedModel
    }

    /// Change only the saved caption model; custom endpoint and reviewer settings stay with the project.
    func useDefaultSelfHostedCaptionModel() {
        guard !busy, !editing, projectUsesAnotherSelfHostedModel, var project else { return }
        do {
            project.job.endpoints?.captioner.model = ProviderChoices.defaultSelfHostedModel
            try project.save()
            self.project = project
            modelName = ProviderChoices.defaultSelfHostedModel
            message = "Project caption model updated to the current default."
        } catch { errorMessage = Self.describe(error) }
    }

    /// Call when the captioning provider changes from `old` to `new` (views: `.onChange(of:)`).
    /// Switching resets the model to the new provider's default; with ChatGPT sign-in, OpenAI starts
    /// on the account's first model.
    func providerChanged(from old: String, to new: String) {
        guard old != new else { return }
        if new == "openai", !openAIUsesChatGPT, !demoMode {
            Task { await adoptChatGPTIfSignedIn() }
        }
        if new == "openai", openAIUsesChatGPT {
            modelName = chatGPT.availableModels.first?.slug ?? ""
            return
        }
        modelName = defaultModel(for: new)
    }

    /// Call when the reviewer's provider changes, like `providerChanged(from:to:)`.
    func criticProviderChanged(from old: String, to new: String) {
        guard old != new else { return }
        if new == "openai", !openAIUsesChatGPT, !demoMode {
            Task { await adoptChatGPTIfSignedIn() }
        }
        if new == "openai", openAIUsesChatGPT {
            criticModel = chatGPT.availableModels.first?.slug ?? ""
            return
        }
        criticModel = defaultModel(for: new)
    }

    func applyJobChoices(_ job: Job) {
        if let endpoint = job.endpoints {
            endpointKind = endpoint.captioner.kind
            modelName = endpoint.captioner.model
            requestBaseURL = endpoint.captioner.baseURL ?? ""
            criticRequestBaseURL = endpoint.critic?.baseURL ?? ""
            outputMode = endpoint.captioner.outputMode
            concurrency = endpoint.captioner.concurrency
            useCritic = endpoint.critic != nil
            criticKind = endpoint.critic?.kind ?? endpointKind
            criticModel = endpoint.critic?.model ?? modelName
        }
        modelThinking = job.captionerThinking
        criticThinking = job.criticThinking
    }

    func endpoint(
        model: String? = nil,
        kind: String? = nil,
        settings: JSONObject? = nil,
        thinking: ThinkingLevel? = nil,
        baseURL: String? = nil,
        keys: (any KeyStore)? = nil,
        transport: any HTTPTransport = URLSessionTransport(),
        streamingTransport: any HTTPStreamingTransport = URLSessionTransport()
    ) throws -> ResolvedEndpoint {
        if demoMode { return ResolvedEndpoint(client: DemoModelClient(scenario: scenario)) }
        let selectedKind = kind ?? endpointKind
        let selectedModel = model ?? modelName
        let targetURL = baseURL ?? vllmTargetURL
        let spec = try EndpointSpec(
            kind: selectedKind,
            model: selectedModel,
            baseURL: selectedKind == "vllm" ? targetURL : nil,
            outputMode: outputMode,
            settings: ProviderChoices.captionSettings(
                kind: selectedKind, model: selectedModel,
                settings: settings ?? project?.job.endpoints?.captioner.settings ?? [:]
            ),
            concurrency: concurrency
        )
        if selectedKind == "openai", openAIUsesChatGPT {
            let requestSettings = try RequestSettings(settings: spec.settings, thinking: thinking ?? modelThinking)
            try ChatGPTModelClient.validate(settings: requestSettings, outputMode: spec.outputMode)
            guard let account = chatGPT.selectedAccount, account.isSignedIn, account.hasPlanPermission else {
                throw StudioError
                    .message("Log in with ChatGPT in Settings and allow use of your plan before captioning.")
            }
            guard chatGPT.availableModels.contains(where: { $0.slug == spec.model }) else {
                throw StudioError.message("Refresh the ChatGPT models on Captioning and choose one for this account.")
            }
            return ResolvedEndpoint(
                client: ChatGPTModelClient(
                    model: spec.model,
                    accessToken: chatGPT.tokenProvider(accountID: account.id),
                    onUsageLimit: { [weak self] error in
                        await self?.stopForChatGPTUsageLimit(error)
                    },
                    prepareVideo: { data, mediaType in
                        try await ChatGPTClipSheet.prepare(data: data, mediaType: mediaType).content
                    },
                    transport: streamingTransport
                ),
                settings: requestSettings,
                outputMode: spec.outputMode,
                requested: spec.model,
                concurrency: spec.concurrency
            )
        }
        if selectedKind == "vllm", usingPodCaptioner {
            guard let trustedURL = gpu.captionEndpoint,
                  !gpu.agentToken.isEmpty else {
                throw StudioError
                    .message("The cloud GPU you caption with is stopped or changed. Start its caption server again.")
            }
            return try Endpoints.resolve(
                spec,
                thinking: thinking ?? modelThinking,
                keys: StaticKeyStore(
                    [.vllm: gpu.agentToken],
                    vllmBaseURL: trustedURL.absoluteString
                ),
                transport: transport
            )
        }
        return try Endpoints.resolve(
            spec,
            thinking: thinking ?? modelThinking,
            keys: keys ?? keyStore,
            transport: transport
        )
    }

    /// The project's job with the current model choices, as job.yaml should store them. The caller
    /// writes it only when it differs from the saved job. A rented computer's caption server is
    /// temporary, so its URL is never stored: while it is in use the stored captioner stays as it was.
    func jobForCaptioning() throws -> Job {
        guard var job = project?.job else { throw StudioError.message("Open a project first.") }
        if !demoMode {
            let captioner = try usingPodCaptioner && endpointKind == "vllm"
                ? job.endpoints?.captioner ?? EndpointSpec(
                    kind: endpointKind, model: modelName, outputMode: outputMode, concurrency: concurrency
                )
                : EndpointSpec(
                    kind: endpointKind,
                    model: modelName,
                    baseURL: endpointKind == "vllm" ? vllmTargetURL : nil,
                    outputMode: outputMode,
                    settings: job.endpoints?.captioner.settings ?? [:],
                    concurrency: concurrency
                )
            let critic = useCritic ? try EndpointSpec(
                kind: criticKind,
                model: criticModel,
                baseURL: criticKind == "vllm" ? criticTargetURL : nil,
                settings: job.endpoints?.critic?.settings ?? [:]
            ) : nil
            job.endpoints = Endpoints(captioner: captioner, critic: critic)
        }
        job.captionerThinking = modelThinking
        job.criticThinking = criticThinking
        return job
    }
}

@MainActor
extension StudioSession {
    // MARK: Rented computer

    func useCurrentTrainingDataset() {
        gpu.repeatSourceRunID = ""
        updateTrainingProjectDefaults(preservingTrainer: true)
    }

    func updateTrainingProjectDefaults(preservingTrainer: Bool = false) {
        guard gpu.repeatSourceRunID.isEmpty else { return }
        gpu.triggerWords = project?.job.triggers.joined(separator: ",") ?? ""
        gpu.squareAugmentationAllowed = project?.job.concepts.isEmpty == false
            && project?.job.concepts.allSatisfy { $0.targetConcept == .style } == true
        gpu.conceptClassNouns = Dictionary(
            (project?.job.concepts ?? []).map { ($0.trigger, $0.classNoun) }, uniquingKeysWith: { first, _ in first }
        )
        gpu.profile = project?.job.profile ?? gpu.modelTable.defaultRow.captions.imageProfile
        gpu.datasetRevision = projectState.datasetRevision
        gpu.datasetContainsVideo = project?.images.contains { Sources.isVideo(Sources.suffix(of: $0.id)) } ?? false
        gpu.datasetItemCount = project?.images.count ?? 0
        // A chosen model that already writes the project's caption profile stays chosen: LTX-2.3 and
        // LTX-2.5 share one, and the profile alone would resolve to the first of them.
        if !preservingTrainer, !gpu.hasRunningPod, !gpu.hasNativeRecipe,
           let row = gpu.exactModelRow, row.followsProjectProfile,
           ![row.captions.imageProfile, row.captions.videoProfile].contains(gpu.profile) {
            // The model picker's path, so the project's model arrives with that model's checkpoint,
            // precision and resolution defaults; an unchanged model keeps the values already edited.
            gpu.chooseTrainingModel(GPUWorkspace.projectModel(forProfile: gpu.profile))
        }
    }

    func configureGPU() {
        updateTrainingProjectDefaults()
        guard !demoMode else { return }
        do {
            let hub = try huggingFace.storedTokenConfiguration()
            try gpu.configure(
                runpodKey: keyStore.read("runpod") ?? "",
                hubToken: hub.manualToken,
                diagnosticsToken: keyStore.read("logfire") ?? "",
                imageName: podImageName,
                networkVolumeID: volumeID.isEmpty ? nil : volumeID,
                hubOAuthToken: hub.oauthToken,
                sshPublicKey: sshPublicKey
            )
        } catch { errorMessage = Self.describe(error) }
    }
}
