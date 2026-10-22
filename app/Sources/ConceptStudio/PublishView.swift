import SwiftUI

struct PublishView: View {
    @Bindable var session: StudioSession

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: StudioStyle.contentSpacing) {
                if let project = session.project { datasetSummary(project) }
                if session.unsavedCaptionCount > 0 {
                    HStack(spacing: 12) {
                        StudioNotice(
                            "\(session.unsavedCaptionCount) caption edits are not saved. "
                                + "Publishing uses saved captions, so return to Review to save those edits.",
                            symbol: "pencil"
                        )
                        Button("Review unsaved edits") { session.step = .review }
                    }
                }
                Divider()
                if session.gpu.usesLocalDataset {
                    StudioSection(title: "Upload directly to your cloud GPU") {
                        Text("No Hugging Face token is configured. Check your saved training data here, then rent a "
                            + "cloud GPU and start training. The app uploads your included targets directly over its "
                            + "authenticated connection. No dataset account is required.")
                        Text("Up to 2 GiB per file and 20 GiB per dataset. "
                            + "Some starting models still require their own account or license access.")
                            .font(.callout).foregroundStyle(StudioStyle.supportingText)
                    }
                } else {
                    StudioSection(
                        title: "Choose the destination",
                        subtitle: "Use a dataset in your own Hugging Face account."
                    ) {
                        TextField("Hugging Face owner/dataset", text: $session.repoID).textFieldStyle(.roundedBorder)
                        Toggle("Private dataset", isOn: $session.privateDataset)
                            .disabled(session.project?.job.adultContent == true)
                        Text("Private datasets are visible only to accounts with access. "
                            + "Keep this on for private images and clips.")
                            .font(.callout).foregroundStyle(StudioStyle.supportingText)
                        StudioNotice(
                            "Your Hugging Face write token goes in Settings. It is never saved in the project.",
                            symbol: "key"
                        )
                    }.disabled(session.busy)
                }
                Divider()
                StudioSection(
                    title: session.gpu.usesLocalDataset ? "Check training data" : "Publish",
                    subtitle: session.demoMode
                        ? "Offline simulation: no files leave your Mac and no money is spent."
                        : session.gpu.usesLocalDataset ? "Checks the included targets and saved captions on your Mac."
                        : "Uploads to your own account. This action does not rent a cloud GPU."
                ) {
                    Button(
                        session.demoMode ? "Simulate dataset upload"
                            : session.gpu.usesLocalDataset ? "Check training data" : "Publish dataset",
                        systemImage: "arrow.up.doc"
                    ) {
                        session.publish()
                    }.buttonStyle(.borderedProminent).tint(StudioStyle.actionTint)
                        .keyboardShortcut(.return, modifiers: .command)
                        .help(session.gpu.usesLocalDataset
                            ? "Check saved training data (⌘↩)" : "Publish the dataset (⌘↩)")
                        .disabled(session
                            .busy || (!session.demoMode && !session.gpu.usesLocalDataset && session.repoID.isEmpty))
                    if session.busy { ProgressView(session.message) }
                    Text(
                        "Continue to Cloud GPU to choose one for training and review its price. "
                            + "Training uses your saved captions and included media."
                    )
                    .font(.callout).foregroundStyle(StudioStyle.supportingText)
                }
            }.frame(maxWidth: 900, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { session.preparePublishing() }
        .onChange(of: session.providerCredentialRevision) { _, _ in session.preparePublishing() }
    }

    /// The included prints squared up like a stack for the box, beside the three counts that matter.
    private func datasetSummary(_ project: StudioProject) -> some View {
        let captioned = session.publishingImages.count(where: { !$0.caption.isEmpty })
        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 36) {
                printStack(session.publishingImages)
                HStack(alignment: .top, spacing: 30) {
                    PrintFigure(value: "\(session.publishingImages.count)", label: "samples")
                    PrintFigure(value: "\(captioned)", label: "captions")
                    PrintFigure(value: "\(session.publishingImages.filter(\.isFinal).count)", label: "final")
                }
                Spacer(minLength: 0)
            }
            if !session.uncaptionedPublishingImages.isEmpty {
                StudioNotice("\(session.uncaptionedPublishingImages.count) samples have no caption "
                    + (session.projectState.includeUncaptioned ? "and will be included." : "and will be left out."))
                Toggle("Include them anyway", isOn: Binding(
                    get: { session.projectState.includeUncaptioned },
                    set: { value in session.updateProjectState { $0.includeUncaptioned = value } }
                )).disabled(session.busy)
                DisclosureGroup("Samples without captions") {
                    ForEach(session.uncaptionedPublishingImages) { image in Text(image.id) }
                }
            }
            let omitted = project.allMedia.filter { image in
                project.excludedImages.contains { $0.id == image.id } || session.projectState.notSure[image.id] != nil
            }
            if !omitted.isEmpty {
                DisclosureGroup("\(omitted.count) excluded or Not sure samples will be left out") {
                    ForEach(omitted) { image in Text(image.id) }
                }
            }
            Text("\(session.publishingImages.count) samples ready to publish")
                .font(.callout)
            DisclosureGroup("What gets uploaded") {
                Text(
                    "The upload contains your included training images or selected video segments, their saved "
                        + "captions and the project configuration. Approved crops replace the full images. "
                        + "Excluded samples, editing originals and mapping references are omitted."
                )
                .font(.callout).foregroundStyle(StudioStyle.supportingText).padding(.top, 12)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Up to eight prints, each a little further along, so the stack reads as the whole set.
    private func printStack(_ images: [ProjectImage]) -> some View {
        let shown = Array(images.prefix(8))
        return ZStack(alignment: .topLeading) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, image in
                VStack(spacing: 0) {
                    TrainingTargetPreview(url: image.url, fill: true).frame(width: 96, height: 96).clipped()
                    Color.clear.frame(width: 96, height: 22)
                }
                .padding([.horizontal, .top], 5)
                .background(InstantPrint.paper, in: RoundedRectangle(cornerRadius: 3))
                .shadow(color: .black.opacity(0.14), radius: 2, x: 0, y: 1)
                .offset(x: CGFloat(shown.count - 1 - index) * 14)
                .zIndex(Double(index))
            }
        }
        .frame(width: 106 + CGFloat(max(shown.count - 1, 0)) * 14, height: 128, alignment: .topLeading)
        .environment(\.colorScheme, .light)
        .accessibilityElement().accessibilityLabel("\(images.count) included samples")
    }
}
