import SwiftUI

extension GPUJourneyView {
    // MARK: Cloud GPU

    var pods: some View {
        VStack(alignment: .leading, spacing: StudioStyle.contentSpacing) {
            StudioSection(
                title: "Choose a cloud GPU",
                subtitle: workspace.computerSubtitle
            ) {
                Form {
                    Picker("Use this GPU for", selection: $workspace.rentsCaptionServer) {
                        Text("Captioning").tag(true)
                        Text("Training").tag(false)
                    }
                    .disabled(workspace.hasRunningPod || workspace.isBusy)
                    if workspace.rentsCaptionServer {
                        TextField("Caption model", text: $workspace.captionModel)
                        TextField("Minimum model memory (GB)", value: $workspace.captionMemoryGB, format: .number)
                            .help(
                                "32 GB is the measured recipe for Qwen3-VL-8B. "
                                    + "Set the requirement for a custom model here."
                            )
                    } else {
                        trainerPicker
                    }
                    Picker("Number of GPUs", selection: $workspace.gpuCount) {
                        ForEach([1, 2, 4], id: \.self) { Text("\($0)").tag($0) }
                    }
                    .disabled(workspace.hasRunningPod || workspace.isBusy)
                    .onChange(of: workspace.gpuCount) { _, _ in Task { await workspace.refreshOffers() } }
                    Text(workspace.gpuCount == 1
                        ? "Captioning and training share this GPU, one after the other."
                        : "One GPU captions while the others train.")
                        .font(.callout).foregroundStyle(StudioStyle.supportingText)
                }.formStyle(.columns)
                CloudGPUList(workspace: workspace)
                Button("Refresh prices and availability") { Task { await workspace.refreshOffers() } }
                    .disabled(workspace.isBusy)
            }
            Divider()
            StudioSection(
                title: "Training storage",
                subtitle: "Your training files (the base model, your images and the trained result) live on "
                    + "RunPod while you train. Keep them on the cloud GPU's own disk, or on saved storage you can "
                    + "reuse with any cloud GPU in the same data centre. RunPod bills storage directly to your "
                    + "RunPod account, including while the cloud GPU is stopped."
            ) {
                Form {
                    Picker("Storage", selection: Binding(
                        get: { workspace.selectedVolume },
                        set: { workspace.chooseStorage($0) }
                    )) {
                        Text("The cloud GPU's own disk · 300 GB").tag("")
                        ForEach(workspace.volumes) { volume in
                            Text("\(volume.name) · \(volume.size) GB · \(volume.dataCenter)").tag(volume.id)
                        }
                    }
                    .disabled(workspace.hasRunningPod)
                    .onChange(of: workspace.selectedVolume) { _, _ in workspace.selectAvailableOffer() }
                }.formStyle(.columns)
                if workspace.selectedVolume.isEmpty, !workspace.hasRunningPod {
                    Text("The disk comes with the cloud GPU. Stopping the cloud GPU keeps your files; removing it "
                        + "deletes them. When training finishes, the trained model is published to your Hugging Face "
                        + "account if you chose a destination there and a Secure Cloud GPU, or saved to your Mac.")
                        .font(.callout).foregroundStyle(StudioStyle.supportingText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let volume = workspace.volumes.first(where: { $0.id == workspace.selectedVolume }) {
                    Text("Only cloud GPUs in \(volume.dataCenter), where this storage lives, can use it.")
                        .font(.callout).foregroundStyle(StudioStyle.supportingText)
                }
                if workspace.volumes.isEmpty, !workspace.demoMode,
                   let url = URL(string: "https://console.runpod.io/storage") {
                    Link("Create saved storage in RunPod", destination: url)
                }
                if workspace.hasRunningPod {
                    if let storage = workspace.storage {
                        if storage.workspaceScoped == true {
                            LabeledContent("Workspace used", value: bytes(storage.usedBytes))
                        } else {
                            Text("This pod image reports shared-host usage. Update its image to see workspace usage.")
                                .font(.callout).foregroundStyle(StudioStyle.supportingText)
                        }
                        if storage.workspaceScoped == true, storage.totalBytes > 0 {
                            LabeledContent("Workspace free", value: bytes(storage.freeBytes))
                            LabeledContent("Workspace total", value: bytes(storage.totalBytes))
                        }
                        LabeledContent("Dataset copies", value: bytes(storage.datasetsBytes))
                        LabeledContent("Eligible dataset cleanup", value: bytes(storage.reclaimableDatasetBytes))
                    }
                    HStack {
                        Button("Refresh storage usage") { Task { await workspace.refreshStorage() } }
                        Button("Clean completed dataset copies") { Task { await workspace.cleanupDatasets() } }
                    }.disabled(workspace.isBusy || workspace.isStopping)
                    Text("Cleanup keeps active inputs and the last three resumable datasets. "
                        + "Checkpoints, models, generated results and unknown or failed runs stay on storage.")
                        .font(.caption).foregroundStyle(StudioStyle.supportingText)
                }
            }
            Divider()
            spending
            if !workspace.keptPods.isEmpty {
                Divider()
                keptComputers
            }
        }
    }

    private var keptComputers: some View {
        StudioSection(
            title: "Stopped, kept",
            subtitle: "Your cached models and files stay here while you use another GPU."
        ) {
            ForEach(workspace.keptPods, id: \.pod.id) { kept in
                VStack(alignment: .leading, spacing: 6) {
                    Text(kept.pod.name ?? kept.pod.id).font(.headline)
                    Text(workspace.keptContents(kept)).font(.callout)
                    Text(workspace.keptStorageCost(kept)).font(.callout).foregroundStyle(StudioStyle.supportingText)
                    HStack {
                        Button("Start") {
                            if workspace.hasRunningPod {
                                keptToStart = kept.pod.id
                            } else { Task { await workspace.startKeptPod(id: kept.pod.id) } }
                        }
                        Button("Remove…", role: .destructive) { keptToRemove = kept.pod.id }
                    }.disabled(workspace.isBusy || workspace.isStopping)
                }.padding(.vertical, 8)
            }
        }
    }

    private func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    private var spending: some View {
        StudioSection(
            title: "Control your spending",
            subtitle: "All charges are RunPod's, billed to your RunPod account. ConceptStudio doesn't charge you "
                + "anything. While a cloud GPU runs, ConceptStudio keeps your Mac awake and stops the GPU at your "
                + "spending limit or when it sits idle."
        ) {
            Form {
                if workspace.quotedHourlyRate > 0 || workspace.hasRunningPod {
                    LabeledContent("Price") {
                        Text(StudioMoney.perHour(workspace.hasRunningPod
                                ? workspace.pod?.cost ?? workspace.quotedHourlyRate
                                : workspace.quotedHourlyRate))
                            .font(.headline).monospacedDigit()
                    }
                }
                if workspace.hasRunningPod {
                    LabeledContent("Spending limit") {
                        Text(StudioMoney.format(workspace.activeBudget ?? workspace.budget)).monospacedDigit()
                    }
                    TextField("Raise the limit to (USD)", value: $newBudget, format: .number)
                } else {
                    TextField("Spending limit (USD)", value: $workspace.budget, format: .number)
                }
                TextField("Stop after idle minutes", value: Binding(
                    get: { workspace.idleMinutes },
                    set: { workspace.idleMinutes = max(1, $0) }
                ), format: .number.grouping(.never))
            }.formStyle(.columns)
            if workspace.hasRunningPod {
                Button("Raise spending limit…") { raiseBudget() }
                    .disabled((newBudget ?? 0) <= (workspace.activeBudget ?? workspace.budget))
                    .help("The limit can only go up while the cloud GPU runs. You confirm the new amount first.")
            } else if workspace.quotedHourlyRate <= 0 {
                Text("Choose an available cloud GPU to see its price.")
                    .font(.callout).foregroundStyle(StudioStyle.supportingText)
            }
            if !workspace.hasRunningPod, !workspace.rentsCaptionServer { prerequisitesNotice(beforeBilling: true) }
            Button(workspace.quotedHourlyRate > 0
                ? "Rent cloud GPU · \(StudioMoney.perHour(workspace.quotedHourlyRate))"
                : "Choose a cloud GPU first") {
                    Task { await workspace.rent() }
                }
                .buttonStyle(.borderedProminent).tint(StudioStyle.actionTint)
                .disabled(workspace.isBusy || workspace.hasRunningPod || workspace.quotedHourlyRate <= 0)
                .help("Renting starts GPU billing, so it has no keyboard shortcut.")
            if workspace.pod != nil {
                if !workspace.hasRunningPod {
                    Button("Start this stopped cloud GPU · last rate "
                        + StudioMoney.perHour(workspace.saved?.hourlyRate ?? 0)) {
                            Task { await workspace.startStoppedComputer() }
                        }.disabled(workspace.isBusy)
                    Text(workspace.outputCustodyExplanation)
                        .font(.callout).foregroundStyle(StudioStyle.supportingText)
                }
                if workspace.hasUndeliveredPodOutputs, !workspace.hasRunningPod {
                    Text("Unsaved outputs keep this cloud GPU from being removed. "
                        + workspace.stoppedPodDiskCostExplanation)
                        .font(.callout).foregroundStyle(StudioStyle.supportingText)
                    Button("Remove anyway and delete these outputs…", role: .destructive) {
                        confirmDiscardingTermination = true
                    }
                    .disabled(workspace.isBusy)
                    .help("Deletes the cloud GPU's disk with the outputs that were never published or saved.")
                } else {
                    Button(
                        "Remove cloud GPU…",
                        role: .destructive
                    ) { confirmTermination = true }
                        .disabled(workspace.hasUndeliveredPodOutputs)
                        .help("Publish or save outputs from the cloud GPU's disk before removing it.")
                }
            }
        }
    }

    private func raiseBudget() {
        let current = workspace.activeBudget ?? workspace.budget
        guard let target = newBudget, target > current else { return }
        Task {
            let rate = workspace.pod.map(\.cost).flatMap { $0 > 0 ? $0 : nil }
            guard await session.ask(.raiseBudget(from: current, to: target, hourlyRate: rate)) == .confirm
            else { return }
            if workspace.raiseBudget(to: target) { newBudget = nil }
        }
    }
}
