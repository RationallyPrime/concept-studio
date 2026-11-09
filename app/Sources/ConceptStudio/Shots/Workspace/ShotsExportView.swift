import AppKit
import PrevisCore
import ShotsMedia
import SwiftUI

struct ShotsExportView: View {
    @Bindable var store: ShotsStore
    let projectDirectory: URL?
    @State private var exportTask: Task<Void, Never>?
    @State private var progress: ExportProgress?
    @State private var summary: String?

    var body: some View {
        ShotsExportControls(
            running: exportTask != nil, progress: progress, summary: summary,
            unavailableReason: unavailableReason, export: beginExport, cancel: { exportTask?.cancel() }
        )
        .onDisappear { exportTask?.cancel() }
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
            let destination = FolderDestination(parent: projectDirectory.appendingPathComponent(
                "Shots",
                isDirectory: true
            ))
            progress = nil
            summary = nil
            exportTask = Task { @MainActor in
                defer { exportTask = nil }
                do {
                    let package = try await exporter.export(
                        scene: snapshot.scene, shotID: snapshot.shotID, options: .standard, to: destination
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
                    .help("Save this shot's guide pictures, reference and control videos, masks and prompt "
                        + "into the project's Shots folder, then show them in Finder.")
                if let unavailableReason {
                    Text(unavailableReason).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let summary {
                    Text(summary).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    static func progressValue(_ progress: ExportProgress?) -> String {
        guard let progress else { return "Preparing" }
        let percent = Int((min(max(progress.fractionCompleted, 0), 1) * 100).rounded())
        return "\(percent) percent, \(progress.step)"
    }
}
