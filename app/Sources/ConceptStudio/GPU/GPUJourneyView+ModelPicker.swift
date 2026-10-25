import SwiftUI

extension GPUJourneyView {
    /// The picker and, for a model whose licence notice is on, the notice, a link to the licence and the size of the
    /// first download. All are direct children of the surrounding form, so a model without a notice lays out as a
    /// bare picker.
    @ViewBuilder var trainerPicker: some View {
        let options = workspace.trainingModelOptions(advancedUser: session.advancedUser)
        Picker("Training model", selection: Binding<String?>(
            get: { options.contains { $0.tag == workspace.baseModel } ? workspace.baseModel : nil },
            set: { if let model = $0 { workspace.chooseTrainingModel(model) } }
        )) {
            if !options.contains(where: { $0.tag == workspace.baseModel }) {
                Text("Choose a verified recipe").tag(String?.none)
            }
            ForEach(options, id: \.tag) { option in
                Text(option.label).tag(Optional(option.tag))
            }
        }
        .disabled(workspace.isBusy || workspace.isTraining)
        let pairings = workspace.modelTable.pairings(modelRef: workspace.baseModel)
        if pairings.count > 1 {
            Picker("Trainer", selection: Binding(
                get: { workspace.trainer },
                set: { workspace.chooseTrainingTrainer($0) }
            )) {
                ForEach(pairings, id: \.trainer) { row in
                    Text(trainerTitle(row.trainer) + (row.recipeStatus == .unverified ? " · Unverified recipe" : ""))
                        .tag(row.trainer)
                }
            }
            .disabled(workspace.isBusy || workspace.isTraining)
        }
        if let row = workspace.exactModelRow, row.recipeStatus == .unverified {
            StudioNotice(
                "Unverified recipe. This model and trainer pairing has not completed an in-app comparison. "
                    + (row.trainingNotice ?? ""),
                symbol: "exclamationmark.triangle"
            )
        }
        if let disclosure = workspace.trainingModelDisclosure {
            Text(disclosure.notice).font(.callout).foregroundStyle(StudioStyle.supportingText)
                .fixedSize(horizontal: false, vertical: true)
            if let link = URL(string: disclosure.licenseURL) {
                Link(disclosure.licenseName, destination: link).font(.callout)
            }
            Text(disclosure.download).font(.callout).foregroundStyle(StudioStyle.supportingText)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let note = workspace.exactModelRow?.usageNote {
            Text(note).font(.callout).foregroundStyle(StudioStyle.supportingText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func trainerTitle(_ trainer: String) -> String {
        switch trainer {
        case "aitoolkit": "AI Toolkit"
        case "musubi": "musubi-tuner"
        case "ltx": "LTX trainer"
        default: trainer
        }
    }
}
