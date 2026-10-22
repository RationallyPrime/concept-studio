import ConceptCore
import ImageIO
import SwiftUI

/// Choose included images and clips and upscale them with SeedVR2 on the cloud GPU.
struct UpscaleSheet: View {
    @Bindable var session: StudioSession
    @State var selection: Set<String>
    @State private var model = UpscaleModel.standard
    @Environment(\.dismiss) private var dismiss

    private var target: UpscaleTarget {
        session.upscaleTarget
    }

    private var images: [ProjectImage] {
        session.project?.images ?? []
    }

    private var unavailable: String? {
        session.gpu.upscaleUnavailableReason
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Upscale and restore").font(.title2.bold())
            Text(
                "SeedVR2 enlarges and repairs blurry, noisy or compressed images and clips on your cloud GPU. "
                    + "Results have a short side of \(target.shortSide) px, the largest size "
                    + "\(session.gpu.effectiveModelRow.shortName) trains at. Each result waits beside its "
                    + "original; nothing is replaced until you keep it."
            )
            .foregroundStyle(StudioStyle.supportingText).fixedSize(horizontal: false, vertical: true)
            modelChoice
            Divider()
            sampleList
            Divider()
            costAndLicence
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if unavailable != nil, !session.demoMode {
                    Button("Open Cloud GPU") { session.step = .pods; dismiss() }
                }
                Button("Upscale \(selection.count) on cloud GPU") {
                    session.upscale(images.map(\.id).filter(selection.contains), model: model)
                    dismiss()
                }
                .buttonStyle(.borderedProminent).tint(StudioStyle.actionTint)
                .disabled(selection.isEmpty || unavailable != nil || session.busy)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28).frame(width: 620)
    }

    private var modelChoice: some View {
        Picker("Model", selection: $model) {
            ForEach(UpscaleModel.allCases) { option in
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.title)
                    Text(option.summary + " First use downloads "
                        + option.firstDownloadGB.formatted(.number.precision(.fractionLength(1)))
                        + " GB to the cloud GPU's storage.")
                        .font(.callout).foregroundStyle(StudioStyle.supportingText)
                }.tag(option)
            }
        }
        .pickerStyle(.radioGroup)
    }

    private var sampleList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(selection.count) of \(images.count) included samples chosen")
                    .font(.callout.weight(.semibold)).monospacedDigit()
                Spacer()
                Button("Choose those below \(target.shortSide) px") {
                    selection = Set(session.upscaleSuggestions)
                }
                Button("Choose none") { selection = [] }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(images) { image in sampleRow(image) }
                }
            }
            .frame(height: 220)
        }
    }

    private func sampleRow(_ image: ProjectImage) -> some View {
        let analysis = session.analyses[image.id]
        return Toggle(isOn: Binding(
            get: { selection.contains(image.id) },
            set: { if $0 { selection.insert(image.id) } else { selection.remove(image.id) } }
        )) {
            HStack(spacing: 10) {
                PhotoView(url: image.url, fill: true).frame(width: 44, height: 34).clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                Text(image.id).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                if let analysis, analysis.width > 0 {
                    Text("\(analysis.width) × \(analysis.height)").monospacedDigit()
                        .foregroundStyle(StudioStyle.supportingText)
                }
                if target.isBelow(analysis) { PrintStateChip(state: .other("Below \(target.shortSide) px")) }
                if session.pendingUpscales.contains(where: { $0.sourceID == image.id }) {
                    PrintStateChip(state: .other("Result waiting"))
                }
            }
        }
        .toggleStyle(.checkbox)
    }

    private var costAndLicence: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let unavailable {
                Text(unavailable).fixedSize(horizontal: false, vertical: true)
            } else if let rate = session.gpu.upscaleHourlyRate {
                Text("Uses your running cloud GPU at \(StudioMoney.perHour(rate)) while it works. "
                    + "Clips take much longer than images; the budget and idle stop you set still apply.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(UpscaleModel.caution).font(.callout).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 4) {
                Text(UpscaleModel.licenseNotice).font(.callout).foregroundStyle(StudioStyle.supportingText)
                    .fixedSize(horizontal: false, vertical: true)
                Link("Model card", destination: model.modelCard).font(.callout)
            }
        }
    }
}

/// Upscaled results waiting for a decision, each beside its original.
struct UpscaleReviewSection: View {
    @Bindable var session: StudioSession
    @State private var comparing: PendingUpscale?

    var body: some View {
        StudioSection(
            title: "Upscaled versions to review",
            subtitle: "Keep a result to train on it in place of its original, or discard it. "
                + "A kept original stays in the project and can be put back."
        ) {
            HStack {
                Button("Keep all \(session.pendingUpscales.count)") { session.keepAllUpscales() }
                    .disabled(session.busy || session.editing)
                Spacer()
            }
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 18) {
                    ForEach(session.pendingUpscales) { pending in row(pending) }
                }
            }
        }
        .sheet(item: $comparing) { pending in UpscaleCompareSheet(session: session, pending: pending) }
    }

    private func row(_ pending: PendingUpscale) -> some View {
        let original = session.project?.allMedia.first { $0.id == pending.sourceID }
        let result = session.project.map { pending.resultURL(in: $0.directory) }
        return VStack(alignment: .leading, spacing: 8) {
            Text(pending.sourceID).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                .truncationMode(.middle)
            HStack(spacing: 8) {
                if let original { UpscaleSide(label: "Original", url: original.url, height: 130) }
                if let result { UpscaleSide(label: "Upscaled", url: result, height: 130) }
            }
            HStack(spacing: 8) {
                Button("Keep upscaled") { session.keepUpscale(pending.sourceID) }
                Button("Discard") { session.discardUpscale(pending.sourceID) }
                Button("Compare larger…") { comparing = pending }
            }
            .disabled(session.busy || session.editing)
        }
        .frame(width: 360, alignment: .leading)
    }
}

/// The original and its upscaled result side by side at the size of the window.
struct UpscaleCompareSheet: View {
    @Bindable var session: StudioSession
    let pending: PendingUpscale
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Compare \(pending.sourceID)").font(.title2.bold())
            Text(UpscaleModel.caution).foregroundStyle(StudioStyle.supportingText)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 12) {
                if let original = session.project?.allMedia.first(where: { $0.id == pending.sourceID }) {
                    UpscaleSide(label: "Original", url: original.url, height: 520)
                }
                if let project = session.project {
                    UpscaleSide(label: "Upscaled with \(pending.model.title)", url: pending.resultURL(
                        in: project.directory
                    ), height: 520)
                }
            }
            HStack {
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Discard") { session.discardUpscale(pending.sourceID); dismiss() }
                Button("Keep upscaled") { session.keepUpscale(pending.sourceID); dismiss() }
                    .buttonStyle(.borderedProminent).tint(StudioStyle.actionTint)
                    .keyboardShortcut(.defaultAction)
            }
            .disabled(session.busy || session.editing)
        }
        .padding(24).frame(minWidth: 900, minHeight: 680)
    }
}

/// One side of a comparison: the media, what it is and its pixel size.
struct UpscaleSide: View {
    let label: String
    let url: URL
    let height: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TrainingTargetPreview(url: url).frame(maxWidth: .infinity).frame(height: height)
                .background(InstantPrint.paper)
            Text(label + (Self.pixelSize(url).map { " · \($0)" } ?? "")).font(.caption).monospacedDigit()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }

    /// "1365 × 1024" for an image, from its header; nil for a clip or an unreadable file.
    static func pixelSize(_ url: URL) -> String? {
        guard !Sources.isVideo(Sources.suffix(of: url.lastPathComponent)),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return "\(width) × \(height)"
    }
}
