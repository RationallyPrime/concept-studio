import PrevisCore
import SwiftUI

/// Blockout Inspector.tsx:1671ff: edit the selected mark, preserve all unedited channels, show degrees.
struct ShotsActorMarkInspector: View {
    let store: ShotsStore
    let shot: Shot
    let entityID: EntityID
    let mark: ActorMark
    @State private var motionID = "wave"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Actor mark").font(.headline)
            ShotsNumberField(title: "Time (s)", value: field(\.time), range: 0 ... shot.duration)
            ShotsNumberField(title: "Hold (s)", value: field(\.hold), range: 0 ... shot.duration)
            ShotsNumberField(title: "Ease in", value: field(\.easeIn), range: 0 ... 1)
            ShotsNumberField(title: "Ease out", value: field(\.easeOut), range: 0 ... 1)
            ShotsPositionFields(position: field(\.position))
            Picker("Gait", selection: field(\.gait)) {
                ForEach(Gait.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            Toggle("Set arrival heading", isOn: Binding(get: { mark.arriveHeading != nil }, set: { enabled in
                update { $0.arriveHeading = enabled ? (mark.arriveHeading ?? 0) : nil }
            }))
            if let heading = mark.arriveHeading {
                ShotsNumberField(title: "Heading (°)", value: Binding(get: { heading * 180 / .pi }, set: { value in
                    update { $0.arriveHeading = value * .pi / 180 }
                }))
            }
            Picker("Motion", selection: $motionID) {
                ForEach(store.catalog.motions.filter { store.catalog.starter.motions.contains($0.id) }) {
                    Text($0.name).tag($0.id)
                }
            }
            Button("Apply motion here") {
                store.run(.applyMotion(
                    shot.id,
                    entityID,
                    motionID: motionID,
                    atFrame: FrameGrid.frame(atTime: mark.time)
                ))
            }
            Button("Apply motion as overlay") { store.run(.overlayMotion(shot.id, entityID, motionID: motionID)) }
        }
    }

    private func update(_ edit: (inout ActorMark) -> Void) {
        var changed = mark
        edit(&changed)
        store.run(.updateActorMark(shot.id, entityID, changed), coalescing: true)
    }

    private func field<Value>(_ key: WritableKeyPath<ActorMark, Value>) -> Binding<Value> {
        Binding(get: { mark[keyPath: key] }, set: { value in update { $0[keyPath: key] = value } })
    }
}

struct ShotsCameraMarkInspector: View {
    let store: ShotsStore
    let shot: Shot
    let mark: CameraMark

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Camera mark").font(.headline)
            ShotsNumberField(title: "Time (s)", value: field(\.time), range: 0 ... shot.duration)
            ShotsNumberField(title: "Hold (s)", value: field(\.hold), range: 0 ... shot.duration)
            ShotsNumberField(title: "Ease in", value: field(\.easeIn), range: 0 ... 1)
            ShotsNumberField(title: "Ease out", value: field(\.easeOut), range: 0 ... 1)
            ShotsPositionFields(position: field(\.position))
            ShotsNumberField(title: "Pan (°)", value: degrees(\.pan))
            ShotsNumberField(title: "Tilt (°)", value: degrees(\.tilt))
            ShotsNumberField(title: "Roll (°)", value: degrees(\.roll))
            ShotsNumberField(title: "Focal length (mm)", value: field(\.focalLength), range: 1 ... 1000)
            Toggle("Set focus distance", isOn: Binding(get: { mark.focusDistance != nil }, set: { enabled in
                var changed = mark
                changed.focusDistance = enabled ? (mark.focusDistance ?? 5) : nil
                store.run(.updateCameraMark(shot.id, changed), coalescing: true)
            }))
            if let focus = mark.focusDistance {
                ShotsNumberField(title: "Focus (m)", value: Binding(get: { focus }, set: { value in
                    var changed = mark
                    changed.focusDistance = value
                    store.run(.updateCameraMark(shot.id, changed), coalescing: true)
                }), range: 0.01 ... 100_000)
            }
        }
    }

    private func field<Value>(_ key: WritableKeyPath<CameraMark, Value>) -> Binding<Value> {
        Binding(get: { mark[keyPath: key] }, set: { value in
            var changed = mark
            changed[keyPath: key] = value
            store.run(.updateCameraMark(shot.id, changed), coalescing: true)
        })
    }

    private func degrees(_ key: WritableKeyPath<CameraMark, Double>) -> Binding<Double> {
        Binding(get: { mark[keyPath: key] * 180 / .pi }, set: { field(key).wrappedValue = $0 * .pi / 180 })
    }
}
