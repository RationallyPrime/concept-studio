import PrevisCore
import SwiftUI

struct ShotsSceneEditInspector: View {
    let store: ShotsStore
    let shot: Shot

    var body: some View {
        DisclosureGroup("Scene edit") {
            ShotsNumberField(
                title: "Edit length (frames)", value: Binding(get: { Double(shot.editFrames) }, set: {
                    store.run(.setEditFrameCount(shot.id, Int($0.rounded())), coalescing: true)
                }), range: 1 ... Double(max(1, shot.frameCount)),
                explanation: "Keep this many frames from the start of the shot in the scene cut."
            )
            if let shots = store.currentScene?.shots, let index = shots.firstIndex(where: { $0.id == shot.id }) {
                LabeledContent("Scene position", value: "\(index + 1) of \(shots.count)")
                HStack {
                    Button("Earlier") { store.run(.moveShot(shot.id, by: -1)) }.disabled(index == 0)
                    Button("Later") { store.run(.moveShot(shot.id, by: 1)) }.disabled(index + 1 == shots.count)
                }
            }
        }
    }
}
