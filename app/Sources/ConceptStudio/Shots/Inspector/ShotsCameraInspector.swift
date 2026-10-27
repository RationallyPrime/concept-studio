import PrevisCore
import SwiftUI

/// Blockout Inspector.tsx:1461ff: sensor/rig, aim-lock/mount and framing/move actions.
struct ShotsCameraInspector: View {
    let store: ShotsStore
    let shot: Shot
    @State private var moveID = "slow-push-in"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Camera").font(.headline)
            Picker("Sensor", selection: Binding(get: { shot.camera.sensor }, set: {
                store.run(.setCameraRig(shot.id, sensor: $0, rig: shot.camera.rig, intensity: shot.camera.rigIntensity))
            })) {
                ForEach(Sensor.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            Picker("Rig", selection: Binding(get: { shot.camera.rig }, set: {
                store.run(.setCameraRig(
                    shot.id,
                    sensor: shot.camera.sensor,
                    rig: $0,
                    intensity: shot.camera.rigIntensity
                ))
            })) {
                ForEach(Rig.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            ShotsInspectorSlider(
                title: "Rig intensity",
                value: shot.camera.rigIntensity,
                range: 0 ... 1,
                store: store
            ) {
                .setCameraRig(shot.id, sensor: shot.camera.sensor, rig: shot.camera.rig, intensity: $0)
            }
            Text("Aim lock").font(.subheadline)
            ForEach(store.currentScene?.entities ?? []) { entity in
                Toggle(entity.name, isOn: Binding(get: { shot.camera.trackIDs.contains(entity.id) }, set: { included in
                    var targets = shot.camera.trackIDs.filter { $0 != entity.id }
                    if included { targets.append(entity.id) }
                    store.run(.setTracking(shot.id, targets))
                }))
            }
            Picker("Mount", selection: Binding(get: { shot.camera.mountID ?? "" }, set: {
                store.run(.setMount(shot.id, $0.isEmpty ? nil : $0))
            })) {
                Text("Nothing").tag("")
                ForEach(store.currentScene?.entities ?? []) { Text($0.name).tag($0.id) }
            }
            Text("Framing").font(.subheadline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 70))]) {
                ForEach(Framing.Kind.allCases, id: \.self) { kind in
                    Button(kind.rawValue) {
                        store.run(.applyFraming(shot.id, kind, subjects: shot.camera.trackIDs, atFrame: store.playhead))
                    }.disabled(shot.camera.trackIDs.isEmpty)
                }
            }
            Text("Choose aim-lock subjects to frame them.").font(.caption).foregroundStyle(.secondary)
            Picker("Camera move", selection: $moveID) {
                ForEach(store.catalog.cameraMoves.filter { store.catalog.starter.cameraMoves.contains($0.id) }) {
                    Text($0.name).tag($0.id)
                }
            }
            Button("Apply camera move") {
                store.run(.applyCameraMove(shot.id, moveID: moveID, subjects: shot.camera.trackIDs))
            }
        }
    }
}
