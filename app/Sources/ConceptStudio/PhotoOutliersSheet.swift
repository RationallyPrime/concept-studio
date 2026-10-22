import ConceptCore
import SwiftUI

struct PhotoOutliersSheet: View {
    @Bindable var session: StudioSession
    @Environment(\.dismiss) private var dismiss
    @State private var suggestions: [PhotoOutlier] = []
    @State private var selected: Set<String> = []
    @State private var loading = true
    @State private var confirm = false
    @State private var error = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Bring outliers into line").font(.title2.bold())
            Text(
                "Review photos whose exposure or colour stands apart from this dataset. "
                    + "Each correction is specific to its photo; the rest of the set stays unchanged."
            )
            .fixedSize(horizontal: false, vertical: true)
            if loading {
                ProgressView("Measuring included photos on this Mac…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if suggestions.isEmpty {
                ContentUnavailableView(
                    "No colour or exposure outliers", systemImage: "checkmark.circle",
                    description: Text(error
                        .isEmpty ? "The scan needs at least four included photos. Ordinary variation is kept." : error)
                ).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(suggestions) { suggestion in
                            if let image = session.project?.images.first(where: { $0.id == suggestion.id }) {
                                VStack(alignment: .leading, spacing: 8) {
                                    Toggle(isOn: Binding(
                                        get: { selected.contains(suggestion.id) },
                                        set: {
                                            if $0 {
                                                selected.insert(suggestion.id)
                                            } else {
                                                selected.remove(suggestion.id)
                                            }
                                        }
                                    )) {
                                        Text("\(suggestion.id) · \(suggestion.reason)").fontWeight(.medium)
                                    }.toggleStyle(.checkbox)
                                    HStack(spacing: 16) {
                                        VStack {
                                            TrainingTargetPreview(url: image.url).frame(width: 300, height: 210)
                                            Text("Current photo").font(.caption)
                                        }
                                        OutlierPreview(project: session.project, image: image, suggestion: suggestion)
                                    }
                                    Text("Exposure " + suggestion.exposure
                                        .formatted(.number.precision(.fractionLength(2))) + " EV · original retained")
                                        .font(.caption).foregroundStyle(StudioStyle.supportingText)
                                    Divider()
                                }
                            }
                        }
                    }
                }
            }
            Divider()
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Apply to \(selected.count) photos") { confirm = true }
                    .buttonStyle(.borderedProminent).tint(StudioStyle.actionTint)
                    .disabled(selected.isEmpty || loading || session.busy)
            }
        }
        .padding(24).frame(width: 720, height: 650)
        .task {
            do {
                let images = (session.project?.images ?? []).filter { !Sources.isVideo(Sources.suffix(of: $0.id)) }
                suggestions = try await Task.detached {
                    var values: [String: PhotoStatistics] = [:]
                    for image in images {
                        try Task.checkCancellation()
                        values[image.id] = try PhotoEditing
                            .statistics(MediaEditor.orientedImage(Data(contentsOf: image.url)))
                    }
                    return PhotoOutliers.suggestions(values)
                }.value
                selected = Set(suggestions.map(\.id))
            } catch { self.error = error.localizedDescription }
            loading = false
        }
        .alert("Apply these photo corrections and reset their captions?", isPresented: $confirm) {
            Button("Keep reviewing", role: .cancel) {}
            Button("Apply corrections") {
                session.applyPhotoOutliers(suggestions.filter { selected.contains($0.id) })
                dismiss()
            }
        } message: {
            Text(
                "Only selected photos change. Their originals stay in the project; "
                    + "captions and subject mappings are reset for review."
            )
        }
    }
}

private struct OutlierPreview: View {
    let project: StudioProject?
    let image: ProjectImage
    let suggestion: PhotoOutlier
    @State private var preview: CGImage?
    @State private var error = ""

    var body: some View {
        VStack {
            Group {
                if let preview {
                    Image(decorative: preview, scale: 1).resizable().scaledToFit()
                } else if !error.isEmpty {
                    Label(error, systemImage: "exclamationmark.triangle").font(.callout)
                } else {
                    ProgressView("Preparing preview…")
                }
            }.frame(width: 300, height: 210)
            Text("Proposed correction").font(.caption)
        }.task {
            do {
                let source = try project?.photoEditSource(for: image) ?? image.url
                let settings = suggestion
                    .applying(to: project?.mediaState.selections[image.id]?.photoEdit?
                        .adjustments ?? PhotoAdjustments())
                preview = try await Task.detached {
                    try PhotoEditing.render(MediaEditor.orientedImage(Data(contentsOf: source)), adjustments: settings)
                }.value
            } catch { self.error = error.localizedDescription }
        }
    }
}
