import PrevisCore
import SwiftUI

struct ShotsNumberField: View {
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double> = -100_000 ... 100_000

    var body: some View {
        LabeledContent(title) {
            TextField(title, value: Binding(get: { value }, set: {
                guard $0.isFinite else { return }
                value = min(max($0, range.lowerBound), range.upperBound)
            }), format: .number.precision(.fractionLength(0 ... 3)))
                .textFieldStyle(.roundedBorder).labelsHidden()
                .accessibilityLabel(title)
        }
    }
}

struct ShotsPositionFields: View {
    @Binding var position: Vec3

    var body: some View {
        ShotsNumberField(title: "X (m)", value: $position.x)
        ShotsNumberField(title: "Y (m)", value: $position.y)
        ShotsNumberField(title: "Z (m)", value: $position.z)
    }
}

/// A drag updates transient preview only; cancellation remains latched until release.
struct ShotsInspectorGesture {
    private var cancelled = false
    private(set) var command: ShotsCommand?

    mutating func update(_ command: ShotsCommand) -> ShotsCommand? {
        guard !cancelled else { return nil }
        self.command = command
        return command
    }

    mutating func cancel() {
        guard command != nil else { return }
        cancelled = true
        command = nil
    }

    mutating func finish() -> ShotsCommand? {
        defer { self = Self() }
        return cancelled ? nil : command
    }
}

struct ShotsInspectorSlider: View {
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    let store: ShotsStore
    let command: (Double) -> ShotsCommand
    @State private var gesture = ShotsInspectorGesture()
    @State private var staged: Double?

    var body: some View {
        Slider(value: Binding(get: { staged ?? value }, set: { value in
            staged = value
            if let preview = gesture.update(command(value)) { store.preview = preview }
        }), in: range, onEditingChanged: { editing in
            if !editing { commit() }
        }, label: { Text(title) })
            .onAppear { gesture = ShotsInspectorGesture() }
            .onExitCommand { cancel() }
            .onDisappear { cancel() }
    }

    private func commit() {
        let pending = gesture.command
        let edit = gesture.finish()
        if store.preview == pending { store.preview = nil }
        staged = nil
        if let edit { store.run(edit, coalescing: true) }
    }

    private func cancel() {
        if store.preview == gesture.command { store.preview = nil }
        gesture.cancel()
        staged = nil
    }
}
