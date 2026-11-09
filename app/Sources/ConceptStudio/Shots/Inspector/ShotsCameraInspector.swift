import PrevisCore
import SwiftUI

/// Blockout Inspector.tsx:1461ff: sensor/rig, aim-lock/mount and framing/move actions.
struct ShotsCameraInspector: View {
    let store: ShotsStore
    let shot: Shot
    @State private var moveID = "slow-push-in"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Camera").font(.headline).accessibilityAddTraits(.isHeader)
            Picker("Sensor", selection: Binding(get: { shot.camera.sensor }, set: {
                store.run(.setCameraRig(shot.id, sensor: $0, rig: shot.camera.rig, intensity: shot.camera.rigIntensity))
            })) {
                ForEach(Sensor.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .help("The camera's image size. A bigger sensor generally shows more of the scene with the same lens.")
            Picker("Rig", selection: Binding(get: { shot.camera.rig }, set: {
                store.run(.setCameraRig(
                    shot.id,
                    sensor: shot.camera.sensor,
                    rig: $0,
                    intensity: shot.camera.rigIntensity
                ))
            })) {
                ForEach(Rig.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .help("What holds the camera. It sets the kind of natural shake the camera has. "
                + "Car mount lets the camera ride on the entity chosen under Mount.")
            ShotsInspectorSlider(
                title: "Rig intensity",
                value: shot.camera.rigIntensity,
                range: 0 ... 1,
                store: store
            ) {
                .setCameraRig(shot.id, sensor: shot.camera.sensor, rig: shot.camera.rig, intensity: $0)
            }
            .help("How much the rig shakes the camera: 0 is perfectly steady.")
            Text("Aim lock").font(.subheadline).accessibilityAddTraits(.isHeader)
                .help("The camera keeps pointing at the chosen people or props, or at the middle of several.")
            ForEach(store.currentScene?.entities ?? []) { entity in
                Toggle(entity.name, isOn: Binding(get: { shot.camera.trackIDs.contains(entity.id) }, set: { included in
                    var targets = shot.camera.trackIDs.filter { $0 != entity.id }
                    if included { targets.append(entity.id) }
                    store.run(.setTracking(shot.id, targets))
                }))
                .accessibilityLabel("Aim camera at \(entity.name)")
            }
            Picker("Mount", selection: Binding(get: { shot.camera.mountID ?? "" }, set: {
                store.run(.setMount(shot.id, $0.isEmpty ? nil : $0))
            })) {
                Text("Nothing").tag("")
                ForEach(store.currentScene?.entities ?? []) { Text($0.name).tag($0.id) }
            }
            .help("With Rig set to Car mount, the camera rides on this person or prop, such as a car, "
                + "and its marks are measured from it. Other rigs ignore it.")
            Text("Framing").font(.subheadline).accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96))], alignment: .leading) {
                ForEach(Framing.Kind.allCases, id: \.self) { kind in
                    Button(kind.displayName) { store.applyFraming(kind) }
                        .disabled(store.currentScene?.entities.isEmpty ?? true)
                        .help(kind.explanation)
                }
            }
            Text(framingNote)
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("Camera move", selection: $moveID) {
                ForEach(store.catalog.cameraMoves.filter { store.catalog.starter.cameraMoves.contains($0.id) }) {
                    Text($0.name).tag($0.id)
                }
            }
            .help("A ready-made camera movement, such as a slow push in.")
            Button("Apply camera move") {
                store.run(.applyCameraMove(shot.id, moveID: moveID, subjects: shot.camera.trackIDs))
            }
            .help("Replace this shot's camera marks and aim lock with the chosen movement.")
        }
    }

    /// Who the framing buttons frame, and what aim lock does to the result (Blockout `SceneManager.ts`).
    private var framingNote: String {
        guard let scene = store.currentScene,
              let id = store.framingSubjects(for: .closeUp).first,
              let subject = scene.entities.first(where: { $0.id == id })
        else { return "Add a person or prop to use framing." }
        var note = "Wide, Full body, Medium and Close-up frame \(subject.name). "
            + "Select one person or prop to frame someone else; select two or more for the other framings, "
            + "which otherwise use every person. Each framing sets the camera at the playhead: it changes the "
            + "camera mark there, or adds one."
        if !shot.camera.trackIDs.isEmpty {
            note += " Aim lock is on, so it keeps choosing where the camera points and the framing sets only "
                + "where the camera stands. Turn aim lock off to keep the framing's aim."
        }
        return note
    }
}
