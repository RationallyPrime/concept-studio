import PrevisCore
import SwiftUI

/// Blockout Inspector.tsx:567–700, 874ff: immutable asset, editable placement and generator actions.
struct ShotsEntityInspector: View {
    let store: ShotsStore
    let entity: PrevisEntity
    let shot: Shot
    @State private var pathID = "walk-forward"
    @State private var duration = 2.0
    @State private var usesSpeed = false
    @State private var speed = 1.0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Entity").font(.headline)
            LabeledContent("Asset", value: store.catalog.asset(entity.assetID)?.name ?? entity.assetID)
            TextField("Name", text: Binding(get: { entity.name }, set: {
                store.run(.renameEntity(entity.id, name: $0), coalescing: true)
            }))
            TextField("Label", text: Binding(get: { entity.label?.text ?? "" }, set: { text in
                let label = text.isEmpty ? nil : EntityLabel(
                    text: text,
                    color: entity.label?.color ?? RGB(r: 1, g: 1, b: 1)
                )
                store.run(.setLabel(entity.id, label), coalescing: true)
            }))
            if let label = entity.label {
                Picker("Label colour", selection: Binding(get: { label.color }, set: {
                    store.run(.setLabel(entity.id, EntityLabel(text: label.text, color: $0)), coalescing: true)
                })) {
                    Text("Current").tag(label.color)
                    ForEach(Array(Self.swatches.enumerated()), id: \.offset) { _, swatch in
                        Text(swatch.name).tag(RGB(hex: swatch.hex))
                    }
                }
            }
            ShotsPositionFields(position: placement(\.position))
            ShotsNumberField(title: "Heading (°)", value: Binding(
                get: { entity.placement.heading * 180 / .pi }, set: {
                    var placement = entity.placement
                    placement.heading = $0 * .pi / 180
                    store.run(.setPlacement(entity.id, placement), coalescing: true)
                }
            ))
            ShotsNumberField(title: "Scale", value: placement(\.scale), range: 0.01 ... 100)
            Picker("Attach to", selection: Binding(
                get: { entity.attachment?.parentID ?? "" }, set: {
                    store.run(.attach(
                        child: entity.id,
                        parent: $0.isEmpty ? nil : $0,
                        shot: shot.id,
                        atFrame: store.playhead
                    ))
                }
            )) {
                Text("Nothing").tag("")
                ForEach(store.currentScene?.entities.filter { $0.id != entity.id } ?? []) { parent in
                    Text(parent.name).tag(parent.id)
                }
            }
            Button("Add mark here") {
                do { try store.addInspectorMark(for: entity.id) } catch { store.onError?(error.localizedDescription) }
            }
            .help("Add a mark at the playhead using this entity’s current position and facing.")
            Divider()
            Picker("Action path", selection: $pathID) {
                ForEach(store.catalog.actionPaths.filter { store.catalog.starter.actionPaths.contains($0.id) }) {
                    Text($0.name).tag($0.id)
                }
            }
            ShotsNumberField(title: "Duration (s)", value: $duration, range: 0.05 ... 3600)
            Toggle("Set speed", isOn: $usesSpeed)
            if usesSpeed { ShotsNumberField(title: "Speed (m/s)", value: $speed, range: 0.01 ... 1000) }
            Button("Apply action path") {
                store.run(.applyActionPath(
                    shot.id,
                    entity.id,
                    pathID: pathID,
                    atFrame: store.playhead,
                    duration: duration,
                    speed: usesSpeed ? speed : nil
                ))
            }
        }
    }

    private static let swatches = [
        (name: "Red", hex: "e5484d"), (name: "Orange", hex: "f5a524"),
        (name: "Green", hex: "46a758"), (name: "Blue", hex: "3b82f6"),
        (name: "Purple", hex: "a855f7"), (name: "Pink", hex: "ec4899"),
        (name: "Teal", hex: "14b8a6"), (name: "Rust", hex: "f97316"),
    ]

    private func placement<Value>(_ key: WritableKeyPath<Placement, Value>) -> Binding<Value> {
        Binding(get: { entity.placement[keyPath: key] }, set: { value in
            var placement = entity.placement
            placement[keyPath: key] = value
            store.run(.setPlacement(entity.id, placement), coalescing: true)
        })
    }
}
