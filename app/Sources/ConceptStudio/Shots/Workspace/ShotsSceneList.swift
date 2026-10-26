import PrevisCore
import SwiftUI
import UniformTypeIdentifiers

struct ShotsSceneList: View {
    @Bindable var store: ShotsStore
    @State private var renameTarget: RenameTarget?
    @State private var proposedName = ""
    @State private var showsImporter = false
    @State private var importNotes: [String] = []
    @State private var importSummary: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Scenes and shots").font(.headline).padding(12)
            sceneList
            HStack {
                Button("New scene", systemImage: "plus") { attempt { try store.createScene() } }
                Spacer(minLength: 0)
                Button("Import Blockout", systemImage: "square.and.arrow.down") { showsImporter = true }
                    .labelStyle(.iconOnly).help("Import a Blockout project")
            }
            .disabled(store.isReadOnly).padding(12)
            if let importSummary {
                VStack(alignment: .leading, spacing: 6) {
                    Text(importSummary).font(.callout)
                    if !importNotes.isEmpty {
                        DisclosureGroup("Import notes (\(importNotes.count))") {
                            ForEach(Array(importNotes.enumerated()), id: \.offset) { _, note in
                                Text(note).font(.caption).textSelection(.enabled)
                            }
                        }
                    }
                }
                .padding(12)
            }
        }
        .fileImporter(isPresented: $showsImporter, allowedContentTypes: [.json]) { result in
            importProject(result)
        }
        .alert("Rename", isPresented: Binding(
            get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("Name", text: $proposedName)
            Button("Cancel", role: .cancel) { renameTarget = nil }
            Button("Rename") { finishRename() }
                .disabled(proposedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var sceneList: some View {
        List(selection: Binding(get: { store.currentShotID }, set: { store.selectShot($0) })) {
            ForEach(store.document.scenes, id: \.id) { scene in
                Section {
                    ForEach(scene.shots, id: \.id) { shot in
                        Label(shot.name, systemImage: "film").foregroundStyle(.primary).tag(shot.id)
                            .contextMenu {
                                Group {
                                    Button("Rename shot…") { beginRename(.shot(shot.id), name: shot.name) }
                                    Button("Duplicate shot") { attempt { try store.copyShot(shot.id) } }
                                    Button("Delete shot", role: .destructive) { store.run(.deleteShot(shot.id)) }
                                }
                                .disabled(store.isReadOnly)
                            }
                    }
                } header: {
                    HStack {
                        Text(scene.name)
                        Spacer(minLength: 0)
                        Menu {
                            Button("New shot") { attempt { try store.createShot(in: scene.id) } }
                            Button("Rename scene…") { beginRename(.scene(scene.id), name: scene.name) }
                            Button("Duplicate scene") { attempt { try store.copyScene(scene.id) } }
                            Button("Delete scene", role: .destructive) { store.run(.deleteScene(scene.id)) }
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                        .menuStyle(.borderlessButton).fixedSize().disabled(store.isReadOnly)
                        .accessibilityLabel("Actions for scene \(scene.name)")
                    }
                }
            }
        }
        .listStyle(.sidebar).accessibilityLabel("Scenes and shots")
        .overlay {
            if store.document.scenes.isEmpty {
                Text("Start with a scene, then frame its shot.")
                    .font(.callout).foregroundStyle(.secondary).padding()
            }
        }
    }

    private func beginRename(_ target: RenameTarget, name: String) {
        proposedName = name
        renameTarget = target
    }

    private func finishRename() {
        let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let target = renameTarget else { return }
        switch target {
        case let .scene(id): store.run(.renameScene(id, name: name))
        case let .shot(id): store.run(.renameShot(id, name: name))
        }
        renameTarget = nil
    }

    private func importProject(_ result: Result<URL, any Error>) {
        do {
            let url = try result.get()
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let before = store.document.scenes.count
            importNotes = try store.importBlockoutProject(Data(contentsOf: url))
            let added = store.document.scenes.count - before
            importSummary = "Imported \(added) \(added == 1 ? "scene" : "scenes")."
        } catch CocoaError.userCancelled {
            // Cancelling the file picker is not an import failure.
        } catch {
            store.onError?(error.localizedDescription)
        }
    }

    private func attempt(_ action: () throws -> some Any) {
        do { _ = try action() } catch { store.onError?(error.localizedDescription) }
    }

    private enum RenameTarget {
        case scene(SceneID), shot(ShotID)
    }
}
