import AppKit
import PrevisCore
import ShotsMedia
import SwiftUI

/// Every shot of a scene side by side, each as its first frame through its own camera over its own plate, with the
/// framing table the scene sheet takes. Both are drawn from the blocking as it stands.
struct ShotsSceneBoard: View {
    @Bindable var store: ShotsStore
    let sceneID: SceneID
    let projectDirectory: URL?
    let folders: ShotsExportFolders
    let onClose: () -> Void
    @State private var pictures: [ShotID: CGImage] = [:]
    @State private var notice: String?

    private var scene: PrevisScene? {
        store.document.scenes.first { $0.id == sceneID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let scene {
                let rows = FramingTable.rows(scene: scene, catalog: store.catalog)
                HStack {
                    Text("\(scene.name): every shot").font(.title3).accessibilityAddTraits(.isHeader)
                    Spacer()
                    if let notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
                    Button("Copy framing table", systemImage: "doc.on.doc") { copy(scene) }
                        .help("Copy the table below as Markdown, to paste into the scene sheet.")
                    Button("Save framing table…", systemImage: "square.and.arrow.down") { save(scene) }
                        .disabled(projectDirectory == nil)
                        .help("Save the table and each shot's staging in words into this scene's export folder.")
                    Button("Done", action: onClose).keyboardShortcut(.defaultAction)
                }
                .padding(14)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 190, maximum: 240), spacing: 14)],
                            spacing: 14
                        ) {
                            ForEach(rows, id: \.shotID) { row in card(row, in: scene) }
                        }
                        table(rows)
                    }
                    .padding(14)
                }
                .task(id: scene.revision) { await draw(scene) }
            } else {
                Text("This scene is no longer in the project.").padding()
                Button("Done", action: onClose).padding()
            }
        }
        .frame(minWidth: 760, idealWidth: 980, minHeight: 560, idealHeight: 720)
    }

    private func card(_ row: FramingTable.Row, in scene: PrevisScene) -> some View {
        let shot = scene.shots.first { $0.id == row.shotID }
        let aspect = shot?.canvas.aspect ?? 9.0 / 16
        return Button {
            store.selectShot(row.shotID)
            onClose()
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Group {
                    if let picture = pictures[row.shotID] {
                        Image(decorative: picture, scale: 1).resizable().interpolation(.high)
                    } else {
                        Rectangle().fill(Color.primary.opacity(0.08)).overlay { ProgressView().controlSize(.small) }
                    }
                }
                .aspectRatio(aspect, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.2)) }
                Text(row.shot).font(.headline)
                Text(row.framing).font(.callout)
                Text("\(row.plate) · \(row.lens)").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .help("Open shot \(row.shot).")
        .accessibilityLabel("Shot \(row.shot): \(row.framing), on \(row.plate), \(row.lens). \(row.who)")
        .accessibilityHint("Opens this shot.")
    }

    private func table(_ rows: [FramingTable.Row]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Framing table").font(.headline).accessibilityAddTraits(.isHeader)
            Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    ForEach(["Shot", "Plate", "Framing", "Lens", "Camera", "Who is where"], id: \.self) {
                        Text($0).font(.caption.bold())
                    }
                }
                ForEach(rows, id: \.shotID) { row in
                    GridRow {
                        Text(row.shot)
                        Text(row.plate)
                        Text(row.framing)
                        Text(row.lens)
                        Text(row.camera)
                        Text(row.who).fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.callout).textSelection(.enabled)
                }
            }
        }
    }

    /// Draws each shot's first frame at a small size, over its plate when it has one.
    private func draw(_ scene: PrevisScene) async {
        guard ShotFrameRenderer.isAvailable, let renderer = try? ShotFrameRenderer() else { return }
        let plates = store.plateFolder.map(PlateImages.init(folder:))
        let look = PrevisLook(scene: scene)
        for shot in scene.shots {
            if Task.isCancelled { return }
            guard let evaluator = try? ShotEvaluator(scene: scene, shotID: shot.id, catalog: store.catalog) else {
                continue
            }
            let frame = evaluator.frame(0)
            let height = 480
            let size = PixelSize(width: max(2, Int((Double(height) * shot.canvas.aspect).rounded())), height: height)
            var picture: CGImage?
            if let plate = frame.plate, let image = try? plates?.image(for: plate) {
                picture = try? await renderer.image(
                    of: frame, over: image, look: look, options: .labelledGuide, sensor: shot.camera.sensor, size: size
                )
            }
            if picture == nil { picture = try? await renderer.image(of: frame, look: look, size: size) }
            pictures[shot.id] = picture
        }
    }

    static func document(for scene: PrevisScene, catalog: ContentCatalog) -> String {
        var text = "# \(scene.name): framing table\n\n" + FramingTable.markdown(scene: scene, catalog: catalog)
        for shot in scene.shots {
            guard let staging = try? ShotEvaluator(scene: scene, shotID: shot.id, catalog: catalog).staging() else {
                continue
            }
            text += "\n## \(shot.name)\n\n" + staging.description() + "\n\n" + staging.legend() + "\n"
        }
        return text
    }

    private func copy(_ scene: PrevisScene) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(FramingTable.markdown(scene: scene, catalog: store.catalog), forType: .string)
        notice = "Framing table copied."
        AccessibilityNotification.Announcement("Framing table copied.").post()
    }

    private func save(_ scene: PrevisScene) {
        guard let projectDirectory else { return }
        do {
            let folder = try folders.open(forScene: scene.id, inProject: projectDirectory)
            defer { folder.close() }
            try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
            let words = scene.name.lowercased().split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }
            let slug = words.isEmpty ? "scene" : words.joined(separator: "-")
            let url = folder.url.appendingPathComponent("\(slug)-framing.md")
            try Data(Self.document(for: scene, catalog: store.catalog).utf8).write(to: url, options: .atomic)
            notice = "Saved \(url.lastPathComponent)."
            AccessibilityNotification.Announcement("Framing table saved. Showing it in Finder.").post()
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            store.onError?(error.localizedDescription)
        }
    }
}
