import AppKit
import AVKit
import ConceptCore
import SwiftUI

/// The viewer points at project samples by id, so saved captions and inclusion changes stay live.
enum MediaViewerItem: Identifiable, Equatable {
    case project(String)
    case render(url: URL, title: String, prompt: String, source: String)

    var id: String {
        switch self {
        case let .project(id): "project:" + id
        case let .render(url, _, _, _): "render:" + url.path
        }
    }

    static func projects(_ images: [ProjectImage]) -> [Self] {
        images.map { .project($0.id) }
    }
}

struct MediaViewerSelection: Equatable {
    let items: [MediaViewerItem]
    var index: Int

    init?(item: MediaViewerItem, items: [MediaViewerItem]) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return nil }
        self.items = items
        self.index = index
    }

    var item: MediaViewerItem {
        items[index]
    }

    mutating func move(_ offset: Int) {
        index = min(max(index + offset, 0), items.count - 1)
    }
}

struct OpenMediaViewer {
    var call: (MediaViewerItem, [MediaViewerItem]) -> Void = { _, _ in }
    func callAsFunction(_ item: MediaViewerItem, among items: [MediaViewerItem]) {
        call(item, items)
    }
}

extension EnvironmentValues {
    @Entry var openMediaViewer = OpenMediaViewer()
}

private struct MediaViewerPreview: ViewModifier {
    let item: MediaViewerItem
    let items: [MediaViewerItem]
    @Environment(\.openMediaViewer) private var open

    func body(content: Content) -> some View {
        content
            .allowsHitTesting(false)
            .overlay {
                Color.clear.contentShape(Rectangle()).onTapGesture { open(item, among: items) }
            }
            .focusable()
            .onKeyPress(.space) { open(item, among: items); return .handled }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: "Open full-size viewer") { open(item, among: items) }
            .help("Click or press Space to view full size. Use arrow keys to browse and Esc to close.")
    }

    private var accessibilityLabel: String {
        switch item {
        case let .project(id): id
        case let .render(_, title, _, _): title
        }
    }
}

extension View {
    func mediaViewerPreview(_ item: MediaViewerItem, among items: [MediaViewerItem]) -> some View {
        modifier(MediaViewerPreview(item: item, items: items))
    }
}

/// An overlay on the existing workspace, leaving the contact sheet's scroll and selection intact.
struct MediaViewer: View {
    @Bindable var session: StudioSession
    @Binding var selection: MediaViewerSelection
    var close: () -> Void
    @FocusState private var focused: Bool
    @State private var actualSize = false
    @State private var showOriginal = false

    private var projectImage: ProjectImage? {
        guard case let .project(id) = selection.item else { return nil }
        return session.project?.allMedia.first { $0.id == id }
    }

    private var url: URL? {
        switch selection.item {
        case .project:
            guard let image = projectImage else { return nil }
            if showOriginal, let original = originalURL { return original }
            return image.url
        case let .render(url, _, _, _): return url
        }
    }

    private var originalURL: URL? {
        guard let image = projectImage, let project = session.project,
              let upscale = session.upscaleRecord(for: image.id) else { return nil }
        return ProjectAppState.folder(in: project.directory)
            .appendingPathComponent(upscale.backupPath).appendingPathComponent(upscale.originalID)
    }

    private var title: String {
        switch selection.item {
        case let .project(id): id
        case let .render(_, title, _, _): title
        }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).onTapGesture { close() }
            VStack(spacing: 0) {
                toolbar
                Divider()
                HStack(spacing: 0) {
                    if let url {
                        MediaViewerCanvas(url: url, actualSize: actualSize)
                            .id(url).frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ContentUnavailableView("This file is no longer in the project", systemImage: "photo")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    Divider()
                    ScrollView {
                        MediaViewerDetails(session: session, item: selection.item, url: url)
                            .padding(18).frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(width: 290)
                }
            }
            .background(InstantPrint.ground, in: RoundedRectangle(cornerRadius: 10))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .shadow(color: .black.opacity(0.3), radius: 18, x: 0, y: 8)
            .padding(20)
            .focusable().focused($focused)
            .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { key in
                selection.move(key.key == .leftArrow || key.key == .upArrow ? -1 : 1)
                return .handled
            }
            .onExitCommand { close() }
            .onAppear { focused = true }
            .onChange(of: selection.index) { _, _ in showOriginal = false }
        }
        .accessibilityAddTraits(.isModal)
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button("Close viewer", systemImage: "xmark") { close() }.labelStyle(.iconOnly)
                .help("Close viewer (Esc)")
            Text(title).font(.headline).lineLimit(1).truncationMode(.middle).help(title)
            Spacer(minLength: 8)
            if originalURL != nil {
                Toggle("Original before upscale", isOn: $showOriginal).toggleStyle(.checkbox)
            }
            if let url, !Sources.isVideo(Sources.suffix(of: url.lastPathComponent)) {
                Toggle("Actual size", isOn: $actualSize).toggleStyle(.checkbox)
                    .help("Show each image pixel at its native size. Scroll to inspect the full image.")
            }
            Text("\(selection.index + 1) of \(selection.items.count)").monospacedDigit().foregroundStyle(.secondary)
            Button("Previous item", systemImage: "chevron.left") { selection.move(-1); focused = true }
                .labelStyle(.iconOnly).disabled(selection.index == 0)
            Button("Next item", systemImage: "chevron.right") { selection.move(1); focused = true }
                .labelStyle(.iconOnly).disabled(selection.index == selection.items.count - 1)
        }.padding(14)
    }
}

private struct MediaViewerCanvas: View {
    let url: URL
    let actualSize: Bool
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        Group {
            if Sources.isVideo(Sources.suffix(of: url.lastPathComponent)) {
                MediaViewerVideo(url: url)
            } else if let image {
                if actualSize {
                    ScrollView([.horizontal, .vertical]) {
                        Image(nsImage: image).fixedSize().padding(12)
                    }
                } else {
                    Image(nsImage: image).resizable().scaledToFit().padding(12)
                }
            } else if failed {
                ContentUnavailableView("Cannot read this image", systemImage: "photo")
            } else { ProgressView("Opening full image…") }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .task(id: url) {
            guard !Sources.isVideo(Sources.suffix(of: url.lastPathComponent)) else { return }
            let decoded = await Task.detached(priority: .userInitiated) {
                try? MediaEditor.orientedImage(Data(contentsOf: url))
            }.value
            let loaded = decoded.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
            guard !Task.isCancelled else { return }
            image = loaded
            failed = loaded == nil
        }
    }
}

private struct MediaViewerVideo: View {
    @State private var player: AVPlayer
    init(url: URL) {
        _player = State(initialValue: AVPlayer(url: url))
    }

    var body: some View {
        VideoPlayer(player: player).onAppear { player.play() }.onDisappear { player.pause() }
    }
}

@MainActor
extension MediaViewerItem {
    static func comparison(_ comparison: GeneratedComparison, workspace: GPUWorkspace) -> [Self] {
        guard let manifest = workspace.comparisonManifest(comparison) else { return [] }
        return manifest.pairs.flatMap { pair in
            [(pair.basePath, "Base model"), (pair.loraPath, "With LoRA")].compactMap { path, label in
                guard let url = workspace.comparisonFile(path, in: comparison) else { return nil }
                return .render(
                    url: url, title: label + " · Seed \(pair.seed)", prompt: pair.prompt,
                    source: comparison.sourceRunID
                )
            }
        }
    }
}
