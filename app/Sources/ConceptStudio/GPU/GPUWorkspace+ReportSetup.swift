import ConceptCore
import Foundation

extension GPUWorkspace {
    var selectedReportGroup: TrainingReportGroup? {
        reportGroups.first { $0.id == selectedReportGroupID }
    }

    var reportAvailability: String? {
        if let reportSetupFailure { return reportSetupFailure }
        guard exactModelRow?.hooks.generator != nil else {
            return "This model row has no generation integration. Its training results are saved; "
                + "automatic render reports require a listed generation model."
        }
        return nil
    }

    var reportCostSummary: String {
        let count = (selectedReportGroup?.prompts.count ?? 0) * (selectedReportGroup?.seeds.count ?? 1) * 2
        let rate = regularizationHourlyRate.map { " GPU time is billed at \(StudioMoney.format($0))/hour." } ?? ""
        return "\(count) renders and \(count) GPU prompt judgments share this run's \(StudioMoney.format(runBudget)) "
            + "spending limit with training. The report stops at that limit; it has no separate allowance." + rate
    }

    /// Prepare the editable group before training. The same group stays fixed across subsequent runs.
    func prepareReportDraft(forceNew: Bool = false) async throws {
        reportSetupFailure = nil
        guard !demoMode, exactModelRow?.hooks.generator != nil, let projectFolder else { return }
        let project = try await StudioProject.open(at: projectFolder)
        let hasMotion = project.job.concepts.contains { $0.targetConcept == .motion }
        if hasMotion, effectiveModelRow.video == nil {
            reportSetupFailure = "This model produces still images. "
                + "A motion report needs a video-capable training model."
            return
        }
        if !forceNew, let group = selectedReportGroup, group.settings.baseModel == baseModel,
           group.settings.trainer == trainer, group.settings.judgeModel == captionModel,
           !project.job.adultContent || group.manualPrompts { return }
        let row = effectiveModelRow
        let generation = row.preview.generation ?? TrainingRun.defaultGeneration
        let settings = try ReportRenderSettings(
            trainer: trainer, baseModel: baseModel, resolution: trainingResolutions.max() ?? resolution,
            inferenceSteps: generation.steps, guidanceScale: generation.guidanceScale,
            frames: hasMotion ? (row.preview.video?.defaultFrames ?? 49)
                : (row.video == nil || row.preview.still ? 1 : (row.preview.video?.minFrames ?? 9)),
            frameRate: row.video?.fixedFPS ?? 24, judgeModel: captionModel,
            judgeExtraBodyJSON: JSONValue.object(RequestSettings(
                settings: ProviderChoices.captionSettings(
                    kind: "vllm", model: captionModel, settings: project.job.endpoints?.captioner.settings ?? [:]
                ), thinking: .none
            ).extraBody).pythonDumpsData()
        )
        let state = ProjectAppState.load(from: projectFolder)
        let captions = project.publishingImages(state: state).map(\.caption)
        let group = TrainingReportGroup(
            id: UUID().uuidString.lowercased(), name: "Comparison group \(reportGroups.count + 1)",
            prompts: ReportPrompts.draft(job: project.job, captions: captions), seeds: [42], settings: settings,
            captionDigest: VisionInspector.contentHash(Data(captions.sorted().joined(separator: "\n").utf8)),
            manualPrompts: project.job.adultContent,
            createdAt: Date()
        )
        reportGroups.append(group)
        selectedReportGroupID = group.id
        saveProjectRecord()
    }

    func editReportPrompt(_ id: String, text: String) {
        guard var group = selectedReportGroup,
              let index = group.prompts.firstIndex(where: { $0.id == id }) else { return }
        var prompts = group.prompts
        prompts[index].text = text
        prompts[index].heldOutAttributes = []
        group = group.edited(prompts: prompts)
        if let index = reportGroups.firstIndex(where: { $0.id == group.id }) { reportGroups[index] = group } else {
            group.name = "Comparison group \(reportGroups.count + 1)"
            reportGroups.append(group)
        }
        selectedReportGroupID = group.id
        saveProjectRecord()
    }

    /// Freeze prompts, render settings and reference bytes before a real run uses the group.
    func prepareTrainingReport() async throws -> String? {
        guard !demoMode, projectFolder != nil, exactModelRow?.hooks.generator != nil else { return nil }
        try await prepareReportDraft()
        guard reportSetupFailure == nil, var group = selectedReportGroup, let projectFolder else { return nil }
        guard !group.needsPrompts else {
            throw StudioError
                .message(
                    "Write the post-training report prompts before starting. Adult projects use your own prompts; "
                        + "other empty fields need a new setting or subject."
                )
        }
        guard group.prompts.allSatisfy({ !$0.text.contains("--") && $0.text.count <= 4000 }) else {
            throw StudioError.message("Report prompts must be at most 4,000 characters and contain no '--' overrides.")
        }
        if group.frozenAt == nil {
            let project = try await StudioProject.open(at: projectFolder)
            group.references = try await freezeReportReferences(group, project: project)
            group.frozenAt = Date()
            if let index = reportGroups.firstIndex(where: { $0.id == group.id }) { reportGroups[index] = group }
            guard saveProjectRecord()
            else { throw StudioError.message("Save this report group before starting training.") }
        }
        return group.id
    }

    private func freezeReportReferences(_ group: TrainingReportGroup, project: StudioProject) async throws
        -> [ReportReference] {
        let folder = group.folder(in: project.directory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let state = ProjectAppState.load(from: project.directory)
        let included = project.publishingImages(state: state)
        var references: [ReportReference] = []
        var nextFile = 0
        for concept in project.job.concepts {
            var sources: [URL] = []
            if concept.targetConcept.isPersonIdentity {
                let reference = project.referenceURL(for: concept.trigger)
                if FileManager.default.fileExists(atPath: reference.path) { sources = [reference] }
            } else if concept.targetConcept == .style {
                let images = included.filter { image in
                    project.job.mapping(for: image.id)?[concept.trigger] != nil
                }
                // At most eight evenly spaced confirmed examples keep the first report bounded.
                let count = min(8, images.count)
                if count > 0 { sources = (0 ..< count).map { images[$0 * images.count / count].url } }
            }
            var names: [String] = [], hashes: [String] = []
            for source in sources {
                try Task.checkCancellation()
                let bytes: Data
                if Sources.isVideo(Sources.suffix(of: source.lastPathComponent)) {
                    let info = try await MediaEditor.videoInfo(url: source)
                    bytes = try await MediaEditor
                        .png(MediaEditor.frame(url: source, seconds: info.duration * 0.5).image)
                } else {
                    bytes = try Images.providerImage(Data(contentsOf: source), suffix: ".png", maxSide: 2048).data
                }
                let name = String(format: "reference-%04d.png", nextFile)
                nextFile += 1
                try bytes.write(to: folder.appendingPathComponent(name), options: .atomic)
                names.append(name)
                hashes.append(VisionInspector.contentHash(bytes))
            }
            if !names.isEmpty {
                references.append(ReportReference(
                    trigger: concept.trigger, category: concept.targetConcept, files: names, sha256: hashes
                ))
            }
        }
        return references
    }

    func attachTrainingReport(runID: String, groupID: String?) {
        guard let groupID else { return }
        trainingReports.removeAll { $0.runID == runID }
        trainingReports.append(TrainingReport(runID: runID, groupID: groupID))
        saveProjectRecord()
    }

    func reportReferenceURLs(_ group: TrainingReportGroup, category: TargetConcept) throws -> [String: [URL]] {
        guard let projectFolder else { throw StudioError.message("Open the report's project first.") }
        let folder = group.folder(in: projectFolder)
        var results: [String: [URL]] = [:]
        for reference in group.references where reference.category == category {
            guard reference.files.count == reference.sha256.count else {
                throw StudioError.message("A frozen report reference changed. Start a new comparison group.")
            }
            var urls: [URL] = []
            for (name, hash) in zip(reference.files, reference.sha256) {
                let url = folder.appendingPathComponent(name)
                guard url.resolvingSymlinksInPath().deletingLastPathComponent() == folder.resolvingSymlinksInPath(),
                      try RunArtifacts.sha256(of: url) == hash else {
                    throw StudioError.message("A frozen report reference changed. Start a new comparison group.")
                }
                urls.append(url)
            }
            results[reference.trigger] = urls
        }
        return results
    }
}
