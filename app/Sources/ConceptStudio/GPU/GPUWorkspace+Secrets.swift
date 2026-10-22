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
        if !hubToken.isEmpty, cloud.receivesHubToken {
            try await provider.storeSecret(name: PodSecrets.hubTokenName, value: hubToken)
            env["HF_TOKEN"] = PodSecrets.reference(PodSecrets.hubTokenName)
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
    /// Whether the cloud GPU holds the Hub token: the rented one as it was created, else the one selected
    /// to rent. Without it the cloud GPU works as for a person with no Hugging Face account: training media
    /// are uploaded from this Mac, and the trained model is saved to this Mac rather than published from it.
    var cloudGPUHoldsHubToken: Bool {
        guard !hubToken.isEmpty else { return false }
        if pod != nil { return saved?.hubTokenOnPod ?? true }
        return offers.first { $0.id == selectedGPU }?.cloud.receivesHubToken ?? true
    }

    /// Whether the trained model can be published from the cloud GPU.
    var canPushToHub: Bool {
        demoMode || cloudGPUHoldsHubToken
    }

    /// The person has a Hub token, but the cloud GPU does not get it (Community Cloud).
    var hubTokenKeptOffCloudGPU: Bool {
        !demoMode && !hubToken.isEmpty && !cloudGPUHoldsHubToken
    }

    /// The training model when it is gated and no Hub token is configured, so no cloud GPU could download it.
    var gatedModelWithoutHubToken: ModelRow? {
        guard !demoMode, hubToken.isEmpty, let row = exactModelRow, row.source.gated else { return nil }
        return row
    }

    /// A gated model downloads only with the Hub token, so it cannot train on a cloud GPU kept without it.
    func checkModelDownloadsWithoutHubToken() throws {
        if let row = gatedModelWithoutHubToken {
            throw StudioError.message("\(row.shortName) downloads from Hugging Face only with a token, and none "
                + "is set. Add a Hugging Face token in Settings, then remove this cloud GPU and rent a Secure Cloud "
                + "GPU to train it.")
        }
        guard hubTokenKeptOffCloudGPU, let row = exactModelRow, row.source.gated else { return }
        throw StudioError.message("\(row.shortName) downloads from Hugging Face only with your token, and this "
            + "cloud GPU was rented without it (Community Cloud GPUs never get it). Remove this cloud GPU and rent "
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
