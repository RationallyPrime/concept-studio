import PrevisCore
import ShotsMedia
import SwiftUI

/// Blocking from a written description: paste rows of a scene sheet's shot table, and each becomes a shot on the
/// plate with its characters placed. The result is a first pass to look at and correct, and one undo step.
struct ShotsBlockingSheet: View {
    @Bindable var store: ShotsStore
    let session: StudioSession
    let sceneID: SceneID
    let onClose: () -> Void
    @State private var text = ""
    @State private var usesModel = true
    @State private var task: Task<Void, Never>?
    @State private var outcome: [ShotsBlocking.Outcome] = []
    @State private var failure: String?

    private var hasModel: Bool {
        !session.demoMode && !session.modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Block shots from a description").font(.title3).accessibilityAddTraits(.isHeader)
            Text(
                "Write one shot per line, starting with its name: who is in frame, where across the frame, behind "
                    + "or on which set piece, how much of them shows and which way they face. Each line becomes a "
                    + "shot over the scene's plate. Use the names of the scene's characters and set pieces."
            )
            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text)
                .font(.body).frame(minHeight: 150)
                .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.2)) }
                .accessibilityLabel("Shot descriptions, one per line")
            Text("Example: 12A plate C, medium-full. Ada frame left behind the Long table, facing Ben. "
                + "Ben frame right behind the Long table, facing Ada.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Toggle("Read the description with the language model", isOn: $usesModel)
                .disabled(!hasModel)
                .help(hasModel
                    ? "On: the model chosen in Settings reads the description. Off: Shots reads it itself, which "
                    + "needs the frame words spelled out, such as \"frame left\" and \"behind the\"."
                    : "No language model is chosen in Settings, so Shots reads the description itself. Spell out "
                    + "the frame words, such as \"frame left\" and \"behind the\".")
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle").shotsAttention()
            }
            if !outcome.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(outcome, id: \.shotID) { result in
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Blocked \(result.shotName): \(result.summary)").font(.callout)
                                ForEach(result.notes, id: \.self) { note in
                                    Label(note, systemImage: "exclamationmark.triangle").shotsAttention()
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 180)
            }
            HStack {
                if task != nil {
                    ProgressView().controlSize(.small)
                    Text("Reading the description…").font(.caption)
                }
                Spacer()
                Button(outcome.isEmpty ? "Cancel" : "Done", role: .cancel) {
                    task?.cancel()
                    onClose()
                }
                .keyboardShortcut(.cancelAction)
                Button("Block these shots") { block() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(task != nil || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Make or re-block the shots named here, as one step you can undo.")
            }
        }
        .padding(16)
        .frame(minWidth: 560, idealWidth: 640, minHeight: 420)
        .onDisappear { task?.cancel() }
    }

    private func block() {
        guard task == nil else { return }
        failure = nil
        let rows = ShotsBlocking.rows(in: text)
        let withModel = usesModel && hasModel
        task = Task { @MainActor in
            defer { task = nil }
            do {
                outcome = try await ShotsBlocking.block(rows: rows, sceneID: sceneID, in: store) { row, scene in
                    if withModel {
                        return try await ShotBlockingWriter.read(row, scene: scene, endpoint: session.endpoint())
                    }
                    return BlockingReader.brief(from: row, scene: scene)
                }
                AccessibilityNotification.Announcement("Blocked \(outcome.count) shots.").post()
            } catch is CancellationError {
                // Cancelling leaves the scene as it was.
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}

/// Applying written descriptions to a scene.
@MainActor enum ShotsBlocking {
    struct Outcome: Equatable {
        var shotID: ShotID
        var shotName: String
        var summary: String
        var notes: [String]
    }

    /// One row per non-empty line.
    static func rows(in text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Reads each row into a brief and blocks it, all on a copy of the scene; the store takes the result as one
    /// undo step, or nothing when any row fails.
    static func block(
        rows: [String], sceneID: SceneID, in store: ShotsStore,
        read: (String, PrevisScene) async throws -> BlockingBrief
    ) async throws -> [Outcome] {
        guard !store.isReadOnly else { throw ShotsEditingError.readOnly }
        guard var scene = store.document.scenes.first(where: { $0.id == sceneID }) else {
            throw ShotsEditingError.missing("scene")
        }
        let revision = scene.revision
        var outcomes: [Outcome] = []
        for row in rows {
            let brief = try await read(row, scene)
            try Task.checkCancellation()
            let result = try BlockingSolver.apply(brief, to: &scene, catalog: store.catalog)
            let staging = try ShotEvaluator(scene: scene, shotID: result.shotID, catalog: store.catalog).staging()
            outcomes.append(Outcome(
                shotID: result.shotID, shotName: brief.shot,
                summary: staging.framing + ". " + staging.characters.map { character in
                    "\(character.name) \(character.horizontal.rawValue), \(character.extentPhrase)"
                }.joined(separator: "; ") + ".",
                notes: result.notes
            ))
        }
        // The scene must be the one that was read: an edit made while the model was reading would be lost.
        guard store.document.scenes.first(where: { $0.id == sceneID })?.revision == revision else {
            throw ShotsMediaError("The scene changed while its description was being read. Block the shots again.")
        }
        try store.perform(.replaceScene(scene))
        if let last = outcomes.last { store.selectShot(last.shotID) }
        return outcomes
    }
}
