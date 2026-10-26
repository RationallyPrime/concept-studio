import AppKit
import PrevisCore
import RealityKit

/// Builds the editor-only overlay hierarchy (`overlayRoot`), kept strictly separate from `PrevisSceneMapper.root`
/// so editor chrome never appears in exported passes.
@MainActor enum ViewportGrid {
    static let gridExtent = 10
    static let lineThickness: Float = 0.014
    static let lineHeight: Float = 0.002
    static let elevation: Float = 0.002

    static func makeOverlayRoot() -> Entity {
        let root = Entity()
        root.name = "viewport.overlayRoot"
        root.addChild(makeGridEntity())
        disableOcclusionCulling(on: root)
        return root
    }

    static func makeGridEntity() -> Entity {
        let grid = Entity()
        grid.name = "viewport.groundGrid"
        let length = Float(gridExtent * 2)
        let xLineMesh = MeshResource.generateBox(width: length, height: lineHeight, depth: lineThickness)
        let zLineMesh = MeshResource.generateBox(width: lineThickness, height: lineHeight, depth: length)

        let minorColor = NSColor(srgbRed: 0.22, green: 0.26, blue: 0.30, alpha: 1)
        let majorColor = NSColor(srgbRed: 0.16, green: 0.20, blue: 0.24, alpha: 1)
        let minorMaterial = UnlitMaterial(color: minorColor)
        let majorMaterial = UnlitMaterial(color: majorColor)

        for index in -gridExtent ... gridExtent {
            let coord = Float(index)
            let isAxis = index == 0
            let material = isAxis ? majorMaterial : minorMaterial

            let xLine = ModelEntity(mesh: xLineMesh, materials: [material])
            xLine.position = SIMD3<Float>(0, elevation, coord)
            grid.addChild(xLine)

            let zLine = ModelEntity(mesh: zLineMesh, materials: [material])
            zLine.position = SIMD3<Float>(coord, elevation, 0)
            grid.addChild(zLine)
        }
        return grid
    }

    static func disableOcclusionCulling(on entity: Entity) {
        #if compiler(>=6.4)
            if #available(macOS 27.0, *) {
                entity.components.set(OcclusionCullingComponent(isEnabled: false))
            }
        #endif
    }
}
