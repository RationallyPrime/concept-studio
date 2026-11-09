import PrevisCore
import SwiftUI

struct ShotsNumberField: View {
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double> = -100_000 ... 100_000
    /// What the number means, for a reader with no film or 3D background. Shown on hover and read by VoiceOver.
    var explanation: String?

    var body: some View {
        LabeledContent(title) {
            TextField(title, value: Binding(get: { value }, set: {
                guard $0.isFinite else { return }
                value = min(max($0, range.lowerBound), range.upperBound)
            }), format: .number.precision(.fractionLength(0 ... 3)))
                .textFieldStyle(.roundedBorder).labelsHidden()
                .accessibilityLabel(ShotsAccessibility.spokenTitle(title))
        }
        .help(explanation ?? ShotsAccessibility.fieldExplanation(title) ?? "")
    }
}

/// A text field that keeps its name beside it once it has text, unlike a bare macOS placeholder.
struct ShotsTextField: View {
    let title: String
    @Binding var text: String
    var explanation: String?
    var multiline = false

    var body: some View {
        Group {
            if multiline {
                // Notes get the column's full width, with their name above.
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).accessibilityHidden(true)
                    field.lineLimit(2 ... 6)
                }
            } else {
                LabeledContent(title) { field }
            }
        }
        .help(explanation ?? "")
    }

    private var field: some View {
        TextField(title, text: $text, axis: multiline ? .vertical : .horizontal)
            .textFieldStyle(.roundedBorder).labelsHidden()
            .accessibilityLabel(title)
    }
}

struct ShotsPositionFields: View {
    @Binding var position: Vec3

    var body: some View {
        ShotsNumberField(title: "X (m)", value: $position.x, explanation: "Left and right across the stage, in metres.")
        ShotsNumberField(title: "Y (m)", value: $position.y, explanation: "Height above the ground, in metres.")
        ShotsNumberField(title: "Z (m)", value: $position.z, explanation: "Toward and away from the front, in metres.")
    }
}

extension View {
    /// The Instant Print "Needs attention" treatment: pink slip, dark red words, readable in both appearances.
    func shotsAttention() -> some View {
        font(.caption).foregroundStyle(InstantPrint.attentionText)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(InstantPrint.attention, in: RoundedRectangle(cornerRadius: 5))
            .fixedSize(horizontal: false, vertical: true)
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
