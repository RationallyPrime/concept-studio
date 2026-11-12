import PrevisCore
import SwiftUI
import UniformTypeIdentifiers

struct ShotsDialogueEditor: View {
    let store: ShotsStore
    let shot: Shot
    @State private var importing = false
    @State private var target: String?

    var body: some View {
        DisclosureGroup("Dialogue and scratch audio") {
            VStack(alignment: .leading, spacing: 10) {
                recording(shot.scratchAudio, lineID: nil)
                ForEach(shot.dialogue) { line in
                    Divider()
                    lineFields(line)
                }
                Button("Add dialogue at playhead", systemImage: "plus") {
                    let line = DialogueLine(id: store.newID("dialogue"), startFrame: store.playhead, text: "")
                    store.run(.setDialogue(shot.id, shot.dialogue + [line]))
                }
            }
            .padding(.vertical, 6)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.wav, .mpeg4Audio]) { result in
            let lineID = target
            Task { @MainActor in
                do {
                    try await store.importScratchAudio(from: result.get(), shotID: shot.id, lineID: lineID)
                } catch {
                    store.onError?(error.localizedDescription)
                }
            }
        }
    }

    private func lineFields(_ line: DialogueLine) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Speaker", selection: binding(line, \.speakerID)) {
                Text("Off-screen").tag(nil as EntityID?)
                ForEach(store.currentScene?.entities ?? []) { entity in
                    Text(entity.name).tag(Optional(entity.id))
                }
            }
            ShotsNumberField(title: "Start (s)", value: Binding(get: {
                FrameGrid.time(ofFrame: line.startFrame)
            }, set: { value in
                binding(line, \.startFrame).wrappedValue = FrameGrid.frame(atTime: value)
            }), range: 0 ... 3600)
            ShotsTextField(title: "Line", text: binding(line, \.text), multiline: true)
            recording(line.recording, lineID: line.id)
            Button("Remove line", role: .destructive) {
                store.run(.setDialogue(shot.id, shot.dialogue.filter { $0.id != line.id }))
            }
        }
    }

    private func recording(_ audio: ScratchRecording?, lineID: String?) -> some View {
        HStack {
            Button(audio == nil ? (lineID == nil ? "Import shot audio" : "Import line audio") : "Replace audio") {
                target = lineID
                importing = true
            }
            .disabled(store.audioDirectory == nil)
            if let audio {
                Text("\(audio.duration, specifier: "%.2f") s").monospacedDigit().foregroundStyle(.secondary)
                Button("Remove audio") {
                    if let line = shot.dialogue.first(where: { $0.id == lineID }) {
                        binding(line, \.recording).wrappedValue = nil
                    } else {
                        store.run(.setScratchAudio(shot.id, nil))
                    }
                }
            }
        }
    }

    private func binding<Value>(_ line: DialogueLine, _ key: WritableKeyPath<DialogueLine, Value>) -> Binding<Value> {
        Binding(get: { line[keyPath: key] }, set: { value in
            guard let current = store.document.scenes.lazy.compactMap({ $0.shots.first { $0.id == shot.id } }).first,
                  let index = current.dialogue.firstIndex(where: { $0.id == line.id }) else { return }
            var changed = current.dialogue
            changed[index][keyPath: key] = value
            store.run(.setDialogue(shot.id, changed), coalescing: true)
        })
    }
}
