import PrevisCore
import SwiftUI

struct ShotsFormationInspector: View {
    let store: ShotsStore
    let entity: PrevisEntity
    let formation: Formation
    @State private var name = ""
    @State private var row = 1
    @State private var column = 1
    @State private var assetID: String?

    var body: some View {
        Stepper("Rows: \(formation.rows)", value: setting(\.rows), in: Formation.dimensionRange)
        Stepper("Columns: \(formation.columns)", value: setting(\.columns), in: Formation.dimensionRange)
        ShotsNumberField(title: "Row spacing (m)", value: setting(\.rowSpacing), range: 0.01 ... 100)
        ShotsNumberField(title: "Column spacing (m)", value: setting(\.columnSpacing), range: 0.01 ... 100)
        ForEach(members) { member in
            if let slot = member.formationSlot {
                LabeledContent("Row \(slot.row), column \(slot.column)") {
                    Button(member.name) { store.selection = .entities([member.id]) }.buttonStyle(.link)
                }
            }
        }
        DisclosureGroup("Add named member") {
            ShotsTextField(title: "Member name", text: $name)
            Stepper("Row: \(slot.row)", value: position($row, limit: formation.rows), in: 1 ... formation.rows)
            Stepper(
                "Column: \(slot.column)",
                value: position($column, limit: formation.columns),
                in: 1 ... formation.columns
            )
            Picker("Person", selection: Binding(get: { assetID ?? entity.assetID }, set: { assetID = $0 })) {
                ForEach(store.libraryAssets(matching: "").filter { $0.rig == .person }) { person in
                    Text(person.name).tag(person.id)
                }
            }
            if occupied {
                Text("This place already has a named member.").font(.caption).foregroundStyle(.secondary)
            }
            Button("Add member") {
                do {
                    try store.addNamedMember(slot, assetID: assetID ?? entity.assetID, name: trimmedName)
                    name = ""
                } catch { store.onError?(error.localizedDescription) }
            }
            .disabled(trimmedName.isEmpty || occupied)
        }
    }

    private var members: [PrevisEntity] {
        store.currentScene?.entities.filter { $0.formationSlot?.formationID == entity.id } ?? []
    }

    private var slot: FormationSlot {
        FormationSlot(formationID: entity.id, row: min(row, formation.rows), column: min(column, formation.columns))
    }

    private var occupied: Bool {
        members.contains { $0.formationSlot == slot }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func setting<Value>(_ key: WritableKeyPath<Formation, Value>) -> Binding<Value> {
        Binding(get: { formation[keyPath: key] }, set: {
            var updated = formation
            updated[keyPath: key] = $0
            store.run(.setFormation(entity.id, updated), coalescing: true)
        })
    }

    private func position(_ value: Binding<Int>, limit: Int) -> Binding<Int> {
        Binding(get: { min(value.wrappedValue, limit) }, set: { value.wrappedValue = $0 })
    }
}
