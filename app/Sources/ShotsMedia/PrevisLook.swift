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
}
