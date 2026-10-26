import Foundation

extension GPUWorkspace {
    /// Park the stopped computer without destroying its disk, credentials or output custody.
    func keepStoppedPod() async {
        guard let pod, !pod.isRunning else { return }
        monitorTask?.cancel()
        refreshTask?.cancel()
        await refreshTask?.value
        persist()
        if let saved {
            keptPods.removeAll { $0.pod.id == pod.id }
            keptPods.append(saved)
            persistKeptPods()
        }
        releaseActivePod()
    }

    /// Stops tracking a cloud GPU RunPod refused to stop, so another can be rented. Called only after the view has
    /// warned that it may still be running and billing on RunPod.
    func forgetActivePod() async {
        guard pod != nil, stopRefused, !isStopping else { return }
        monitorTask?.cancel()
        refreshTask?.cancel()
        await refreshTask?.value
        let id = pod?.id ?? ""
        releaseActivePod()
        message = "ConceptStudio no longer tracks cloud GPU \(id). Stop or delete it in your RunPod account; "
            + "until then it may keep billing."
    }

    private func releaseActivePod() {
        stopRefused = false
        self.pod = nil
        saved = nil
        agent = nil
        plan = nil
        storage = nil
        result = nil
        generation = nil
        runID = ""
        points = []
        restartBlockedByHost = false
        if !demoMode { preferences.removeObject(forKey: Self.activePodKey) }
    }

    /// Drops kept computers RunPod no longer has under the current key, for example ones deleted on RunPod's own
    /// site, and returns their ids. Their agent tokens stay, as their secrets do, in case another account holds them.
    func forgetMissingKeptPods(_ provider: any GPUProvider) async throws -> [String] {
        var missing: [String] = []
        for kept in keptPods where try await !provider.exists(id: kept.pod.id) {
            missing.append(kept.pod.id)
        }
        guard !missing.isEmpty else { return [] }
        keptPods.removeAll { missing.contains($0.pod.id) }
        persistKeptPods()
        return missing
    }

    func persistKeptPods() {
        if !demoMode, let data = try? JSONEncoder().encode(keptPods) {
            preferences.set(data, forKey: Self.keptPodsKey)
        }
    }

    /// The view confirms switching first. Stop confirmation completes before another pod starts.
    func startKeptPod(id: String) async {
        guard !isBusy, !isStopping, let kept = keptPods.first(where: { $0.pod.id == id }) else { return }
        if hasRunningPod { await stopEverything(discardingPendingResult: true) }
        guard !hasRunningPod else { return }
        await keepStoppedPod()
        keptPods.removeAll { $0.pod.id == id }
        saved = kept
        pod = kept.pod
        runID = kept.runID
        points = kept.points
        result = kept.result
        generation = kept.generation
        storage = kept.storage
        trainer = kept.trainer
        rentsCaptionServer = kept.rentsCaptionServer
        idleMinutes = kept.idleMinutes
        keepsRunningWhenIdle = kept.keepsRunningWhenIdle
        budget = max(budget, kept.budget)
        restoreAgentToken(podID: id)
        connectAgent(kept.pod)
        persist()
        persistKeptPods()
        await startStoppedComputer()
    }

    /// Called only after the view confirms deletion of this exact computer and its disk.
    func removeKeptPod(id: String) async {
        await perform {
            guard let kept = self.keptPods.first(where: { $0.pod.id == id }),
                  let provider = self.provider else { return }
            let exists = try await provider.exists(id: id)
            if exists {
                guard try await !(provider.status(id: id)).isRunning else {
                    throw StudioError.message("This cloud GPU is running. Start managing it before removing it.")
                }
                try await provider.terminate(id: id)
            }
            self.keptPods.removeAll { $0.pod.id == id }
            self.persistKeptPods()
            if !self.demoMode { try? self.deleteAgentToken("pod.\(id)") }
            if !kept.agentSecret.isEmpty { try? await provider.deleteSecret(name: kept.agentSecret) }
            self.message = exists
                ? "Kept cloud GPU removed. Its disk was deleted; separate saved storage remains."
                : "RunPod has no cloud GPU \(id) under the current key, so this app no longer tracks it. "
                + "If you changed RunPod accounts, it may still exist, and bill storage, in the other account."
        }
    }

    func keptContents(_ record: SavedPod) -> String {
        var parts = ["Model cache and workspace files"]
        if let usage = record.storage, usage.workspaceScoped == true {
            parts.append(ByteCountFormatter.string(fromByteCount: usage.usedBytes, countStyle: .file))
        }
        if let result = record.result { parts.append("training run \(result.runID)") }
        if let generation = record.generation { parts.append("comparison \(generation.runID)") }
        return parts.joined(separator: " · ")
    }

    /// Published RunPod storage rates, checked 2026-10-22: https://www.runpod.io/pricing
    static func networkStorageMonthlyRate(_ volume: GPUVolume) -> Double? {
        switch volume.type {
        case "STANDARD": volume.size > 1000 ? 0.05 : 0.07
        case "HIGH_PERFORMANCE": 0.14
        default: nil
        }
    }

    func keptStorageCost(_ record: SavedPod) -> String {
        if !record.volumeID.hasPrefix("pod:") {
            guard let volume = record.networkVolume ?? volumes.first(where: { $0.id == record.volumeID }),
                  let rate = Self.networkStorageMonthlyRate(volume) else {
                return "Storage cost/day unavailable: refresh storage details in RunPod."
            }
            return "Shared storage: about \(StudioMoney.format(Double(volume.size) * rate / 30))/day "
                + "(\(volume.size) GB; billed once for this volume)"
        }
        let daily = Double(RunPodProvider.podDiskGB) * Self.stoppedPodDiskUSDPerGBMonth / 30
        return "Storage: about \(StudioMoney.format(daily))/day (\(RunPodProvider.podDiskGB) GB disk)"
    }
}
