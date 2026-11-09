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
            Text("Actor mark").font(.headline).accessibilityAddTraits(.isHeader)
            ShotsMarkTimingFields(
                time: field(\.time), hold: field(\.hold), easeIn: field(\.easeIn), easeOut: field(\.easeOut),
                duration: shot.duration
            )
            ShotsPositionFields(position: field(\.position))
            Picker("Gait", selection: field(\.gait)) {
                ForEach(Gait.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .help("How the person moves on the way to this mark, and their pose while holding it.")
            Toggle("Set arrival heading", isOn: Binding(get: { mark.arriveHeading != nil }, set: { enabled in
                update { $0.arriveHeading = enabled ? (mark.arriveHeading ?? 0) : nil }
            }))
            .help("Choose which way the person faces here. Otherwise they face the way they walk.")
            if let heading = mark.arriveHeading {
                ShotsNumberField(title: "Heading (°)", value: Binding(get: { heading * 180 / .pi }, set: { value in
                    update { $0.arriveHeading = value * .pi / 180 }
                }), explanation: ShotsAccessibility.FieldHelp.arrivalHeading)
            }
            Picker("Motion", selection: $motionID) {
                ForEach(store.catalog.motions.filter { store.catalog.starter.motions.contains($0.id) }) {
                    Text($0.name).tag($0.id)
                }
            }
            .help("A ready-made body movement, such as a wave.")
            Button("Apply motion here") {
                store.run(.applyMotion(
                    shot.id,
                    entityID,
                    motionID: motionID,
                    atFrame: FrameGrid.frame(atTime: mark.time)
                ))
            }
            .help("Play the motion once from this mark's time. It replaces this mark and the ones after it.")
            Button("Apply motion as overlay") { store.run(.overlayMotion(shot.id, entityID, motionID: motionID)) }
                .help("Add an upper-body motion, such as a wave, while the person keeps walking their marks.")
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

/// Time, hold and eases, which actor and camera marks share.
struct ShotsMarkTimingFields: View {
    @Binding var time: Double
    @Binding var hold: Double
    @Binding var easeIn: Double
    @Binding var easeOut: Double
    let duration: Double

    var body: some View {
        ShotsNumberField(
            title: "Time (s)", value: $time, range: 0 ... duration, explanation: ShotsAccessibility.FieldHelp.time
        )
        ShotsNumberField(
            title: "Hold (s)", value: $hold, range: 0 ... duration, explanation: ShotsAccessibility.FieldHelp.hold
        )
        ShotsNumberField(
            title: "Ease in", value: $easeIn, range: 0 ... 1, explanation: ShotsAccessibility.FieldHelp.easeIn
        )
        ShotsNumberField(
            title: "Ease out", value: $easeOut, range: 0 ... 1, explanation: ShotsAccessibility.FieldHelp.easeOut
        )
    }
}

struct ShotsCameraMarkInspector: View {
    let store: ShotsStore
    let shot: Shot
    let mark: CameraMark

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Camera mark").font(.headline).accessibilityAddTraits(.isHeader)
            ShotsMarkTimingFields(
                time: field(\.time), hold: field(\.hold), easeIn: field(\.easeIn), easeOut: field(\.easeOut),
                duration: shot.duration
            )
            ShotsPositionFields(
                position: field(\.position), fromMount: shot.camera.rig == .carMount && shot.camera.mountID != nil
            )
            ShotsNumberField(title: "Pan (°)", value: degrees(\.pan), explanation: ShotsAccessibility.FieldHelp.pan)
            ShotsNumberField(title: "Tilt (°)", value: degrees(\.tilt), explanation: ShotsAccessibility.FieldHelp.tilt)
            ShotsNumberField(title: "Roll (°)", value: degrees(\.roll), explanation: ShotsAccessibility.FieldHelp.roll)
            ShotsNumberField(
                title: "Focal length (mm)", value: field(\.focalLength), range: 1 ... 1000,
                explanation: ShotsAccessibility.FieldHelp.focalLength
            )
            Toggle("Set focus distance", isOn: Binding(get: { mark.focusDistance != nil }, set: { enabled in
                var changed = mark
                changed.focusDistance = enabled ? (mark.focusDistance ?? 5) : nil
                store.run(.updateCameraMark(shot.id, changed), coalescing: true)
            }))
            .help("Choose one distance to keep sharp. Otherwise everything is sharp.")
            if let focus = mark.focusDistance {
                ShotsNumberField(title: "Focus (m)", value: Binding(get: { focus }, set: { value in
                    var changed = mark
                    changed.focusDistance = value
                    store.run(.updateCameraMark(shot.id, changed), coalescing: true)
                }), range: 0.01 ... 100_000, explanation: ShotsAccessibility.FieldHelp.focus)
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
