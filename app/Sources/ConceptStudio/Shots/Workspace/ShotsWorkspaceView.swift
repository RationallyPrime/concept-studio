import PrevisCore
import SwiftUI

struct ShotsWorkspaceView: View {
    @Bindable var session: StudioSession

    var body: some View {
        if let store = session.shots {
            ShotsWorkspaceContent(store: store, projectDirectory: session.project?.directory)
        } else {
            ContentUnavailableView(
                "Shots is unavailable", systemImage: "film",
                description: Text("Close and reopen the project to try again.")
            )
        }
    }
}

private struct ShotsWorkspaceContent: View {
    @Bindable var store: ShotsStore
    let projectDirectory: URL?
    @State private var showsShotCamera = false

    var body: some View {
        VSplitView {
            HSplitView {
                sceneColumn.frame(minWidth: 160, idealWidth: 180, maxWidth: 240)
                viewport.frame(minWidth: 260, maxWidth: .infinity, minHeight: 220)
                inspector.frame(minWidth: 180, idealWidth: 210, maxWidth: 250)
            }
            ShotsTimelineView(store: store).frame(minHeight: 150, idealHeight: 210, maxHeight: 360)
        }
        .background(ShotsUndoBridge(store: store))
        .onKeyPress(keys: [.space]) { press in
            guard press.modifiers.isDisjoint(with: [.command, .control, .option, .shift]),
                  !ShotsTimelineView.editingText,
                  store.currentShot != nil else { return .ignored }
            store.toggleShotsPlayback()
            return .handled
        }
    }

    private var sceneColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            ShotsSceneList(store: store)
            Divider()
            Text("Library").font(.headline).padding(12)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(store.catalog.assets.filter { store.catalog.starter.assets.contains($0.id) }) { asset in
                        Text(asset.name).font(.callout)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12)
            }
            .frame(height: 92).accessibilityLabel("Asset library")
        }
    }

    private var viewport: some View {
        VStack(spacing: 0) {
            Picker("View", selection: $showsShotCamera) {
                Text("Scene view").tag(false)
                Text("Shot camera").tag(true)
            }
            .pickerStyle(.segmented).padding(12)
            if showsShotCamera {
                ShotCameraView(store: store)
            } else {
                ShotsViewport(store: store)
            }
        }
    }

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Inspector").font(.headline)
                Divider()
                ShotsShotSettings(store: store)
                Divider()
                ShotsExportView(store: store, projectDirectory: projectDirectory)
                if store.isReadOnly {
                    Label("Read only", systemImage: "lock").foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
        }
        .accessibilityLabel("Shot inspector")
    }
}
