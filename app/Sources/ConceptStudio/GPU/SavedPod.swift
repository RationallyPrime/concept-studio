import CryptoKit
import Foundation

/// The local record of the rented pod. Fields added after the first release decode with
/// defaults, so a record written by an older build still restores (and stays under budget).
struct SavedPod: Codable {
    var pod: RentedPod
    var started: Date
    var accruedGPUCostUSD = 0.0
    var hourlyRate: Double
    var budget: Double
    var trainer: String
    var runID: String
    /// Which RunPod key the pod was rented under (`SavedPod.fingerprint`); empty for a record from before
    /// this was kept. A pod missing under a different key may still exist in another account.
    var runpodKey = ""
    var idleMinutes = 15
    var volumeID = ""
    /// The RunPod secret holding this pod's agent bearer; deleted when the pod is removed.
    var agentSecret = ""
    /// Whether the pod was created with the Hub token in its environment. Records from before this was
    /// kept describe pods that got the token whenever there was one; an adopted pod is treated as without it.
    var hubTokenOnPod = true
    var networkVolume: GPUVolume?
    var storage: AgentStorageUsage?
    var points: [TrainingPoint] = []
    var result: TrainingResult?
    var run: TrainingRun?
    var generation: GeneratedComparison?
}

extension SavedPod {
    /// A short digest naming a RunPod key without storing it.
    static func fingerprint(_ key: String) -> String {
        key.isEmpty ? "" : SHA256.hash(data: Data(key.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        pod = try values.decode(RentedPod.self, forKey: .pod)
        started = try values.decode(Date.self, forKey: .started)
        accruedGPUCostUSD = try values.decodeIfPresent(Double.self, forKey: .accruedGPUCostUSD) ?? 0
        hourlyRate = try values.decode(Double.self, forKey: .hourlyRate)
        budget = try values.decode(Double.self, forKey: .budget)
        trainer = try values.decode(String.self, forKey: .trainer)
        runID = try values.decode(String.self, forKey: .runID)
        idleMinutes = try values.decodeIfPresent(Int.self, forKey: .idleMinutes) ?? 15
        volumeID = try values.decodeIfPresent(String.self, forKey: .volumeID) ?? ""
        agentSecret = try values.decodeIfPresent(String.self, forKey: .agentSecret) ?? ""
        hubTokenOnPod = try values.decodeIfPresent(Bool.self, forKey: .hubTokenOnPod) ?? true
        runpodKey = try values.decodeIfPresent(String.self, forKey: .runpodKey) ?? ""
        networkVolume = try values.decodeIfPresent(GPUVolume.self, forKey: .networkVolume)
        storage = try values.decodeIfPresent(AgentStorageUsage.self, forKey: .storage)
        points = try values.decodeIfPresent([TrainingPoint].self, forKey: .points) ?? []
        result = try values.decodeIfPresent(TrainingResult.self, forKey: .result)
        run = try values.decodeIfPresent(TrainingRun.self, forKey: .run)
        generation = try values.decodeIfPresent(GeneratedComparison.self, forKey: .generation)
        if !runID.isEmpty, !RunArtifacts.validRunID(runID) { runID = "" }
        if let result, !RunArtifacts.validRunID(result.runID) { self.result = nil }
        if let run, !RunArtifacts.validRunID(run.runID) { self.run = nil }
        if let generation, !RunArtifacts.validRunID(generation.runID)
            || !RunArtifacts.validRunID(generation.sourceRunID) { self.generation = nil }
    }
}
