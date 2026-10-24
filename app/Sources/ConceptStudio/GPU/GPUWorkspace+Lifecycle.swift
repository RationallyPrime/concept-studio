import ConceptCore
import Foundation

// MARK: - Cost guards and stopping

extension GPUWorkspace {
    func refresh() async {
        if let refreshTask { await refreshTask.value; return }
        // The task clears itself as it finishes: a caller that joined it and resumes first must not find
        // the finished task still recorded, or its next refresh returns without refreshing anything.
        let work = Task {
            await self.refreshState()
            self.refreshTask = nil
        }
        refreshTask = work
        await work.value
    }

    func refreshState() async {
        guard let provider, let current = pod, hasRunningPod else { return }
        let startRevision = agentStartRevision
        let resultBefore = result
        let settlementRevision = isBusy ? nil : operationRevision
        var agentAnswered = false
        do {
            try await enforceLimits()
            // A pod found stopped ends the polling, so a resolved error must clear here too.
            guard hasRunningPod else { clearRefreshFailure(); return }
            let currentStatus = try await provider.status(id: current.id)
            try requireCurrentAgentStart(startRevision)
            if !currentStatus.isRunning { freezePodCost() }
            updateHourlyRate(currentStatus)
            pod = currentStatus
            persist()
            guard hasRunningPod else { clearRefreshFailure(); return }
            guard let agent else {
                throw StudioError.message("Open Settings to restore this cloud GPU’s saved connection.")
            }
            if plan == nil {
                let currentPlan = try await agent.plan()
                try noteAgentReady(for: startRevision)
                plan = currentPlan
                let currentStorage = try? await agent.storageUsage()
                try requireCurrentAgentStart(startRevision)
                storage = currentStorage
            }
            let services = try await agent.services()
            try noteAgentReady(for: startRevision)
            updateCaptionServerState(services)
            agentAnswered = true
            if message.hasPrefix("Your cloud GPU is rented and its control agent is connecting.") {
                message = "Your cloud GPU is connected and ready. "
                    + "Its cost is visible below; you can stop it at any time."
            }
            let active = services.contains { $0.active && !["tensorboard", "vllm"].contains($0.name) }
            if active { lastActivity = Date() }
            updateTrainingService(services)
            if !runID.isEmpty { try await updateProgress(agent, services: services) }
            // A result created while this refresh was in flight is judged on the next one.
            if settlementRevision == operationRevision, !isBusy, result == resultBefore { try await settleResult(
                agent,
                services: services
            ) }
            if settlementRevision == operationRevision,
               !isBusy { try await settleGeneration(agent, services: services) }
            startAutomaticReport()
            clearRefreshFailure()
        } catch is CancellationError {
            return
        } catch {
            showRefreshFailure(error, for: startRevision)
        }
        // A failed agent/proxy request must not suppress the provider-level idle stop, but a
        // finished LoRA that is neither pushed nor downloaded keeps the computer up, and so does a
        // run the agent still answers for whose result has not been settled yet.
        if startRevision == agentStartRevision, hasRunningPod, agentReadyAt != nil,
           !keepsRunningWhenIdle, !isBusy, appWorkInFlight == 0, !resultNeedsSaving,
           !(agentAnswered && resultUnsettled),
           Date().timeIntervalSince(lastActivity) >= Double(idleMinutes * 60) {
            await stopEverything()
            if !hasRunningPod { message = "Stopped the idle cloud GPU to avoid further GPU charges." }
        }
    }

    /// A reply from a previous pod or start cannot make its replacement ready.
    func requireCurrentAgentStart(_ startRevision: Int) throws {
        try Task.checkCancellation()
        guard startRevision == agentStartRevision, hasRunningPod else { throw CancellationError() }
    }

    func noteAgentReady(for startRevision: Int) throws {
        try requireCurrentAgentStart(startRevision)
        if agentReadyAt == nil {
            let ready = Date()
            agentReadyAt = ready
            lastActivity = ready
            persist()
        }
    }

    func enforceLimits(now: Date = Date()) async throws {
        guard let saved, hasRunningPod else { return }
        elapsedCost = saved.accruedGPUCostUSD + max(0, now.timeIntervalSince(saved.started)) / 3600 * saved.hourlyRate
        let exceededRun = activeBudgetedRun.flatMap { run in
            run.gpuBudgetUSD.map { currentRunCost(run, podCost: elapsedCost) >= $0 }
        } == true
        if elapsedCost >= saved.budget || exceededRun {
            let stranded = resultNeedsSaving || resultUnsettled
            await stopEverything(discardingPendingResult: true)
            if !hasRunningPod {
                message = (exceededRun ? "This training run's budget was reached."
                    : "Your cloud GPU's spending limit was reached.") + " The GPU is stopped."
                    + (stranded ? " " + outputCustodyExplanation : "")
            }
        }
    }

    /// The spending limit enforced on the running pod.
    var activeBudget: Double? {
        hasRunningPod ? saved?.budget : nil
    }

    /// Raises the running pod's limit. The caller confirms with the user first; lowering is refused
    /// because it could stop the pod the moment it is applied.
    @discardableResult
    func raiseBudget(to newBudget: Double) -> Bool {
        guard var saved, hasRunningPod, newBudget.isFinite, newBudget > saved.budget else {
            message = "Enter a spending limit above the current one."
            return false
        }
        saved.budget = newBudget
        self.saved = saved
        budget = newBudget
        persist()
        message = "Spending limit raised to \(StudioMoney.format(newBudget))."
        return true
    }

    /// Stops the pod. Refuses, with a message, while a finished LoRA is unsaved unless
    /// `discardingPendingResult` is set (the budget sets it; the run stays on the volume).
    func stopEverything(discardingPendingResult: Bool = false) async {
        guard !isStopping else { return }
        if !discardingPendingResult, resultNeedsSaving {
            message = "Your trained model or generated outputs are not saved yet. Retrieve them first, or stop "
                + "anyway. " + outputCustodyExplanation
            return
        }
        isStopping = true
        defer { isStopping = false }
        operationTask?.cancel()
        await operationTask?.value
        guard let provider, let pod else { return }
        do {
            if let current = try? await provider.status(id: pod.id) {
                if !current.isRunning { freezePodCost() }
                self.pod = current
                persist()
                if !current.isRunning {
                    message = "RunPod confirms this cloud GPU is stopped. "
                        + "Workspace files remain; storage charges continue."
                    trainingState = "stopped"
                    return
                }
            }
            // Provider stop also works when the agent is unreachable; it is the final cost control.
            try await provider.stop(id: pod.id)
            for _ in 0 ..< 20 {
                let updated = try await provider.status(id: pod.id)
                if !updated.isRunning { freezePodCost() }
                self.pod = updated
                persist()
                if !updated.isRunning {
                    message = "Cloud GPU stopped. GPU billing has ended; "
                        + "workspace files remain and storage charges continue."
                    trainingState = "stopped"
                    return
                }
                try await Task.sleep(for: .seconds(1))
            }
            message = "Stop was requested, but RunPod has not confirmed it. Keep this window open and retry Stop."
        } catch {
            message = "Could not confirm the cloud GPU is stopped. Retry Stop or stop it in your RunPod account."
        }
    }

    func connectAgent(_ pod: RentedPod) {
        historyRunID = nil
        if demoMode {
            agent = DemoPodAgent(count: pod.gpu.count)
        } else if let provider {
            agent = PodAgentClient(
                baseURL: provider.url(for: pod, port: PodPort.agent), token: agentToken,
                transport: transport, downloader: downloader, uploader: uploader
            )
        }
    }

    func beginAppWork() {
        appWorkInFlight += 1
        noteActivity()
    }

    func endAppWork() {
        appWorkInFlight = max(0, appWorkInFlight - 1)
        noteActivity()
    }

    func showRefreshFailure(_ error: any Error, for startRevision: Int) {
        guard startRevision == agentStartRevision, !Task.isCancelled, !isBusy else { return }
        message = error.localizedDescription
        refreshFailureMessage = message
    }

    /// A refresh that succeeded clears the error an earlier one left on the status line.
    func clearRefreshFailure() {
        if let refreshFailureMessage, message == refreshFailureMessage { message = "" }
        refreshFailureMessage = nil
    }

    /// Drops every local trace of `pod`: the record, its agent token and its agent secret.
    func forgetPod(_ pod: RentedPod) async {
        let agentSecret = saved?.agentSecret ?? ""
        self.pod = nil
        message = "Cloud GPU removed."
        storage = nil
        plan = nil
        saved = nil
        agent = nil
        restartBlockedByHost = false
        if !demoMode {
            preferences.removeObject(forKey: Self.activePodKey)
            try? deleteAgentToken("pod.\(pod.id)")
        }
        // A secret left behind is harmless once the pod is gone; launch pruning removes it.
        if !agentSecret.isEmpty, let provider { try? await provider.deleteSecret(name: agentSecret) }
    }

    /// Removes the computer. Outputs only on its pod disk block removal unless the user has confirmed
    /// `discardingUndeliveredOutputs`, which deletes them with the disk.
    func terminate(discardingUndeliveredOutputs: Bool = false) async {
        let lost = undeliveredPodOutputs
        // A pod removed outside the app (RunPod console, another tool) cannot be stopped or deleted here, and
        // the stale record would keep Rent disabled. A 404 under the current key is not proof of deletion: the
        // key may belong to another account now, so the message says where it may still be.
        if !demoMode, let provider, let pod, await (try? provider.exists(id: pod.id)) == false {
            await forgetPod(pod)
            message = "RunPod has no cloud GPU \(pod.id) under the current key, so this app no longer tracks it"
                + (lost.isEmpty ? "" : " (with " + lost.joined(separator: ", ") + ")")
                + ". If you changed RunPod accounts, it may still exist, and bill storage, in the other account."
            return
        }
        guard lost.isEmpty || discardingUndeliveredOutputs else {
            message = "This cloud GPU holds outputs that have not been published or saved. "
                + "Start this same cloud GPU and retrieve them before removing it. " + stoppedPodDiskCostExplanation
            failure = message
            return
        }
        await stopEverything(discardingPendingResult: discardingUndeliveredOutputs)
        guard !hasRunningPod, let provider, let pod else { return }
        await perform {
            self.message = "Removing cloud GPU and its disk…"
            try await provider.terminate(id: pod.id)
            await self.forgetPod(pod)
            self.message = lost.isEmpty
                ? "Cloud GPU removed. Its disk was deleted; separate saved storage remains in RunPod."
                : "Cloud GPU removed. Its disk was deleted with "
                + lost.joined(separator: ", ") + "; separate saved storage remains in RunPod."
        }
    }
}

extension GPUWorkspace {
    private func updateProgress(_ agent: any PodAgent, services: [AgentService]) async throws {
        if historyRunID != runID {
            // TensorBoard is started by train(); after an agent restart it is down until started again.
            if !services.contains(where: { $0.name == "tensorboard" && $0.active }) {
                try? await agent.start("tensorboard", gpus: [], params: ["logdir": .string("/workspace/runs")])
            }
            // Retried on every refresh until the full curve arrives.
            if let history = try? await agent.history(runID: runID), !history.isEmpty {
                merge(history)
                historyRunID = runID
            }
        }
        if let point = try await agent.latest(runID: runID) { merge([point]) }
        if let log = try? await agent.runLog(runID: runID) { logs = log }
        persist()
        saveProjectRecord()
    }

    private func merge(_ incoming: [TrainingPoint]) {
        var byStep = Dictionary(points.map { ($0.step, $0) }, uniquingKeysWith: { first, _ in first })
        for point in incoming {
            byStep[point.step] = point
        }
        points = byStep.values.sorted { $0.step < $1.step }
    }
}
