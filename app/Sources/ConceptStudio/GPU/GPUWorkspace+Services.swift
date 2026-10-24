import Foundation

extension GPUWorkspace {
    nonisolated static let serviceTitles = [
        "vllm": "The caption server",
        "tensorboard": "TensorBoard",
        "cleanup-datasets": "Dataset cleanup",
        "pull-dataset": "Training data preparation",
        "push-lora": "Hugging Face model publishing",
        "trainer-aitoolkit": "AI Toolkit training",
        "trainer-ltx": "LTX training",
        "trainer-musubi": "musubi training",
        "generate-aitoolkit": "AI Toolkit generation",
        "generate-ltx": "LTX generation",
        "generate-musubi": "musubi generation",
        "draw-regularization": "Regularisation image generation",
        "upscale-media": "SeedVR2 upscaling",
    ]

    /// The same explanation gates the visible action and its preflight before any inputs are sent.
    func serviceUnavailableReason(_ name: String) -> String? {
        guard hasRunningPod else { return "Rent a cloud GPU for this task first." }
        guard let serviceInventory else { return "Waiting for the cloud GPU to report its installed tools." }
        let title = Self.serviceTitles[name] ?? name
        let recovery = name == "vllm"
            ? "Use hosted captioning, or choose Automatic in Advanced settings and rent from Captioning."
            : "Choose Automatic in Advanced settings and rent a GPU for this task."
        let missing = "\(title) is not installed on this cloud GPU. " + recovery
        guard let service = serviceInventory.first(where: { $0.name == name }) else { return missing }
        guard let available = service.available else {
            return "This GPU image cannot report whether \(title.lowercased()) is installed. "
                + "Rent a cloud GPU with the current image."
        }
        return available ? nil : missing
    }

    func unavailableServicesReason(_ names: [String]) -> String? {
        names.lazy.compactMap { self.serviceUnavailableReason($0) }.first
    }

    @discardableResult
    func requireServices(_ names: [String], from agent: any PodAgent) async throws -> [AgentService] {
        let revision = agentStartRevision
        let services = try await agent.services()
        try noteAgentReady(for: revision)
        updateServiceState(services)
        if let reason = unavailableServicesReason(names) { throw StudioError.message(reason) }
        return services
    }

    func updateServiceState(_ services: [AgentService]) {
        serviceInventory = services
        captionServerActive = services.contains { $0.name == "vllm" && $0.active }
        captionServerInstalled = services.first { $0.name == "vllm" }?.available == true
    }

    /// GPU work also keeps the requested caption model running on a separate GPU.
    var retainedCaptionServices: [String] {
        keepCaptionServer && (pod?.gpu.count ?? 0) > 1 ? ["vllm"] : []
    }

    var upscaleServices: [String] {
        ["upscale-media"] + retainedCaptionServices
    }

    func generationServices(_ trainer: String) -> [String] {
        ["generate-\(trainer)"] + retainedCaptionServices
    }

    func generationUnavailableReason(_ trainer: String) -> String? {
        unavailableServicesReason(generationServices(trainer))
    }

    var trainingServices: [String] {
        var names = ["trainer-\(trainer)", "pull-dataset"]
        if usesRegularization, !ownRegularizationImages { names.append("draw-regularization") }
        return names + retainedCaptionServices
    }

    var trainingUnavailableReason: String? {
        unavailableServicesReason(trainingServices)
    }

    func resumeServices(_ run: TrainingRun) -> [String] {
        var names = ["trainer-\(run.trainer)"]
        if run.localInputDigest != nil { names.append("pull-dataset") }
        return names + retainedCaptionServices
    }

    func resumeUnavailableReason(_ run: TrainingRun) -> String? {
        unavailableServicesReason(resumeServices(run))
    }

    func reportUnavailableReason(_ trainer: String) -> String? {
        unavailableServicesReason(["generate-\(trainer)", "vllm"])
    }
}
