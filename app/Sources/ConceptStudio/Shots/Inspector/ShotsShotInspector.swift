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
            Text("Guide frames").font(.headline).accessibilityAddTraits(.isHeader)
                .help("Frames exported as still pictures to steer the video. The first and last frames always are.")
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
            Text("Shot notes").font(.headline).accessibilityAddTraits(.isHeader)
            Text("Describe what the blocking can't show. The prompt is written from these notes and the blocking.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ShotsTextField(
                title: "Setting and action", text: notes(\.description),
                explanation: "Where the shot happens and what the people do.", multiline: true
            )
            ForEach(store.currentScene?.entities.filter { $0.assetID.hasPrefix("person.") } ?? []) { entity in
                ShotsTextField(title: "\(entity.name) appearance", text: Binding(get: {
                    shot.notes.characters.first { $0.entityID == entity.id }?.appearance ?? ""
                }, set: { appearance in
                    var changed = shot.notes
                    changed.characters.removeAll { $0.entityID == entity.id }
                    if !appearance.isEmpty { changed.characters.append(CharacterNote(
                        entityID: entity.id,
                        appearance: appearance
                    )) }
                    store.run(.setNotes(shot.id, changed), coalescing: true)
                }), explanation: "Clothes, hair and other looks the stand-in figure can't show.", multiline: true)
            }
            ShotsTextField(
                title: "Sound", text: notes(\.sound),
                explanation: "Sounds heard in the shot, such as rain or footsteps.", multiline: true
            )
            ShotsTextField(title: "Music", text: notes(\.music), explanation: "Music, if any.", multiline: true)
            Divider()
            Text("H3 prompt").font(.headline).accessibilityAddTraits(.isHeader)
            if let prompt = shot.prompt {
                Text(prompt.text).font(.callout).textSelection(.enabled)
                if prompt.sceneRevision < (store.currentScene?.revision ?? 0) {
                    Label(
                        "Older than the blocking. Write it again to include the latest changes.",
                        systemImage: "clock.arrow.circlepath"
                    )
                    .shotsAttention()
                }
            } else {
                Text("The written description of this shot that the H3 video model reads. It goes in the shot package.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Button(shot.prompt == nil ? "Write H3 prompt" : "Write H3 prompt again") { writePrompt() }
                .disabled(promptTask != nil)
                .help("Write the prompt from the blocking and notes with the language model chosen in Settings. "
                    + "Demo projects and projects without a model use a fixed template.")
            if promptTask != nil {
                ProgressView("Writing prompt…")
                Button("Cancel") { promptTask?.cancel() }.accessibilityLabel("Cancel writing the prompt")
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
                AccessibilityNotification.Announcement("H3 prompt written.").post()
            } catch is CancellationError {
                // Cancellation intentionally leaves the previous prompt intact.
            } catch {
                store.onError?(error.localizedDescription)
            }
        }
    }
}
