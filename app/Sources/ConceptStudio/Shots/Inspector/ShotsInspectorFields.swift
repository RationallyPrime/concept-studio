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

    @MainActor mutating func preview(_ edit: ShotsCommand, in store: ShotsStore) {
        invalidateIfNeeded(in: store)
        if let preview = update(edit) { store.preview = preview }
    }

    @MainActor mutating func invalidateIfNeeded(in store: ShotsStore) {
        if let command, store.preview != command { cancel() }
    }

    @MainActor mutating func commit(in store: ShotsStore) {
        let ownsPreview = command != nil && store.preview == command
        let edit = finish()
        guard ownsPreview else { return }
        store.preview = nil
        if let edit { store.run(edit, coalescing: true) }
    }

    @MainActor mutating func cancel(in store: ShotsStore) {
        if let command, store.preview == command { store.preview = nil }
        cancel()
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
            gesture.preview(command(value), in: store)
        }), in: range, onEditingChanged: { editing in
            if !editing { commit() }
        }, label: { Text(title) })
            .onAppear { gesture = ShotsInspectorGesture() }
            .onChange(of: store.preview) { _, _ in
                gesture.invalidateIfNeeded(in: store)
                if gesture.command == nil { staged = nil }
            }
            .onExitCommand { cancel() }
            .onDisappear { cancel() }
    }

    private func commit() {
        gesture.commit(in: store)
        staged = nil
    }

    private func cancel() {
        gesture.cancel(in: store)
        staged = nil
    }
}
