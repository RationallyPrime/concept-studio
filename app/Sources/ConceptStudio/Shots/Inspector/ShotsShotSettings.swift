import PrevisCore
import SwiftUI

struct ShotsShotSettings: View {
    @Bindable var store: ShotsStore
    @State private var showsCustomCanvas = false

    var body: some View {
        if let shot = store.currentShot {
            VStack(alignment: .leading, spacing: 12) {
                Text(shot.name).font(.title3)
                    .accessibilityLabel("Shot \(shot.name)").accessibilityAddTraits(.isHeader)
                Stepper {
                    Text("\(shot.frameCount) frames")
                } onIncrement: {
                    if shot.frameCount <= Int.max - 17 { store.run(.setFrameCount(shot.id, shot.frameCount + 17)) }
                } onDecrement: {
                    if shot.frameCount > 5 { store.run(.setFrameCount(shot.id, shot.frameCount - 17)) }
                }
                .help("Shot length. The video model accepts lengths 17 frames apart, so it changes in steps of 17.")
                Text("\(shot.duration, specifier: "%.2f") seconds at 24 frames per second")
                    .font(.caption).foregroundStyle(.secondary)
                if !FrameGrid.trainedRange.contains(shot.frameCount) {
                    Label(
                        "The model was trained on 124–362 frames; other lengths may look worse.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .shotsAttention()
                }
                canvasSettings(shot)
                if let scene = store.currentScene {
                    Picker("Lighting", selection: Binding(
                        get: { scene.lighting }, set: { store.run(.setLighting(scene.id, $0)) }
                    )) {
                        ForEach(LightingPreset.allCases, id: \.self) { preset in
                            Text(lightingName(preset)).tag(preset)
                        }
                    }
                    .help("How the whole scene is lit in the scene view and the exported pictures.")
                }
            }
            .disabled(store.isReadOnly)
            .onChange(of: shot.id) { _, _ in showsCustomCanvas = false }
        } else {
            Text("Choose a shot to see its settings.").foregroundStyle(.secondary)
        }
    }

    private func canvasSettings(_ shot: Shot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Canvas", selection: Binding(
                get: { showsCustomCanvas ? -1 : ShotCanvas.presets.firstIndex(of: shot.canvas) ?? -1 },
                set: { index in
                    showsCustomCanvas = index == -1
                    if ShotCanvas.presets.indices.contains(index) {
                        store.run(.setCanvas(shot.id, ShotCanvas.presets[index]))
                    }
                }
            )) {
                ForEach(Array(ShotCanvas.presets.enumerated()), id: \.offset) { index, canvas in
                    Text(Self.canvasName(canvas)).tag(index)
                }
                Text("Custom").tag(-1)
            }
            .help("The exported picture size in pixels, width × height.")
            if showsCustomCanvas || !ShotCanvas.presets.contains(shot.canvas) {
                Stepper("Width: \(String(shot.canvas.width))", value: Binding(
                    get: { shot.canvas.width },
                    set: { store.run(.setCanvas(shot.id, ShotCanvas(width: $0, height: shot.canvas.height))) }
                ), in: 64 ... 2048, step: 32)
                Stepper("Height: \(String(shot.canvas.height))", value: Binding(
                    get: { shot.canvas.height },
                    set: { store.run(.setCanvas(shot.id, ShotCanvas(width: shot.canvas.width, height: $0))) }
                ), in: 64 ... 2048, step: 32)
                Text("Canvas dimensions use multiples of 32 pixels.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// "640 × 1152": pixel sizes never take locale digit grouping ("1,152").
    static func canvasName(_ canvas: ShotCanvas) -> String {
        "\(String(canvas.width)) × \(String(canvas.height))"
    }

    private func lightingName(_ preset: LightingPreset) -> String {
        switch preset {
        case .day: "Day"
        case .goldenHour: "Golden hour"
        case .night: "Night"
        case .interiorWarm: "Warm interior"
        case .interiorCool: "Cool interior"
        }
    }
}
