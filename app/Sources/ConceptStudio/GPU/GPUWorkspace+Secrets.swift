// Credentials for a new pod travel as RunPod account secrets (POD-SPEC §1): the pod's
// environment holds `{{ RUNPOD_SECRET_<name> }}` placeholders and never a token, so a pod
// listing cannot leak one.

import ConceptCore
import Foundation
import Security

extension GPUWorkspace {
    /// 256 random bits from the system CSPRNG, hex encoded: the pod agent's bearer and vLLM key.
    nonisolated static func newAgentToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw StudioError.message("Your Mac could not generate a key for the cloud GPU. Try again.")
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    struct PodCredentials {
        let env: [String: String]
        /// The per-pod secret holding the agent bearer; deleted when the pod is removed.
        let agentSecret: String

        var holdsHubToken: Bool {
            env["HF_TOKEN"] != nil
        }
    }

    /// Writes the Hub token (when there is one and `cloud` may hold it) and the new agent bearer to the
    /// account's secret store. The Hub secret has one fixed name and is rewritten every time, so a rotated
    /// token takes effect at the next rental.
    func storeCredentials(_ provider: any GPUProvider, cloud: GPUCloud) async throws -> PodCredentials {
        var env: [String: String] = [:]
        if hasHubCredential, cloud.receivesHubToken {
            let token = try await freshHubToken()
            try await provider.storeSecret(name: PodSecrets.hubTokenName, value: token)
            env["HF_TOKEN"] = PodSecrets.reference(PodSecrets.hubTokenName)
        }
        if !diagnosticsToken.isEmpty, cloud.receivesHubToken {
            try await provider.storeSecret(name: PodSecrets.diagnosticsTokenName, value: diagnosticsToken)
            env["LOGFIRE_TOKEN"] = PodSecrets.reference(PodSecrets.diagnosticsTokenName)
        }
        let agentSecret = try PodSecrets.newAgentSecretName()
        try await provider.storeSecret(name: agentSecret, value: agentToken)
        env["PODAGENT_TOKEN"] = PodSecrets.reference(agentSecret)
        return PodCredentials(env: env, agentSecret: agentSecret)
    }

    /// The image the next computer runs: the trainer's image, with the caption server (its "-captioning"
    /// tag) when the captioning screen asked for one or a caption model is kept running during training.
    /// A custom image from Settings is used as entered.
    var podImage: String {
        let override = imageName.trimmingCharacters(in: .whitespacesAndNewlines)
        let captioning = rentsCaptionServer || keepCaptionServer
            || (projectFolder != nil && exactModelRow?.hooks.generator != nil)
        let image = override.isEmpty
            ? StudioSession.defaultPodImageName + (captioning ? Self.captioningTagSuffix : "")
            : override
        return image.replacingOccurrences(of: "{trainer}", with: trainer)
    }

    nonisolated static let captioningTagSuffix = "-captioning"
    nonisolated static let noCaptionServer = "This cloud GPU was rented without the caption server. "
        + "Use hosted captioning, or rent a cloud GPU for captioning from the Captioning screen."

    /// Creates the pod. A creation that fails leaves no agent secret behind.
    func createPod(
        _ provider: any GPUProvider, offer: GPUOffer, volume: GPUVolume?, credentials: PodCredentials
    ) async throws -> RentedPod {
        do {
            var env = credentials.env
            env["PODAGENT_WORKSPACE_BYTES"] = String(Int64(volume?.size ?? RunPodProvider.podDiskGB) * 1_000_000_000)
            return try await provider.create(PodCreation(
                name: PodNaming.name(project: projectFolder?.lastPathComponent ?? ""),
                offer: offer, count: gpuCount, image: podImage,
                minCudaVersion: modelTable.minimumCUDA(trainer), volume: volume, env: env
            ))
        } catch {
            try? await provider.deleteSecret(name: credentials.agentSecret)
            throw error
        }
    }
}

extension GPUWorkspace {
    var usesHubOAuth: Bool {
        hubOAuthToken != nil
    }

    var hasHubCredential: Bool {
        usesHubOAuth || !hubToken.isEmpty
    }

    func freshHubToken() async throws -> String {
        try Task.checkCancellation()
        guard let hubOAuthToken else { return hubToken }
        let token = try await hubOAuthToken()
        try Task.checkCancellation()
        guard !token.isEmpty else {
            throw StudioError.message("Sign in with Hugging Face again before using your account.")
        }
        return token
    }

    /// Credentialed operations must be admitted before input uploads or changes to running services.
    func hubTokenUnavailableReason(_ name: String, service: AgentService?) -> String? {
        guard !demoMode, usesHubOAuth, cloudGPUHoldsHubToken,
              !["tensorboard", "cleanup-datasets"].contains(name), service?.supportsHFToken != true else { return nil }
        return "This cloud GPU image cannot renew Hugging Face access for "
            + name + ". Use an updated ConceptStudio pod image before starting this operation. "
            + "Existing pods are not upgraded automatically."
    }

    /// A service-start copy only: callers retain their canonical params for saved runs and repeat.
    /// Manual tokens keep their existing rental environment; OAuth access tokens are renewed per operation.
    func paramsWithFreshHubToken(
        _ params: JSONObject, service: String, agent: any PodAgent
    ) async throws -> JSONObject {
        var request = params
        request["hf_token"] = nil
        guard !demoMode, usesHubOAuth, cloudGPUHoldsHubToken else { return request }
        let startRevision = agentStartRevision
        let podID = pod?.id
        let inventory = try await agent.services()
        try Task.checkCancellation()
        guard startRevision == agentStartRevision, podID == pod?.id,
              usesHubOAuth, cloudGPUHoldsHubToken else { throw CancellationError() }
        if let reason = hubTokenUnavailableReason(service, service: inventory.first(where: { $0.name == service })) {
            throw StudioError.message(reason)
        }
        let token = try await freshHubToken()
        guard startRevision == agentStartRevision, podID == pod?.id, usesHubOAuth, cloudGPUHoldsHubToken else {
            throw CancellationError()
        }
        request["hf_token"] = .string(token)
        return request
    }

    /// Whether the cloud GPU holds the Hub token: the rented one as it was created, else the one selected
    /// to rent. Without it the cloud GPU works as for a person with no Hugging Face account: training media
    /// are uploaded from this Mac, and the trained model is saved to this Mac rather than published from it.
    var cloudGPUHoldsHubToken: Bool {
        guard hasHubCredential else { return false }
        if pod != nil { return saved?.hubTokenOnPod ?? true }
        return offers.first { $0.id == selectedGPU }?.cloud.receivesHubToken ?? true
    }

    /// Whether the trained model can be published from the cloud GPU.
    var canPushToHub: Bool {
        demoMode || cloudGPUHoldsHubToken
    }

    /// The person has a Hub token, but the cloud GPU does not get it (Community Cloud).
    var hubTokenKeptOffCloudGPU: Bool {
        !demoMode && hasHubCredential && !cloudGPUHoldsHubToken
    }

    /// The gated training model when no Hugging Face account or manual token is connected.
    var gatedModelWithoutHubToken: ModelRow? {
        guard !demoMode, !hasHubCredential, let row = exactModelRow, row.source.gated else { return nil }
        return row
    }

    /// A gated model downloads only with the Hub token, so it cannot train on a cloud GPU kept without it.
    func checkModelDownloadsWithoutHubToken() throws {
        if let row = gatedModelWithoutHubToken {
            throw StudioError.message("\(row.shortName) needs your Hugging Face account to download. "
                + "Sign in with Hugging Face in Settings, then remove this cloud GPU and rent a Secure Cloud "
                + "GPU to train it.")
        }
        guard hubTokenKeptOffCloudGPU, let row = exactModelRow, row.source.gated else { return }
        throw StudioError.message("\(row.shortName) needs your Hugging Face account to download, and this "
            + "cloud GPU was rented without account access (Community Cloud GPUs never get it). "
            + "Remove this cloud GPU and rent "
            + "a Secure Cloud GPU to train it.")
    }

    /// The sentence after "saved to <folder>." for a result whose Hugging Face destination was skipped
    /// because the cloud GPU had no token. The Mac cannot publish a trained model itself yet.
    func unpublishedSentence(_ result: TrainingResult) -> String {
        guard hubTokenKeptOffCloudGPU, result.destination == .download, !result.outputRepo.isEmpty else { return "" }
        return " It was not published to \(result.outputRepo): Community Cloud GPUs never get your Hugging Face "
            + "token, and ConceptStudio cannot yet publish a trained model from your Mac. Upload it there yourself."
    }

    func trainingStartedMessage(_ destination: TrainingResult.Destination, output: HubDestination) -> String {
        if destination == .hub {
            return "Training started. When it finishes, the LoRA is published to \(output.repo)."
        }
        let skipped = hubTokenKeptOffCloudGPU && !output.repo.isEmpty
            ? " Community Cloud GPUs never get your Hugging Face token, so it is not published." : ""
        return "Training started. When it finishes, the LoRA is saved into this project’s results folder." + skipped
    }
}
