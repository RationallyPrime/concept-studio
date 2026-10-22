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
            throw StudioError.message("Your Mac could not generate a key for the computer. Try again.")
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    struct PodCredentials {
        let env: [String: String]
        /// The per-pod secret holding the agent bearer; deleted when the pod is removed.
        let agentSecret: String
    }

    /// Writes the Hub token (when there is one) and the new agent bearer to the account's secret
    /// store. The Hub secret has one fixed name and is rewritten every time, so a rotated token
    /// takes effect at the next rental.
    func storeCredentials(_ provider: any GPUProvider) async throws -> PodCredentials {
        var env: [String: String] = [:]
        if !hubToken.isEmpty {
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
    nonisolated static let noCaptionServer = "This computer was rented without the caption server. "
        + "Use hosted captioning, or rent a captioning computer from the Captioning screen."

    /// Creates the pod. A creation that fails leaves no agent secret behind.
    func createPod(
        _ provider: any GPUProvider, offer: GPUOffer, volume: GPUVolume?, credentials: PodCredentials
    ) async throws -> RentedPod {
        do {
            let pod = try await provider.create(PodCreation(
                name: PodNaming.name(project: projectFolder?.lastPathComponent ?? ""),
                offer: offer, count: gpuCount, image: podImage,
                minCudaVersion: modelTable.minimumCUDA(trainer), volume: volume, env: credentials.env
            ))
            rentsCaptionServer = false
            return pod
        } catch {
            try? await provider.deleteSecret(name: credentials.agentSecret)
            throw error
        }
    }
}
