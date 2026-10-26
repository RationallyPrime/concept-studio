import PrevisCore
import SwiftUI

struct ShotsWorkspaceView: View {
    @Bindable var session: StudioSession

    var body: some View {
        if let store = session.shots {
            ShotsWorkspaceContent(store: store)
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
    @State private var showsShotCamera = false

    var body: some View {
        VSplitView {
            HSplitView {
                sceneColumn.frame(minWidth: 160, idealWidth: 180, maxWidth: 240)
                viewport.frame(minWidth: 260, maxWidth: .infinity, minHeight: 220)
                inspector.frame(minWidth: 180, idealWidth: 210, maxWidth: 250)
            }
            timeline.frame(minHeight: 96, idealHeight: 112, maxHeight: 160)
        }
    }

    private var sceneColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Scenes and shots").font(.headline).padding(12)
            List(selection: Binding(get: { store.currentShotID }, set: { selectShot($0) })) {
                ForEach(store.document.scenes, id: \.id) { scene in
                    Section(scene.name) {
                        ForEach(scene.shots, id: \.id) { shot in
                            Label(shot.name, systemImage: "film").foregroundStyle(.primary).tag(shot.id)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .accessibilityLabel("Scenes and shots")
            .overlay {
                if store.document.scenes.isEmpty {
                    Text("Start with a scene, then frame its shot.")
                        .font(.callout).foregroundStyle(.secondary).padding()
                }
            }
            Button("New scene", systemImage: "plus", action: addScene)
                .disabled(store.isReadOnly).padding(12)
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
                if let shot = store.currentShot {
                    Text(shot.name).font(.title3)
                    LabeledContent("Frames", value: "\(shot.frameCount)")
                    LabeledContent("Canvas", value: "\(shot.canvas.width) × \(shot.canvas.height)")
                } else {
                    Text("Choose a shot to see its settings.").foregroundStyle(.secondary)
                }
                if store.isReadOnly {
                    Label("Read only", systemImage: "lock").foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
        }
        .accessibilityLabel("Shot inspector")
    }

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Timeline").font(.headline)
                Spacer()
                if let shot = store.currentShot {
                    Text("Frame \(store.playhead + 1) of \(shot.frameCount)")
                        .monospacedDigit().foregroundStyle(.secondary)
                }
            }
            Slider(
                value: Binding(get: { Double(store.playhead) }, set: { store.playhead = Int($0.rounded()) }),
                in: 0 ... Double(max(1, (store.currentShot?.frameCount ?? 1) - 1)), step: 1
            )
            .disabled(store.currentShot == nil)
            .accessibilityLabel("Playhead")
            .accessibilityValue("Frame \(store.playhead + 1)")
        }
        .padding(12)
    }

    private func selectShot(_ id: ShotID?) {
        guard let id,
              let scene = store.document.scenes.first(where: { $0.shots.contains { $0.id == id } }) else { return }
        store.preview = nil
        store.selection = .none
        store.currentSceneID = scene.id
        store.currentShotID = id
    }

    private func addScene() {
        let sceneID = store.newID("scene"), shotID = store.newID("shot")
        store.run(.addScene(
            id: sceneID, name: "New scene", takeID: store.newID("take"), shotID: shotID,
            cameraMarkID: store.newID("camera")
        ))
        if store.document.scenes.contains(where: { $0.id == sceneID }) { selectShot(shotID) }
    }
}
