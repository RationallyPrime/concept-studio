import Foundation
import PrevisCore
import SwiftUI

/// The framing buttons, in the camera inspector and in the inspector of a selected person or prop. Blockout keeps them
/// reachable whatever is selected (the viewport's shot-size and framing rows, `Viewport.tsx` 101-155, and the pinned
/// Camera tab, `Inspector.tsx` 69-77), because they frame the selection (`ShotsFramingSubjects`).
struct ShotsFramingSection: View {
    let store: ShotsStore
    let shot: Shot

    var body: some View {
        Text("Framing").font(.subheadline).accessibilityAddTraits(.isHeader)
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96))], alignment: .leading) {
            ForEach(Framing.Kind.allCases, id: \.self) { kind in
                Button(kind.displayName) { store.applyFraming(kind) }
                    .disabled(store.currentScene?.entities.isEmpty ?? true)
                    .help(kind.explanation)
            }
        }
        Text(note)
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    /// Who the buttons frame now, how to choose, and what aim lock does to the result.
    private var note: String {
        guard let scene = store.currentScene else { return "Add a person or prop to use framing." }
        func names(_ kind: Framing.Kind) -> String {
            let names = store.framingSubjects(for: kind).compactMap { id in scene.entities.first { $0.id == id }?.name }
            return ListFormatter.localizedString(byJoining: names)
        }
        let sized = names(.closeUp)
        guard !sized.isEmpty else { return "Add a person or prop to use framing." }
        var note = "Wide, Full body, Medium and Close-up frame \(sized); the other framings use \(names(.twoShot)). "
            + "To choose, select one person or prop for the first four, or Shift-click two or more in the scene "
            + "view for the others. Each framing sets the camera at the playhead: it changes the camera mark there, "
            + "or adds one."
        if !shot.camera.trackIDs.isEmpty {
            note += " Aim lock is on, so it keeps choosing where the camera points: a framing sets where the camera "
                + "stands (and Dutch angle its roll). Turn aim lock off to keep the framing's aim."
        }
        return note
    }
}
