import CoreGraphics
import PrevisCore

/// The one canonical look shared by the editor viewport and every export, so a preview matches what ships.
public struct PrevisLook: Sendable, Equatable {
    public var lighting: LightingPreset

    public init(lighting: LightingPreset) {
        self.lighting = lighting
    }

    public init(scene: PrevisScene) {
        lighting = scene.lighting
    }

    var palette: LookPalette {
        LookPalette(lighting)
    }
}

/// Colours and lights for one lighting preset. RealityKit has no ambient term, so three directional lights
/// (key, fill and a low bounce) keep every face of a grey box readable. The hues follow Blockout's presets.
struct LookPalette: Equatable {
    struct Light: Equatable {
        var color: RGB
        var intensity: Float // lux
        var from: SIMD3<Float> // the light shines from here toward the origin
    }

    var background: RGB
    var ground: RGB
    var lights: [Light]

    init(_ lighting: LightingPreset) {
        let key = SIMD3<Float>(4, 7, 5), fill = SIMD3<Float>(-5, 3, -2), bounce = SIMD3<Float>(1, -2, 6)
        switch lighting {
        case .day:
            background = RGB(hex: "#394048")
            ground = RGB(hex: "#4a5058")
            lights = [
                Light(color: RGB(hex: "#fff4e0"), intensity: 5200, from: key),
                Light(color: RGB(hex: "#cfe0ef"), intensity: 2400, from: fill),
                Light(color: RGB(hex: "#9aa4ae"), intensity: 900, from: bounce),
            ]
        case .goldenHour:
            background = RGB(hex: "#3a2d1e")
            ground = RGB(hex: "#4d3d2b")
            lights = [
                Light(color: RGB(hex: "#ff9a3c"), intensity: 4600, from: SIMD3(6, 3, 4)),
                Light(color: RGB(hex: "#f5c396"), intensity: 1800, from: fill),
                Light(color: RGB(hex: "#8a6f55"), intensity: 800, from: bounce),
            ]
        case .night:
            background = RGB(hex: "#11151c")
            ground = RGB(hex: "#1c222c")
            lights = [
                Light(color: RGB(hex: "#7a9cc6"), intensity: 2400, from: key),
                Light(color: RGB(hex: "#2c3e5a"), intensity: 1200, from: fill),
                Light(color: RGB(hex: "#3a4658"), intensity: 600, from: bounce),
            ]
        case .interiorWarm:
            background = RGB(hex: "#27231d")
            ground = RGB(hex: "#3a332a")
            lights = [
                Light(color: RGB(hex: "#ffd9a0"), intensity: 4000, from: key),
                Light(color: RGB(hex: "#ffe0b3"), intensity: 2200, from: fill),
                Light(color: RGB(hex: "#8c7a63"), intensity: 900, from: bounce),
            ]
        case .interiorCool:
            background = RGB(hex: "#212528")
            ground = RGB(hex: "#30363b")
            lights = [
                Light(color: RGB(hex: "#e8f2ff"), intensity: 4200, from: key),
                Light(color: RGB(hex: "#d0e4f5"), intensity: 2300, from: fill),
                Light(color: RGB(hex: "#7d8994"), intensity: 900, from: bounce),
            ]
        }
    }
}

extension RGB {
    var cgColor: CGColor {
        CGColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }
}
