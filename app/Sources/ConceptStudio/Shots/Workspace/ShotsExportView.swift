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
        VStack(alignment: .leading, spacing: 8) {
            if exportTask != nil {
                ProgressView(value: progress?.fractionCompleted ?? 0)
                Text(progress?.step ?? "Preparing the shot package…").font(.caption)
                Button("Cancel export") { exportTask?.cancel() }
            } else {
                Button("Export shot package…", systemImage: "square.and.arrow.up", action: beginExport)
                    .disabled(store.currentShotID == nil || projectDirectory == nil || store.isReadOnly)
                if let summary { Text(summary).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .onDisappear { exportTask?.cancel() }
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
                    NSWorkspace.shared.activateFileViewerSelecting([package.url])
                } catch is CancellationError {
                    summary = "Export cancelled."
                } catch {
                    store.onError?(error.localizedDescription)
                }
            }
        } catch {
            store.onError?(error.localizedDescription)
        }
    }
}
