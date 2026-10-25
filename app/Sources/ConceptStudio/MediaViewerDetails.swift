import ConceptCore
import Foundation
import ImageIO
import SwiftUI

/// File metadata is read from the opened file, including generated outputs and retained originals.
struct MediaViewerFileInfo: Equatable, Sendable {
    let width: Int
    let height: Int
    let bytes: Int64

    var description: String {
        "\(width) × \(height) px · " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func read(_ url: URL) async throws -> Self {
        let bytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        if Sources.isVideo(Sources.suffix(of: url.lastPathComponent)) {
            let info = try await MediaEditor.videoInfo(url: url)
            return Self(width: info.width, height: info.height, bytes: Int64(bytes))
        }
        return try await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int else {
                throw StudioError.message("This image's dimensions could not be read.")
            }
            let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
            return Self(
                width: orientation >= 5 ? height : width,
                height: orientation >= 5 ? width : height, bytes: Int64(bytes)
            )
        }.value
    }
}

struct MediaViewerDetails: View {
    @Bindable var session: StudioSession
    let item: MediaViewerItem
    let url: URL?
    @State private var info: MediaViewerFileInfo?
    @State private var metadataError: String?

    private var image: ProjectImage? {
        guard case let .project(id) = item else { return nil }
        return session.project?.allMedia.first { $0.id == id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("File").font(.headline)
                if let info { Text(info.description).monospacedDigit() }
                if let metadataError { Text(metadataError).foregroundStyle(.secondary) }
                if let url { Text(url.lastPathComponent).textSelection(.enabled) }
                source
            }
            if let image { projectDetails(image) } else if case let .render(_, _, prompt, _) = item {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Generation prompt").font(.headline)
                    Text(prompt).textSelection(.enabled)
                    Text("This is a generated comparison output, outside the training dataset.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .font(.callout)
        .focusedSceneValue(\.captionSaveAction, saveAction)
        .task(id: url) {
            info = nil; metadataError = nil
            guard let url else { return }
            do {
                let result = try await MediaViewerFileInfo.read(url)
                if !Task.isCancelled { info = result }
            } catch {
                if !Task.isCancelled { metadataError = error.localizedDescription }
            }
        }
    }

    private var saveAction: CaptionSaveAction? {
        guard let image else { return nil }
        return CaptionSaveAction(save: {
            let draft = session.captionDraft(for: image)
            session.saveCaption(id: image.id, text: draft.text, final: draft.isFinal)
        }, disabled: session.busy || session.editing || !session.hasUnsavedCaption(for: image))
    }

    @ViewBuilder private var source: some View {
        switch item {
        case let .render(_, _, _, source): Text("Source: " + source)
        case .project:
            if let image {
                if let upscale = session.upscaleRecord(for: image.id) {
                    Text("Source: Upscale · " + upscale.model.title)
                    Text("Original: " + upscale.originalID)
                    Text("Use Original before upscale to inspect its retained file.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                let original = session.project?.mediaState.selections[image.id]?.originalName ?? image.id
                if let origin = session.project?.mediaState.origins[original]
                    ?? session.project?.mediaState.origins[image.id] {
                    Text("Imported from: " + origin)
                } else {
                    Text("Original import source was not recorded.").foregroundStyle(.secondary)
                }
            }
        }
    }

    private func projectDetails(_ image: ProjectImage) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Caption").font(.headline)
                TextEditor(text: Binding(
                    get: { session.captionDraft(for: image).text },
                    set: {
                        var draft = session.captionDraft(for: image)
                        draft.text = $0
                        session.setCaptionDraft(draft, for: image.id)
                    }
                ))
                .frame(minHeight: 140).scrollContentBackground(.hidden)
                .padding(6).background(.background, in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.separator, lineWidth: 1))
                .accessibilityLabel("Caption for " + image.id)
                .disabled(session.busy || session.editing)
                Button("Save caption") {
                    let draft = session.captionDraft(for: image)
                    session.saveCaption(id: image.id, text: draft.text, final: draft.isFinal)
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(session.busy || session.editing || !session.hasUnsavedCaption(for: image))
                if session.hasUnsavedCaption(for: image) {
                    Text("Unsaved edit · kept as a draft when you browse or close.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Concept mapping").font(.headline)
                if let mapping = session.project?.job.mapping(for: image.id), !mapping.isEmpty {
                    ForEach(mapping.keys, id: \.self) { trigger in
                        Text(trigger + ": " + (mapping[trigger] ?? "")).textSelection(.enabled)
                    }
                } else { Text("No confirmed mapping").foregroundStyle(.secondary) }
                if let result = session.faceRecognitionResults[image.id] {
                    FaceMatchResultView(result: result)
                } else {
                    Text("Face match: not measured").foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Warnings").font(.headline)
                let warnings = (session.analyses[image.id]?.warnings ?? []) + image.notes
                    + (session.projectState.notSure[image.id].map { ["Not sure: " + $0] } ?? [])
                if warnings.isEmpty { Text("No recorded warnings").foregroundStyle(.secondary) }
                ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Toggle("Include in training", isOn: Binding(
                get: { session.project?.isIncluded(image.id) == true },
                set: { session.includeMedia(image.id, included: $0) }
            )).toggleStyle(.checkbox).disabled(session.busy || session.editing)
        }
    }
}
