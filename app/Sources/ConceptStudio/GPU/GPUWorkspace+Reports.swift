import ConceptCore
import Foundation

extension GPUWorkspace {
    func startAutomaticReport() {
        guard !demoMode, reportTask == nil, !isBusy, !isStopping, hasRunningPod,
              !isTraining, !resultNeedsSaving, generation?.state != .generating,
              let report = trainingReports.first(where: { report in
                  report.state == .waiting && runHistory.contains {
                      $0.runID == report.runID && $0.hasFinishedModel && $0.volumeID == currentVolumeID
                          && $0.trainer == trainer
                  }
              }), reportUnavailableReason(trainer) == nil else { return }
        reportTask = Task {
            await self.runTrainingReport(report.runID)
            self.reportTask = nil
        }
    }

    func runTrainingReport(_ runID: String) async {
        await perform {
            guard let report = self.trainingReports.first(where: { $0.runID == runID }),
                  let group = self.reportGroups.first(where: { $0.id == report.groupID }),
                  let run = self.runHistory.first(where: { $0.runID == runID }),
                  let agent = self.agent, self.hasRunningPod,
                  run.volumeID == self.currentVolumeID, run.trainer == self.trainer,
                  group.settings.baseModel == run.baseModel, let projectFolder = self.projectFolder else {
                throw StudioError.message("Connect this run's project and saved storage before making its report.")
            }
            try await self.requireServices(["generate-\(run.trainer)", "vllm"], from: agent)
            self.beginReportBudget(runID)
            self.beginAppWork()
            self.updateReport(runID) { $0.state = .running; $0.failure = nil }
            defer {
                self.finishReportBudget()
                self.endAppWork()
            }
            var reportFailure: (any Error)?
            do {
                try self.requireReportBudget(run)
                try await self.completeTrainingReport(run, group: group, agent: agent, projectFolder: projectFolder)
            } catch { reportFailure = error }
            do {
                try await self.reconcileReportCaptionServer(group: group, run: run, agent: agent)
            } catch { if reportFailure == nil { reportFailure = error } }
            do {
                if let reportFailure { throw reportFailure }
                self.updateReport(runID) { $0.state = .complete; $0.completedAt = Date() }
                try self.saveReportArtifact(runID, group: group)
                self.message = "Post-training report saved in this project."
            } catch {
                self.updateReport(runID) { $0.state = .failed; $0.failure = error.localizedDescription }
                try? self.saveReportArtifact(runID, group: group)
                let current = self.runHistory.first { $0.runID == runID } ?? run
                if let cap = current.gpuBudgetUSD,
                   self.currentRunCost(current, podCost: self.estimatedPodCost) >= cap {
                    Task { await self.stopEverything(discardingPendingResult: true) }
                }
                throw error
            }
        }
    }

    /// The report may use an older frozen judge. Return its live server to the user's current
    /// choice before releasing the report's budget and work guards; cancellation never starts a reload.
    func reconcileReportCaptionServer(
        group: TrainingReportGroup, run: TrainingRun, agent: any PodAgent
    ) async throws {
        guard group.settings.judgeModel != captionModel else { return }
        captionServerActive = false
        try Task.checkCancellation()
        try requireReportBudget(run)
        let services = try await agent.services()
        guard services.contains(where: { $0.name == "vllm" && $0.active }) else { return }
        try await ensureCaptionServer(agent, plan: agent.plan(), services: services)
        try Task.checkCancellation()
        captionServerActive = true
    }

    private func completeTrainingReport(
        _ run: TrainingRun, group: TrainingReportGroup, agent: any PodAgent, projectFolder: URL
    ) async throws {
        // Resume scoring downloaded batches before spending GPU time on any new renders.
        for comparison in generations where comparison.sourceRunID == run.runID
            && comparison.reportGroupID == group.id && comparison.state == .saved {
            let pending = unfinishedReportPrompts(run.runID, group: group)
            if comparison.reportPromptIDs?.contains(where: { id in pending.contains { $0.id == id } }) == true {
                try await scoreReportComparison(comparison, group: group, run: run, agent: agent)
            }
        }
        guard !unfinishedReportPrompts(run.runID, group: group).isEmpty else { return }
        let files = try await agent.runFiles(runID: run.runID)
        guard let checkpoint = RunArtifacts.newest(files.filter { $0.path.hasSuffix(".safetensors") }) else {
            throw StudioError.message("This run has no checkpoint available on its saved storage.")
        }
        let references = try await uploadReportStyleReferences(group, agent: agent)
        while true {
            let prompts = Array(unfinishedReportPrompts(run.runID, group: group).prefix(6))
            if prompts.isEmpty { return }
            try Task.checkCancellation()
            guard self.projectFolder == projectFolder else {
                throw StudioError.message("Reopen the report's original project to continue.")
            }
            try requireReportBudget(run)
            try await startComparison(
                run: run, checkpoint: checkpoint, prompts: prompts.map(\.text), seeds: group.seeds,
                report: ReportComparisonRequest(group: group, promptIDs: prompts.map(\.id), styleReferences: references)
            )
            try await waitForService("generate-" + run.trainer) {
                // Stop cancels and joins operationTask, so request it outside that task.
                Task { try? await self.enforceLimits() }
            }
            try await settleGeneration(agent, services: agent.services())
            try await retrieveGeneration()
            guard let comparison = generation, comparison.state == .saved else {
                throw StudioError.message("Report generation did not finish every requested output.")
            }
            try requireReportBudget(run)
            try await scoreReportComparison(comparison, group: group, run: run, agent: agent)
        }
    }

    private func saveReportArtifact(_ runID: String, group: TrainingReportGroup) throws {
        guard let report = trainingReports.first(where: { $0.runID == runID }) else { return }
        let folder = try resultsFolder(for: runID)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(SavedTrainingReport(group: group, report: report))
            .write(to: folder.appendingPathComponent("report.json"), options: .atomic)
    }

    func updateReport(_ runID: String, _ change: (inout TrainingReport) -> Void) {
        guard let index = trainingReports.firstIndex(where: { $0.runID == runID }) else { return }
        change(&trainingReports[index])
        saveProjectRecord()
    }

    private func unfinishedReportPrompts(_ runID: String, group: TrainingReportGroup) -> [ReportPrompt] {
        let done = Set(trainingReports.first { $0.runID == runID }?.completedPromptIDs ?? [])
        return group.prompts.filter { !done.contains($0.id) }
    }

    func requireReportBudget(_ run: TrainingRun) throws {
        let current = runHistory.first { $0.runID == run.runID } ?? run
        guard hasRunningPod, let cap = current.gpuBudgetUSD, cap.isFinite,
              currentRunCost(current, podCost: estimatedPodCost) < cap else {
            throw StudioError.message("The run's budget is exhausted. Raise that run's budget to continue its report.")
        }
    }

    private func uploadReportStyleReferences(_ group: TrainingReportGroup, agent: any PodAgent) async throws
        -> JSONObject? {
        let groups = try reportReferenceURLs(group, category: .style)
        guard !groups.isEmpty else { return nil }
        let upload = "report-style-" + UUID().uuidString.prefix(12).lowercased()
        var names = JSONObject()
        for (trigger, urls) in groups.sorted(by: { $0.key < $1.key }) {
            for url in urls {
                try Task.checkCancellation()
                let size = try Int64(url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
                try await agent.upload(name: upload, fileName: url.lastPathComponent, from: url, size: size)
            }
            names[trigger] = .array(urls.map { .string($0.lastPathComponent) })
        }
        return ["upload": .string(upload), "groups": .object(names)]
    }
}

extension GPUWorkspace {
    /// Resume changes this run's weights. Keep old renders in Generation history, but only
    /// outputs made after the continuation may contribute to its next report.
    func resetReportForResumedTraining(_ runID: String) throws {
        guard let index = trainingReports.firstIndex(where: { $0.runID == runID }),
              let group = reportGroups.first(where: { $0.id == trainingReports[index].groupID }) else { return }
        let previous = trainingReports[index]
        let comparisons = generations, current = generation
        trainingReports[index] = TrainingReport(runID: runID, groupID: group.id)
        for index in generations.indices where generations[index].sourceRunID == runID {
            generations[index].reportGroupID = nil
            generations[index].reportPromptIDs = nil
        }
        if generation?.sourceRunID == runID {
            generation?.reportGroupID = nil
            generation?.reportPromptIDs = nil
        }
        do {
            guard saveProjectRecord() else { throw StudioError.message("Save this project's report before resuming.") }
            try saveReportArtifact(runID, group: group)
        } catch {
            trainingReports[index] = previous
            generations = comparisons
            generation = current
            saveProjectRecord()
            try? saveReportArtifact(runID, group: group)
            throw error
        }
    }
}
