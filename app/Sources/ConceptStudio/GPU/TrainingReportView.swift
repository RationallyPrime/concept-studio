import SwiftUI

struct ReportPlanView: View {
    @Bindable var workspace: GPUWorkspace

    var body: some View {
        StudioSection(
            title: "Post-training report",
            subtitle: "Render fixed prompts and seeds, then compare identity, style and prompt adherence."
        ) {
            if let reason = workspace.reportAvailability {
                Text(reason).font(.callout).foregroundStyle(StudioStyle.supportingText)
            } else if workspace.demoMode {
                Text("Reports use real trained checkpoints. The demo does not create report scores.")
                    .font(.callout).foregroundStyle(StudioStyle.supportingText)
            } else if let group = workspace.selectedReportGroup {
                HStack {
                    Text(group.name).font(.headline)
                    Spacer()
                    Button("New group from current captions") {
                        Task {
                            do { try await workspace.prepareReportDraft(forceNew: true) } catch {
                                workspace.failure = error.localizedDescription
                            }
                        }
                    }
                }
                Text(workspace.reportCostSummary).font(.callout).foregroundStyle(StudioStyle.supportingText)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Seed \(group.seeds.map(String.init).joined(separator: ", ")) · "
                    + "\(group.settings.resolution) px · \(group.settings.inferenceSteps) generation steps · "
                    + "Judge: \(group.settings.judgeModel)")
                    .font(.caption).foregroundStyle(StudioStyle.supportingText)
                if group.frozenAt != nil {
                    Text(
                        "This group's prompts, settings and reference images are frozen. "
                            + "Editing a prompt starts a new group."
                    )
                    .font(.callout).foregroundStyle(StudioStyle.supportingText)
                } else if group.needsPrompts {
                    StudioNotice(
                        "Write each empty report prompt before training. Adult projects always use your own prompts."
                    )
                }
                DisclosureGroup("Report prompts · \(group.prompts.count)") {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(group.prompts) { prompt in
                            Text(
                                prompt
                                    .trigger + " · " +
                                    (prompt.kind == .bleed ? "without the trigger (bleed)" : "concept")
                            )
                            .font(.caption).foregroundStyle(StudioStyle.supportingText)
                            TextField("Write the report prompt", text: Binding(
                                get: { workspace.selectedReportGroup?.prompts.first { $0.id == prompt.id }?.text ?? ""
                                },
                                set: { workspace.editReportPrompt(prompt.id, text: $0) }
                            ), axis: .vertical).lineLimit(2 ... 4)
                            if !prompt.heldOutAttributes.isEmpty {
                                Text("Not mentioned in the saved captions: " + prompt.heldOutAttributes
                                    .joined(separator: "; "))
                                    .font(.caption).foregroundStyle(StudioStyle.supportingText)
                            }
                        }
                    }.padding(.top, 8)
                }
                Text("Face similarity and bleed use SFace on this Mac. Style uses VGG19 Gram-feature cosine "
                    + "against up to eight frozen training examples; its first use downloads 548 MB on the GPU. "
                    + "The GPU captioner judges prompt adherence. Missing faces or unavailable metrics stay unscored.")
                    .font(.callout).foregroundStyle(StudioStyle.supportingText).fixedSize(
                        horizontal: false,
                        vertical: true
                    )
            } else {
                ProgressView("Preparing report prompts…")
            }
        }
        .disabled(workspace.isBusy || workspace.isTraining)
        .task(id: workspace.baseModel + (workspace.projectFolder?.path ?? "")) {
            do { try await workspace.prepareReportDraft() } catch { workspace.failure = error.localizedDescription }
        }
    }
}

struct TrainingReportResultsView: View {
    @Bindable var workspace: GPUWorkspace

    var body: some View {
        StudioSection(title: "Training reports", subtitle: "Compare runs within the same frozen prompt group.") {
            if workspace.trainingReports.isEmpty {
                Text("The next training run creates its report automatically after its checkpoint is saved.")
                    .foregroundStyle(StudioStyle.supportingText)
            }
            ForEach(workspace.reportGroups.filter { group in
                workspace.trainingReports.contains { $0.groupID == group.id }
            }) { group in
                let reports = workspace.trainingReports.filter { $0.groupID == group.id }
                Text(group.name).font(.headline)
                ScrollView(.horizontal) {
                    Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 12) {
                        GridRow {
                            Text("Metric").font(.headline)
                            ForEach(reports) { report in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(report.runID).font(.caption).textSelection(.enabled)
                                    Text(report.state.rawValue.capitalized).font(.caption)
                                }
                            }
                        }
                        metricRow(
                            "Face similarity ↑",
                            reports: reports,
                            group: group,
                            kind: .concept,
                            metric: \.identity
                        )
                        metricRow("Identity bleed ↓", reports: reports, group: group, kind: .bleed, metric: \.identity)
                        metricRow("Style similarity ↑", reports: reports, group: group, kind: .concept, metric: \.style)
                        metricRow("Prompt adherence ↑", reports: reports, group: group, kind: nil, metric: \.adherence)
                    }.padding(.vertical, 8)
                }
                Text("Values are means with scored/eligible sample counts. Cosine similarities and judge scores "
                    + "are separate measurements; they are not probabilities or one overall quality score.")
                    .font(.callout).foregroundStyle(StudioStyle.supportingText)
                ForEach(reports) { report in
                    if let failure = report.failure {
                        StudioNotice("\(report.runID): \(failure)")
                    }
                    if report.state == .failed || report.state == .waiting {
                        Button("Continue report for \(report.runID)") {
                            Task { await workspace.runTrainingReport(report.runID) }
                        }.disabled(workspace.isBusy || !workspace.hasRunningPod)
                    }
                }
                DisclosureGroup("Rendered outputs and individual scores") {
                    ForEach(group.prompts) { prompt in
                        ForEach(group.seeds, id: \.self) { seed in
                            promptComparisons(prompt, seed: seed, reports: reports)
                        }
                    }
                }
                Divider()
            }
        }
    }

    private func metricRow(
        _ title: String, reports: [TrainingReport], group: TrainingReportGroup,
        kind: ReportPrompt.Kind?, metric: KeyPath<ReportSample, ReportMetric?>
    ) -> some View {
        GridRow {
            Text(title)
            ForEach(reports) { report in
                let eligible = group.prompts.filter { prompt in
                    (kind == nil || prompt.kind == kind)
                        && (metric != \ReportSample.identity || prompt.category.isPersonIdentity)
                        && (metric != \ReportSample.style || prompt.category == .style)
                }
                let samples = report.samples.filter { sample in eligible.contains { $0.id == sample.promptID } }
                let total = eligible.count * group.seeds.count
                let values = samples.compactMap { $0[keyPath: metric]?.lora }
                let base = samples.compactMap { $0[keyPath: metric]?.base }
                VStack(alignment: .leading, spacing: 4) {
                    Text(total == 0 ? "Not applicable" : mean(values) + " (\(values.count)/\(total))").monospacedDigit()
                    Text("Base: " + mean(base) + " (\(base.count)/\(total))")
                        .font(.caption).foregroundStyle(StudioStyle.supportingText)
                }
            }
        }
    }

    private func mean(_ values: [Double]) -> String {
        values.isEmpty ? "—" : String(format: "%.3f", values.reduce(0, +) / Double(values.count))
    }

    private func promptComparisons(_ prompt: ReportPrompt, seed: Int, reports: [TrainingReport]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(prompt.text).textSelection(.enabled)
            Text("Seed \(seed)").font(.caption).foregroundStyle(StudioStyle.supportingText)
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(reports) { report in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(report.runID).font(.caption)
                            if let sample = report.samples
                                .first(where: { $0.promptID == prompt.id && $0.seed == seed }),
                               let comparison = workspace.generations
                                   .first(where: { $0.runID == sample.comparisonID }),
                               let url = workspace.comparisonFile(sample.loraPath, in: comparison) {
                                if url.pathExtension == "mp4" { GeneratedVideo(url: url) } else { PhotoView(url: url) }
                                ForEach(
                                    [sample.identity, sample.style, sample.adherence].compactMap(\.self).indices,
                                    id: \.self
                                ) { index in
                                    let metrics = [sample.identity, sample.style, sample.adherence].compactMap(\.self)
                                    if let note = metrics[index].note {
                                        Text(note).font(.caption).foregroundStyle(StudioStyle.supportingText)
                                    }
                                }
                            } else { Text("Waiting for this output.").foregroundStyle(StudioStyle.supportingText) }
                        }.frame(width: 240)
                    }
                }
            }
        }.padding(.vertical, 12)
    }
}
