import AppKit
import PrevisCore
import ShotsMedia
import SwiftUI

struct ShotsExportView: View {
    @Bindable var store: ShotsStore
    let projectDirectory: URL?
    let folders: ShotsExportFolders
    @State private var exportTask: Task<Void, Never>?
    @State private var progress: ExportProgress?
    @State private var summary: String?
    @State private var chosenFolder: String?

    var body: some View {
        ShotsExportControls(
            running: exportTask != nil, progress: progress, summary: summary,
            unavailableReason: unavailableReason, export: beginExport, cancel: { exportTask?.cancel() },
            folder: folderControls
        )
        .onDisappear { exportTask?.cancel() }
        .task(id: store.currentSceneID) { readChosenFolder() }
    }

    /// The scene's export folder and the two ways to change it; nil without a project and a scene to export from.
    private var folderControls: ShotsExportControls.Folder? {
        guard let projectDirectory, let sceneID = store.currentSceneID else { return nil }
        return ShotsExportControls.Folder(
            chosen: chosenFolder,
            choose: {
                guard let url = ProjectAccess.chooseFolder(prompt: "Export here") else { return }
                do {
                    try folders.choose(url, forScene: sceneID, inProject: projectDirectory)
                    readChosenFolder()
                    AccessibilityNotification.Announcement("This scene's packages now go to \(url.lastPathComponent).")
                        .post()
                } catch {
                    store.onError?(error.localizedDescription)
                }
            },
            useProject: {
                folders.clear(forScene: sceneID, inProject: projectDirectory)
                readChosenFolder()
                AccessibilityNotification.Announcement("This scene's packages now go to the project's Shots folder.")
                    .post()
            }
        )
    }

    private func readChosenFolder() {
        chosenFolder = projectDirectory.flatMap { project in
            store.currentSceneID.flatMap { folders.chosenPath(forScene: $0, inProject: project) }
        }
    }

    /// Why Export is off, in words, so a disabled button never leaves the reader guessing.
    private var unavailableReason: String? {
        if store.isReadOnly { return "This Shots file is read only." }
        if store.currentShotID == nil { return "Choose a shot to export it." }
        if projectDirectory == nil { return "Open a project folder to export into." }
        return nil
    }

    private func beginExport() {
        guard exportTask == nil, let projectDirectory else { return }
        do {
            let snapshot = try store.exportSnapshot()
            try store.flush()
            let exporter = try ShotExporter(catalog: store.catalog)
            let folder = try folders.open(forScene: snapshot.scene.id, inProject: projectDirectory)
            let destination = FolderDestination(parent: folder.url)
            progress = nil
            summary = nil
            exportTask = Task { @MainActor in
                defer {
                    exportTask = nil
                    folder.close()
                }
                do {
                    let package = try await exporter.export(
                        scene: snapshot.scene, shotID: snapshot.shotID,
                        options: .standard(inProject: projectDirectory), to: destination
                    ) { progress = $0 }
                    try Task.checkCancellation()
                    summary = "Shot package exported."
                    AccessibilityNotification.Announcement("Shot package exported. Showing it in Finder.").post()
                    NSWorkspace.shared.activateFileViewerSelecting([package.url])
                } catch is CancellationError {
                    summary = "Export cancelled."
                    AccessibilityNotification.Announcement("Export cancelled.").post()
                } catch {
                    store.onError?(error.localizedDescription)
                }
            }
        } catch {
            store.onError?(error.localizedDescription)
        }
    }
}

/// The export area's visible states. Failures go to the window alert, the app's single failure path.
struct ShotsExportControls: View {
    let running: Bool
    let progress: ExportProgress?
    let summary: String?
    let unavailableReason: String?
    let export: () -> Void
    let cancel: () -> Void
    var folder: Folder?

    /// Where the scene's packages go: the folder the user chose for it, or the project's own Shots folder.
    struct Folder {
        let chosen: String?
        let choose: () -> Void
        let useProject: () -> Void
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Export").font(.headline).accessibilityAddTraits(.isHeader)
            if running {
                ProgressView(value: progress?.fractionCompleted ?? 0)
                    .accessibilityLabel("Export progress")
                    .accessibilityValue(Self.progressValue(progress))
                Text(progress?.step ?? "Preparing the shot package…").font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Cancel export", action: cancel)
            } else {
                Button("Export shot package…", systemImage: "square.and.arrow.up", action: export)
                    .disabled(unavailableReason != nil)
                    .help("Save this shot's guide pictures, reference and control videos, masks, staging and "
                        + "prompt into this scene's export folder, then show them in Finder. A shot over a plate "
                        + "also gets the composition guide for the image model.")
                if let unavailableReason {
                    Text(unavailableReason).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let summary {
                    Text(summary).font(.caption).foregroundStyle(.secondary)
                }
                if let folder { destination(folder) }
            }
        }
    }

    private func destination(_ folder: Folder) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Self.destinationSentence(folder.chosen)).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            Button("Choose export folder…", action: folder.choose)
                .help("Send every shot package of this scene to a folder you choose, such as the scene's folder "
                    + "in your production tree. Each shot gets its own folder inside it.")
            if folder.chosen != nil {
                Button("Use the project's Shots folder", action: folder.useProject)
                    .help("Send this scene's shot packages to the Shots folder inside this project again. "
                        + "Packages already exported stay where they are.")
            }
        }
        .controlSize(.small)
    }

    static func destinationSentence(_ chosen: String?) -> String {
        guard let chosen else { return "This scene's packages go to the project's Shots folder." }
        return "This scene's packages go to \((chosen as NSString).abbreviatingWithTildeInPath)."
    }

    static func progressValue(_ progress: ExportProgress?) -> String {
        guard let progress else { return "Preparing" }
        let percent = Int((min(max(progress.fractionCompleted, 0), 1) * 100).rounded())
        return "\(percent) percent, \(progress.step)"
    }
}
