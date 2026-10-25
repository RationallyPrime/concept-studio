import Foundation

@MainActor
extension GPUWorkspace {
    /// A report can continue on a new pod whose spend counter starts at zero. Each segment adds
    /// to the run's recorded training/report cost and starts from this pod's current counter.
    func beginReportBudget(_ runID: String) {
        guard let index = runHistory.firstIndex(where: { $0.runID == runID }) else { return }
        runHistory[index].previousGPUCostUSD = runHistory[index].estimatedGPUCostUSD
            ?? runHistory[index].previousGPUCostUSD
        runHistory[index].podSpendAtStart = estimatedPodCost
        runHistory[index].hourlyRateUSD = saved?.hourlyRate
        activeReportRunID = runID
        saveProjectRecord()
    }

    func captureReportCost() {
        guard let id = activeReportRunID, let index = runHistory.firstIndex(where: { $0.runID == id }) else { return }
        runHistory[index].estimatedGPUCostUSD = currentRunCost(runHistory[index], podCost: estimatedPodCost)
        runHistory[index].updatedAt = Date()
    }

    func finishReportBudget() {
        captureReportCost()
        activeReportRunID = nil
        saveProjectRecord()
    }

    /// Welcome can retain the active global rental while another project is open. The pod's
    /// saved run is its budget source in that case; it is not imported into the other project.
    var activeBudgetedRun: TrainingRun? {
        guard hasRunningPod else { return nil }
        if let activeReportRunID,
           let run = runHistory.first(where: { $0.runID == activeReportRunID }) {
            return run
        }
        guard trainingState != "stopped", let result, result.state == .training else { return nil }
        let run = runHistory.first { $0.runID == result.runID } ?? saved?.run
        guard let run, run.runID == result.runID, run.volumeID == currentVolumeID else { return nil }
        return run
    }

    func currentRunCost(_ run: TrainingRun, podCost: Double) -> Double {
        run.previousGPUCostUSD + max(0, podCost - run.podSpendAtStart)
    }

    var activeRunBudget: Double? {
        activeBudgetedRun?.gpuBudgetUSD
    }

    var activeRunCost: Double? {
        activeBudgetedRun.map { currentRunCost($0, podCost: estimatedPodCost) }
    }

    func checkCurrentRunBudget() throws {
        guard hasRunningPod, let run = activeBudgetedRun, let cap = run.gpuBudgetUSD,
              currentRunCost(run, podCost: estimatedPodCost) < cap else {
            throw StudioError.message("The training run reached its budget during preparation; no trainer was started.")
        }
    }

    func finishFailedPreparation(previousResult: TrainingResult? = nil) {
        let reachedCap = activeBudgetedRun.map { run in
            run.gpuBudgetUSD.map { currentRunCost(run, podCost: estimatedPodCost) >= $0 } ?? false
        } ?? false
        updateResult(previousResult?.state ?? .failed)
        trainingState = "Preparation failed"
        if reachedCap {
            Task { await self.stopEverything(discardingPendingResult: true) }
        }
    }

    @discardableResult
    func raiseRunBudget(to cap: Double, runID: String? = nil) -> Bool {
        let chosen = runID.flatMap { id in runHistory.first { $0.runID == id } } ?? activeBudgetedRun
        guard var run = chosen, let previous = run.gpuBudgetUSD,
              cap.isFinite, cap > previous else {
            message = "Enter a training budget above the current one."
            return false
        }
        run.gpuBudgetUSD = cap
        if let index = runHistory.firstIndex(where: { $0.runID == run.runID }) {
            runHistory[index] = run
            saveProjectRecord()
        }
        if saved?.run?.runID == run.runID { saved?.run = run }
        persist()
        message = "Training run budget raised to \(StudioMoney.format(cap))."
        return true
    }
}
