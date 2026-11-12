import PrevisCore
import SwiftUI

struct ShotsSetPieceInspector: View {
    let store: ShotsStore
    let entity: PrevisEntity
    let piece: SetPiece

    var body: some View {
        ShotsNumberField(title: "Width (m)", value: dimension(\.width), range: 0.01 ... 1000)
        ShotsNumberField(title: "Height (m)", value: dimension(\.height), range: 0.01 ... 1000)
        ShotsNumberField(title: "Depth (m)", value: dimension(\.depth), range: 0.01 ... 1000)
        if entity.assetID == "prim.wall" {
            ShotsNumberField(
                title: "Curve (°)", value: Binding(
                    get: { piece.wallSweep * 180 / .pi },
                    set: { update(\.wallSweep, $0 * .pi / 180) }
                ), range: 0 ... 180,
                explanation: "Bend the wall along its width. Zero makes a straight wall."
            )
            Toggle("Battlements", isOn: Binding(
                get: { piece.crenellated }, set: { update(\.crenellated, $0) }
            ))
        }
    }

    private func dimension(_ key: WritableKeyPath<SetPiece, Double>) -> Binding<Double> {
        Binding(get: { piece[keyPath: key] * entity.placement.scale }, set: {
            update(key, $0 / entity.placement.scale)
        })
    }

    private func update<Value>(_ key: WritableKeyPath<SetPiece, Value>, _ value: Value) {
        var updated = piece
        updated[keyPath: key] = value
        store.run(.setSetPiece(entity.id, updated), coalescing: true)
    }
}
