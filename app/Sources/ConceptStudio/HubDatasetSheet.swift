import ConceptCore
import SwiftUI

struct HubDatasetSheet: View {
    var title = "Import a Hugging Face dataset"
    var actionTitle = "Download images or clips"
    let onChoose: (HubDatasetLocation) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var subfolder = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title2.bold())
            Text(
                "Paste a dataset URL, including a folder URL, or enter owner/dataset. "
                    + "Imports images, clips and captions."
            )
            .foregroundStyle(StudioStyle.supportingText)
            TextField("Dataset URL or owner/dataset", text: $input)
            TextField("Subfolder (optional)", text: $subfolder)
            Text("A subfolder entered here replaces the folder in the URL.")
                .font(.caption).foregroundStyle(StudioStyle.supportingText)
            if let errorMessage { Text(errorMessage).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(actionTitle) {
                    do {
                        let location = try HubDatasetLocation(input, subfolder: subfolder)
                        onChoose(location)
                        dismiss()
                    } catch { errorMessage = StudioSession.describe(error) }
                }
                .buttonStyle(.borderedProminent).tint(StudioStyle.actionTint)
                .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width: 520)
    }
}

struct NewHubProjectSheet: View {
    let session: StudioSession

    var body: some View {
        HubDatasetSheet(
            title: "New project from Hugging Face dataset",
            actionTitle: "Choose project location…"
        ) { location in
            if let url = ProjectAccess.chooseNewProject(
                preferences: session.preferences, name: location.suggestedProjectName
            ) {
                session.createProject(at: url, importing: location)
            }
        }
    }
}
