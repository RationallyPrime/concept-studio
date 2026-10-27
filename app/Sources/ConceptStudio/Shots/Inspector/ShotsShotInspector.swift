import PrevisCore
import ShotsMedia
import SwiftUI

/// Blockout's SceneInspector/shot notes are adapted to the agreed per-shot notes and H3 compiler seam.
struct ShotsShotInspector: View {
    let store: ShotsStore
    let session: StudioSession
    let shot: Shot
    @State private var promptTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ShotsShotSettings(store: store)
            Divider()
            Text("Guide frames").font(.headline)
            ForEach(shot.guideFrames, id: \.self) { frame in
                HStack {
                    Text("Frame \(frame)")
                    Spacer()
                    Button("Remove") {
                        store.run(.setGuideFrames(shot.id, shot.guideFrames.filter { $0 != frame }))
                    }.accessibilityLabel("Remove guide frame \(frame)")
                }
            }
            Button("Add guide frame here") { store.addGuideAtPlayhead() }
                .disabled(!store.canAddGuideAtPlayhead)
            Divider()
            TextField("Setting and action", text: notes(\.description), axis: .vertical)
            ForEach(store.currentScene?.entities.filter { $0.assetID.hasPrefix("person.") } ?? []) { entity in
                TextField("\(entity.name) appearance", text: Binding(get: {
                    shot.notes.characters.first { $0.entityID == entity.id }?.appearance ?? ""
                }, set: { appearance in
                    var changed = shot.notes
                    changed.characters.removeAll { $0.entityID == entity.id }
                    if !appearance.isEmpty { changed.characters.append(CharacterNote(
                        entityID: entity.id,
                        appearance: appearance
                    )) }
                    store.run(.setNotes(shot.id, changed), coalescing: true)
                }), axis: .vertical)
            }
            TextField("Sound", text: notes(\.sound), axis: .vertical)
            TextField("Music", text: notes(\.music), axis: .vertical)
            Divider()
            if let prompt = shot.prompt {
                Text(prompt.text).font(.callout).textSelection(.enabled)
                if prompt.sceneRevision < (store.currentScene?.revision ?? 0) {
                    Label("Older than the blocking", systemImage: "clock.arrow.circlepath")
                        .font(.caption).foregroundStyle(InstantPrint.attentionText)
                }
            }
            Button("Write H3 prompt") { writePrompt() }.disabled(promptTask != nil)
            if promptTask != nil {
                ProgressView("Writing prompt…")
                Button("Cancel") { promptTask?.cancel() }
            }
        }
        .onDisappear { promptTask?.cancel() }
        .onChange(of: shot.id) { _, _ in promptTask?.cancel() }
    }

    private func notes(_ key: WritableKeyPath<ShotNotes, String>) -> Binding<String> {
        Binding(get: { shot.notes[keyPath: key] }, set: { value in
            var changed = shot.notes
            changed[keyPath: key] = value
            store.run(.setNotes(shot.id, changed), coalescing: true)
        })
    }

    private func writePrompt() {
        guard promptTask == nil else { return }
        promptTask = Task { @MainActor in
            defer { promptTask = nil }
            do {
                try await ShotsPromptAction.write(store: store) { facts in
                    if session.demoMode || session.modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return ShotPromptCompiler.template(facts)
                    }
                    return try await ShotPromptCompiler.write(facts, endpoint: session.endpoint())
                }
            } catch is CancellationError {
                // Cancellation intentionally leaves the previous prompt intact.
            } catch {
                store.onError?(error.localizedDescription)
            }
        }
    }
}
