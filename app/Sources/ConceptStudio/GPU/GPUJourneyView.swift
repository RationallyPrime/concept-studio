import AppKit
import Charts
import SwiftUI

enum MonitorTab: String, CaseIterable, Identifiable {
    case progress = "Progress"
    case tensorBoard = "TensorBoard"
    case log = "Training log"
    case results = "Generated results"
    case runs = "Saved runs"

    var id: Self {
        self
    }
}

struct GPUJourneyView: View {
    let session: StudioSession
    @Bindable var workspace: GPUWorkspace
    let step: StudioStep
    /// The journey footer already shows spend and Stop everything; the Welcome sheet does not.
    var showsSpendControls = true
    @State var confirmTermination = false
    @State var confirmDiscardingTermination = false
    @State var newBudget: Double?
    @State var keptToStart: String?
    @State var keptToRemove: String?

    init(session: StudioSession, step: StudioStep, showsSpendControls: Bool = true) {
        self.session = session
        workspace = session.gpu
        self.step = step
        self.showsSpendControls = showsSpendControls
    }

    var datasetRepo: String {
        session.repoID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            status
            if workspace.demoMode {
                StudioNotice(
                    "Demo cloud GPU and prices. No cloud GPU is rented and there are no charges.",
                    symbol: "leaf"
                )
            }
            switch step {
            case .pods: ScrollView { pods.padding(.bottom, 12) }
            case .training: ScrollView { training.padding(.bottom, 12) }
            case .monitor: monitor
            default: EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { if workspace.offers.isEmpty { await workspace.refreshOffers() } }
        .confirmationDialog("Stop the running GPU and start this kept GPU?", isPresented: Binding(
            get: { keptToStart != nil }, set: { if !$0 { keptToStart = nil } }
        )) {
            Button("Switch cloud GPU") {
                if let id = keptToStart { Task { await workspace.startKeptPod(id: id) } }
            }
        } message: { Text("The running GPU will stop first. Its files and storage are kept.") }
        .confirmationDialog("Remove this kept GPU and delete its disk?", isPresented: Binding(
            get: { keptToRemove != nil }, set: { if !$0 { keptToRemove = nil } }
        )) {
            Button("Remove and delete disk", role: .destructive) {
                if let id = keptToRemove { Task { await workspace.removeKeptPod(id: id) } }
            }
        } message: {
            Text(
                "All model caches, datasets and unsaved outputs on this disk will be deleted. "
                    + "Separate saved storage remains."
            )
        }
        .confirmationDialog("Permanently remove this cloud GPU?", isPresented: $confirmTermination) {
            Button("Remove cloud GPU", role: .destructive) { Task { await workspace.terminate() } }
        } message: {
            Text(
                "Removing deletes this cloud GPU and its disk. Separate saved storage remains. "
                    + workspace.outputCustodyExplanation
            )
        }
        .confirmationDialog(
            "Remove this cloud GPU and delete its unsaved outputs?",
            isPresented: $confirmDiscardingTermination
        ) {
            Button("Remove and delete outputs", role: .destructive) {
                Task { await workspace.terminate(discardingUndeliveredOutputs: true) }
            }
        } message: {
            Text("These are only on this cloud GPU's disk and cannot be recovered after removal: "
                + workspace.undeliveredPodOutputs.joined(separator: ", ") + ".")
        }
    }

    // MARK: Training

    private var training: some View {
        VStack(alignment: .leading, spacing: StudioStyle.contentSpacing) {
            StudioSection(title: "Your training plan", paper: true) {
                Text(session.trainingPlanExplanation)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 0) {
                    receiptRow(
                        "Training model",
                        workspace.trainingModelOptions(advancedUser: session.advancedUser)
                            .first { $0.tag == workspace.baseModel }?.label ?? workspace.baseModel
                    )
                    receiptRow(
                        workspace.usesLocalDataset ? "Training inputs" : "Published dataset",
                        workspace.usesLocalDataset ? "Included media and saved captions in this project"
                            : trainingDatasetRepo.isEmpty
                            ? "Publish your training media first" : trainingDatasetRepo
                    )
                    receiptRow(
                        workspace.usesLocalDataset ? "Transfer" : "Published revision",
                        workspace.usesLocalDataset ? "Direct authenticated upload when training starts"
                            : trainingDatasetRevision ?? "Latest revision on first download"
                    )
                    receiptRow(workspace.trainingLengthLabel, "\(workspace.steps)")
                    receiptRow("Spending limit", StudioMoney.format(workspace.activeBudget ?? workspace.budget))
                }
                Text(workspace.usesLocalDataset
                    ? "Training uploads the included media, selected segments and saved captions "
                    + "directly from this project."
                    : "Training downloads this published dataset. Publish again after changing included media, crops, "
                    + "segments or captions on this Mac.")
                    .font(.callout).foregroundStyle(StudioStyle.supportingText)
                Button("Refresh the plan") { Task { await workspace.refresh() } }
            }
            Divider()
            StudioSection(
                title: "What to train",
                subtitle: "Some models require you to accept their license in your Hugging Face account first."
            ) {
                Form {
                    trainerPicker
                    if session.advancedUser {
                        TextField("Starting model", text: $workspace.baseModel)
                            .help("Base diffusion model to train. Choose a compatible model for these images or clips.")
                            .disabled(workspace.isBusy || workspace.isTraining)
                    }
                    trainingDestinationFields
                }.formStyle(.columns)
                Text("This project's own destination. With a Hugging Face token in Settings and a Secure Cloud "
                    + "GPU, the trained model is published to this repository when training finishes. Without a "
                    + "token, or on a Community Cloud GPU, it is saved in this project's results folder on your Mac.")
                    .font(.callout).foregroundStyle(StudioStyle.supportingText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .task(id: session.project?.directory) { await session.fillDefaultTrainingOutput() }
            Divider()
            TrainingInitializationView(workspace: workspace)
            Divider()
            TrainingAidsView(session: session, workspace: workspace)
            ReportPlanView(workspace: workspace)
            Divider()
            StudioSection(title: "Run settings", subtitle: workspace.trainingLengthSubtitle) {
                Form {
                    TextField(workspace.trainingLengthLabel, value: $workspace.steps, format: .number.grouping(.never))
                        .help(workspace.trainingLengthHelp)
                        .disabled(workspace.isBusy || workspace.isTraining)
                }.formStyle(.columns)
                TrainingBudgetView(session: session, workspace: workspace)
                prerequisitesNotice(beforeBilling: false)
                if !session.advancedUser {
                    let overrides = workspace.advancedTrainingOverrides + workspace.advancedInputOverrides(
                        expectedTriggers: (session.project?.job.concepts ?? []).map(\.trigger).joined(separator: ","),
                        expectedProfile: session.project?.job.profile ?? workspace.effectiveModelRow.captions
                            .imageProfile
                    )
                    if !overrides.isEmpty {
                        StudioNotice("Advanced settings still in force: " + overrides.joined(separator: "; ")
                            + ". Turn on Advanced user to edit them.")
                    }
                }
                if session.advancedUser {
                    DisclosureGroup("Advanced training controls") {
                        AdvancedTrainingControls(workspace: workspace).padding(.top, 12)
                            .disabled(workspace.isBusy || workspace.isTraining)
                    }
                }
                Button("Start training", systemImage: "play.fill") {
                    Task {
                        await session.fillDefaultTrainingOutput()
                        await workspace.train(
                            datasetRepo: datasetRepo, output: session.trainingOutput,
                            captureLocal: session.captureTrainingInputs,
                            regularizationCaptioning: session.regularizationCaptioning
                        )
                    }
                }
                .buttonStyle(.borderedProminent).tint(StudioStyle.actionTint)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Start training (⌘↩)")
                .disabled(workspace.isBusy || workspace.isTraining || !workspace
                    .hasRunningPod || session.busy || session
                    .editing || (!workspace.usesLocalDataset && trainingDatasetRepo.isEmpty))
            }
            if !workspace.repeatSourceRunID.isEmpty {
                StudioNotice(repeatNotice)
                Button("Use this project's current dataset instead") {
                    session.useCurrentTrainingDataset()
                }
            }
            Divider()
            RunHistoryView(session: session, workspace: workspace)
        }
    }

    // MARK: Monitor

    /// Each tab gets the full height below the picker; nothing scrolls inside another scroll view.
    private var monitor: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ViewThatFits(in: .horizontal) {
                    monitorPicker.pickerStyle(.segmented).labelsHidden().fixedSize()
                    monitorPicker.pickerStyle(.menu).frame(maxWidth: 240)
                }
                Spacer(minLength: 0)
                Button("Refresh progress", systemImage: "arrow.clockwise") { Task { await workspace.refresh() } }
                    .disabled(workspace.isBusy || workspace.isStopping)
                    .keyboardShortcut("r", modifiers: .command)
            }
            switch session.monitorTab {
            case .progress: ScrollView { progress.padding(.bottom, 12) }
            case .tensorBoard: tensorBoard.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            case .log: log
            case .results: ScrollView { GenerationView(workspace: workspace).padding(.bottom, 12) }
            case .runs: ScrollView { RunHistoryView(session: session, workspace: workspace).padding(.bottom, 12) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var monitorPicker: some View {
        Picker("Monitor", selection: Bindable(session).monitorTab) {
            ForEach(MonitorTab.allCases) { Text($0.rawValue).tag($0) }
        }
    }

    @ViewBuilder private var tensorBoard: some View {
        if workspace.demoMode {
            ContentUnavailableView(
                "TensorBoard connects to a real training run",
                systemImage: "chart.xyaxis.line",
                description: Text("The offline demo uses the Progress tab. No training server is contacted.")
            )
        } else if !workspace.hasRunningPod || workspace.tensorBoardURL == nil {
            ContentUnavailableView(
                "No running cloud GPU",
                systemImage: "server.rack",
                description: Text("Rent a cloud GPU and start training to view its detailed TensorBoard charts.")
            )
        } else if let url = workspace.tensorBoardURL {
            TensorBoardView(url: url, token: workspace.agentToken)
        }
    }

    private var log: some View {
        ScrollView {
            Text(workspace.logs.isEmpty ? "Training logs will appear here as the run progresses." : workspace.logs)
                .font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
        }
        .defaultScrollAnchor(.top, for: .alignment)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(InstantPrint.paper, in: RoundedRectangle(cornerRadius: 6))
        .environment(\.colorScheme, .light)
        .accessibilityLabel("Training log")
    }
}

extension GPUJourneyView {
    private var progress: some View {
        VStack(alignment: .leading, spacing: StudioStyle.contentSpacing) {
            StudioSection(title: "Learning curve") {
                if workspace.runID.isEmpty, let run = workspace.monitoredRun {
                    Text("Most recent saved run · " + run.startedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.callout).foregroundStyle(StudioStyle.supportingText)
                }
                if workspace.curveDisplay != .available {
                    ContentUnavailableView(
                        workspace.curveDisplay.title,
                        systemImage: "chart.xyaxis.line",
                        description: Text(workspace.curveDisplay.explanation)
                    )
                    if workspace.curveDisplay == .noRun {
                        Button("Go to Training") { session.step = .training }
                    } else if workspace.curveDisplay == .waiting {
                        if let drawing = workspace.regularizationProgress {
                            ProgressView(value: Double(drawing.ready), total: Double(drawing.planned)) {
                                Text(drawing.text)
                            }.controlSize(.small)
                        } else {
                            ProgressView("Waiting for a training measurement").controlSize(.small)
                        }
                    }
                } else {
                    Chart(workspace.monitoredPoints) { point in
                        LineMark(x: .value("Training step", point.step), y: .value("Training loss", point.loss))
                            .foregroundStyle(StudioStyle.accent)
                    }
                    .chartXAxisLabel("Training step").chartYAxisLabel("Loss")
                    .frame(minHeight: 200, idealHeight: 260)
                    Text(workspace.curveDisplay.explanation)
                        .font(.callout).foregroundStyle(StudioStyle.supportingText)
                }
            }
            Divider()
            TrainingResultSection(state: workspace.monitoredResultState, busy: workspace.isBusy) {
                Task { await workspace.retrieveResult() }
            }
        }
    }
}

struct TrainingResultSection: View {
    let state: TrainingResult.State?
    let busy: Bool
    let retrieve: () -> Void

    var body: some View {
        StudioSection(title: "Your trained model") {
            switch state {
            case nil, .training?:
                Text("When training finishes, the model is uploaded to your Hugging Face repository, or saved in "
                    + "this project's results folder if you have no Hugging Face token.")
                    .foregroundStyle(StudioStyle.supportingText).fixedSize(horizontal: false, vertical: true)
            case .pending?:
                StudioNotice(
                    "The trained model is still only on the cloud GPU's storage. Retrieve it before you "
                        + "stop the cloud GPU.",
                    symbol: "exclamationmark.triangle"
                )
                HStack(spacing: 12) {
                    Button("Retrieve now", systemImage: "arrow.down.circle", action: retrieve)
                        .buttonStyle(.borderedProminent).tint(StudioStyle.actionTint)
                        .keyboardShortcut(.return, modifiers: .command)
                        .help("Retrieve the trained model (⌘↩)")
                        .disabled(busy)
                    if busy { ProgressView().controlSize(.small) }
                }
            case let .pushed(repo)?:
                Label("Published to \(repo)", systemImage: "checkmark.circle").font(.headline)
                if let url = URL(string: "https://huggingface.co/\(repo)") {
                    Link("Open on Hugging Face", destination: url)
                }
            case let .saved(folder)?:
                let url = URL(fileURLWithPath: folder, isDirectory: true)
                Label("Saved to \(url.lastPathComponent)", systemImage: "checkmark.circle").font(.headline)
                    .help(folder)
                Text(folder).font(.callout).foregroundStyle(StudioStyle.supportingText).textSelection(.enabled)
                    .lineLimit(2).truncationMode(.middle)
                Button("Reveal in Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            case .failed?:
                Label(
                    "The run ended without a trained model. Read the training log for the cause.",
                    systemImage: "exclamationmark.triangle"
                )
            }
        }
    }
}

extension StudioSession {
    /// Stop everything, warning first when a trained model has been neither pushed nor saved.
    func requestStopEverything() {
        Task {
            var discardingPendingResult = false
            if gpu.resultNeedsSaving {
                switch await ask(.stopWithPendingResult) {
                case .confirm:
                    await gpu.retrieveResult()
                    guard !gpu.resultNeedsSaving else { return }
                case .alternate: discardingPendingResult = true
                case .cancel: return
                }
            }
            await leaveComputerRunning()
            await gpu.stopEverything(discardingPendingResult: discardingPendingResult)
        }
    }
}

extension GPUJourneyView {
    /// Inline status: progress and recoverable states. Blocking failures go to the window alert.
    private var status: some View {
        HStack(alignment: .center, spacing: 16) {
            statusChip("Cloud GPU", workspace.computerStatus)
            if step == .training || step == .monitor {
                statusChip("Training", workspace.trainingStatus)
            }
            Text(workspace.failure == workspace.message ? "" : workspace.message).font(.callout)
                .foregroundStyle(StudioStyle.supportingText)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            Spacer(minLength: 0)
            if workspace.isBusy || workspace.isStopping { ProgressView().controlSize(.small) }
            if showsSpendControls, workspace.hasRunningPod {
                Text("GPU spend · \(StudioMoney.format(workspace.elapsedCost))")
                    .font(.headline).monospacedDigit()
                Button(workspace.isStopping ? "Stopping…" : "Stop everything", systemImage: "stop.circle") {
                    session.requestStopEverything()
                }.disabled(workspace.isStopping)
            }
        }
    }

    private func statusChip(_ title: String, _ value: String) -> some View {
        HStack(spacing: 7) {
            Text(title).font(.system(size: 13.5, weight: .semibold))
            PrintStateChip(state: .other(value)).environment(\.colorScheme, .light)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value)")
    }
}
