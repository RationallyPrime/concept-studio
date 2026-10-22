import SwiftUI

/// The cloud GPU list under "Choose a cloud GPU". GPUs that can't be rented now stay listed, greyed,
/// with the reason in place of their stock; choosing a row selects the GPU to rent.
struct CloudGPUList: View {
    @Bindable var workspace: GPUWorkspace
    @State private var sortOrder = [KeyPathComparator(\GPUChoice.hourlyPrice)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 20) { filters }
                VStack(alignment: .leading, spacing: 8) { filters }
            }
            Text("Community Cloud GPUs run on independent hosts, so ConceptStudio keeps your Hugging Face token "
                + "off them and saves the trained model to your Mac instead of publishing it.")
                .font(.callout).foregroundStyle(StudioStyle.supportingText)
                .fixedSize(horizontal: false, vertical: true)
            list
        }
        .disabled(workspace.hasRunningPod)
    }

    @ViewBuilder private var filters: some View {
        Toggle("In stock only", isOn: $workspace.inStockOnly)
        Picker("Minimum graphics memory", selection: $workspace.minimumMemoryFilter) {
            ForEach(workspace.memoryFilterChoices, id: \.self) { size in
                Text(size == 0 ? "Any" : "\(size) GB").tag(size)
            }
        }
        .fixedSize()
        Toggle("Include Community Cloud (cheaper, less reliable)", isOn: $workspace.includeCommunityCloud)
            .help("Community Cloud GPUs run on independent hosts' machines. They cost less but can be less "
                + "reliable, and saved storage can't be used with them.")
    }

    private var list: some View {
        let choices = workspace.gpuChoices(sortedBy: sortOrder)
        return Table(choices, selection: selection, sortOrder: $sortOrder) {
            TableColumn("GPU", value: \.label) { choice in
                Text(choice.label).foregroundStyle(ink(choice)).selectionDisabled(!choice.isSelectable)
            }
            .width(min: 150, ideal: 210)
            TableColumn("Graphics memory", value: \.memory) { choice in
                Text("\(choice.memory) GB").monospacedDigit().foregroundStyle(ink(choice))
                    .selectionDisabled(!choice.isSelectable)
            }
            .width(min: 90, ideal: 110)
            TableColumn(priceTitle, value: \.hourlyPrice) { choice in
                Text(StudioMoney.perHour(choice.hourlyPrice)).monospacedDigit().foregroundStyle(ink(choice))
                    .selectionDisabled(!choice.isSelectable)
            }
            .width(min: 90, ideal: 120)
            TableColumn("Availability", value: \.stock) { choice in
                Text(choice.availabilityText).foregroundStyle(ink(choice)).help(choice.availabilityText)
                    .selectionDisabled(!choice.isSelectable)
            }
            .width(min: 140, ideal: 280)
        }
        .frame(height: 280)
        .overlay {
            if choices.isEmpty {
                Text(workspace.offers.isEmpty
                    ? "Refresh to see cloud GPUs and their prices."
                    : "No cloud GPUs match these filters.")
                    .foregroundStyle(StudioStyle.supportingText)
            }
        }
        .accessibilityLabel("Cloud GPUs")
    }

    private var priceTitle: String {
        workspace.gpuCount == 1 ? "Price per hour" : "Price per hour, \(workspace.gpuCount) GPUs"
    }

    /// Only a GPU that can be rented now can be selected.
    private var selection: Binding<String?> {
        Binding(
            get: { workspace.selectedGPU.isEmpty ? nil : workspace.selectedGPU },
            set: { id in
                if let id, workspace.availableOffers.contains(where: { $0.id == id }) { workspace.selectedGPU = id }
            }
        )
    }

    private func ink(_ choice: GPUChoice) -> Color {
        choice.isSelectable ? .primary : .secondary
    }
}
