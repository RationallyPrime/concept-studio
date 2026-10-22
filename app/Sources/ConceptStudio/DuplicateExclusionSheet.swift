import SwiftUI

struct DuplicateExclusionSheet: View {
    let session: StudioSession
    let groups: [[ProjectImage]]
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Set<String>

    init(session: StudioSession, groups: [[ProjectImage]]) {
        self.session = session
        self.groups = groups
        _selection = State(initialValue: DuplicateCuration.recommendedExclusions(
            groups: groups, analyses: session.analyses
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Exclude duplicates").font(.title2.bold())
            Text(
                "Keep the best of each group: the highest-resolution copy stays included. Check the copies to exclude."
            )
            .foregroundStyle(StudioStyle.supportingText)
            Button("Keep the best of each group") {
                selection = DuplicateCuration.recommendedExclusions(groups: groups, analyses: session.analyses)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(groups, id: \.first?.id) { group in
                        ScrollView(.horizontal) {
                            HStack(alignment: .top, spacing: 16) {
                                ForEach(group) { image in
                                    VStack(alignment: .leading, spacing: 8) {
                                        TrainingTargetPreview(url: image.url).frame(width: 150, height: 110)
                                        Text(image.id).font(.caption).lineLimit(1).help(image.id)
                                        if let analysis = session.analyses[image.id] {
                                            Text("\(analysis.width) × \(analysis.height)").font(.caption)
                                        }
                                        Toggle("Exclude", isOn: Binding(
                                            get: { selection.contains(image.id) },
                                            set: {
                                                if $0 { selection.insert(image.id) } else { selection.remove(image.id) }
                                            }
                                        )).toggleStyle(.checkbox)
                                    }.frame(width: 150, alignment: .leading)
                                }
                            }
                        }
                        Divider()
                    }
                }
            }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Exclude \(selection.count) samples") {
                    session.excludeDuplicates(selection)
                    dismiss()
                }
                .disabled(selection.isEmpty || session.busy || session.editing)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }.padding(28).frame(width: 720, height: 560)
    }
}
