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
            Text(entity.formation == nil ? "Entity" : "Formation").font(.headline).accessibilityAddTraits(.isHeader)
            LabeledContent("Asset", value: store.catalog.asset(entity.assetID)?.name ?? entity.assetID)
            ShotsTextField(title: "Name", text: Binding(get: { entity.name }, set: {
                store.run(.renameEntity(entity.id, name: $0), coalescing: true)
            }))
            ShotsTextField(
                title: "Label",
                text: Binding(get: { entity.label?.text ?? "" }, set: { text in
                    let label = text.isEmpty ? nil : EntityLabel(
                        text: text,
                        color: entity.label?.color ?? RGB(r: 1, g: 1, b: 1)
                    )
                    store.run(.setLabel(entity.id, label), coalescing: true)
                }),
                explanation: "A short tag, such as W, that names this entity's timeline row. Its colour marks its path "
                    + "in the scene view and its box in the exported layout pictures."
            )
            if let label = entity.label {
                Picker("Label colour", selection: Binding(get: { label.color }, set: {
                    store.run(.setLabel(entity.id, EntityLabel(text: label.text, color: $0)), coalescing: true)
                })) {
                    Text("Current").tag(label.color)
                    ForEach(Array(Self.swatches.enumerated()), id: \.offset) { _, swatch in
                        Text(swatch.name).tag(RGB(hex: swatch.hex))
                    }
                }
                .help("The colour of this entity's path in the scene view and its box in the layout pictures.")
            }
            if let formation = entity.formation {
                ShotsFormationInspector(store: store, entity: entity, formation: formation)
            }
            if let slot = entity.formationSlot,
               let parent = store.currentScene?.entities.first(where: { $0.id == slot.formationID }) {
                LabeledContent("Formation") {
                    Button(parent.name) { store.selection = .entities([parent.id]) }
                        .buttonStyle(.link)
                }
            }
            if !isInFormation {
                placementFields
                if let asset = store.catalog.asset(entity.assetID),
                   let piece = entity.setPiece ?? SetPiece.standard(for: asset) {
                    ShotsSetPieceInspector(store: store, entity: entity, piece: piece)
                }
            }
            Button(isInFormation ? "Leave formation here" : "Add mark here") {
                do { try store.addInspectorMark(for: entity.id) } catch { store.onError?(error.localizedDescription) }
            }
            .help(isInFormation
                ? "Start this member's own track at the playhead."
                : "Add a mark at the playhead using this entity’s current position and facing.")
            Divider()
            if !isInFormation {
                actionPath
                Divider()
            }
            ShotsFramingSection(store: store, shot: shot)
            ShotsCameraMoveSection(store: store)
        }
    }

    private var isInFormation: Bool {
        store.frame?.entities.first { $0.id == entity.id }?.formationID != nil
    }

    @ViewBuilder private var placementFields: some View {
        ShotsPositionFields(position: placement(\.position))
        ShotsNumberField(title: "Heading (°)", value: Binding(
            get: { entity.placement.heading * 180 / .pi }, set: {
                var placement = entity.placement
                placement.heading = $0 * .pi / 180
                store.run(.setPlacement(entity.id, placement), coalescing: true)
            }
        ), explanation: "Which way it faces before its first mark, in degrees.")
        ShotsNumberField(
            title: "Scale", value: placement(\.scale), range: 0.01 ... 100,
            explanation: "Size compared with the asset's normal size, which is 1."
        )
        if entity.formationSlot == nil {
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
            .help("Carry this entity with another, such as a bag held by a person, until this entity's own first mark.")
        }
    }

    @ViewBuilder private var actionPath: some View {
        Picker("Action path", selection: $pathID) {
            ForEach(store.catalog.actionPaths.filter { store.catalog.starter.actionPaths.contains($0.id) }) {
                Text($0.name).tag($0.id)
            }
        }
        .help("A ready-made route, such as walking forward.")
        ShotsNumberField(
            title: "Duration (s)", value: $duration, range: 0.05 ... 3600,
            explanation: "How long the route takes, in seconds. With Set speed on, the speed decides instead."
        )
        Toggle("Set speed", isOn: $usesSpeed)
            .help("Time the route by walking speed instead of by duration.")
        if usesSpeed {
            ShotsNumberField(
                title: "Speed (m/s)", value: $speed, range: 0.01 ... 1000,
                explanation: "Average travel speed in metres per second. The route is retimed to match it."
            )
        }
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
        .help("Replace this entity's marks with the route. It starts at the playhead, from the entity's placement.")
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
