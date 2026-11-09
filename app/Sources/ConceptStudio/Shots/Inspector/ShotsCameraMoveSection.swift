import PrevisCore
import SwiftUI

/// The camera-move picker, in the camera inspector and in the inspector of a selected person or prop, because the
/// move is built around a subject taken from the selection (Blockout `Inspector.tsx` 1410-1457, `SceneManager.ts`
/// `applyCameraMove`; see `ShotsFramingSubjects.cameraMoveSubject`).
struct ShotsCameraMoveSection: View {
    let store: ShotsStore
    @State private var moveID = "slow-push-in"

    var body: some View {
        Picker("Camera move", selection: $moveID) {
            ForEach(store.catalog.cameraMoves.filter { store.catalog.starter.cameraMoves.contains($0.id) }) {
                Text($0.name).tag($0.id)
            }
        }
        .help("A ready-made camera movement, such as a slow push in.")
        Button("Apply camera move") { store.applyCameraMove(moveID) }
            .disabled(subjectName == nil)
            .help("Replace this shot's camera marks with the chosen movement, built around the subject named below. "
                + "A move that follows the subject turns aim lock on for it; any other move turns aim lock off.")
        Text(note)
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private var subjectName: String? {
        guard let id = store.cameraMoveSubject else { return nil }
        return store.currentScene?.entities.first { $0.id == id }?.name
    }

    private var note: String {
        guard let name = subjectName else { return "Add a person or prop to build a camera move around." }
        return "Camera moves are built around \(name): the first of two or more selected people or props, "
            + "otherwise the scene's first person."
    }
}
