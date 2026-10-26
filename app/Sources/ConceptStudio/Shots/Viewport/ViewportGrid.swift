import AppKit
import PrevisCore
import RealityKit
import SwiftUI

/// Builds the editor-only overlay hierarchy (`overlayRoot`), kept strictly separate from `PrevisSceneMapper.root`
/// so editor chrome never appears in exported passes, and provides the canonical scene background and sky box
/// for the live viewport.
///
/// Reference: Blockout `src/renderer/viewport/SceneManager.ts:187, 200-205, 239-243, 764-796`
/// (`new THREE.GridHelper(60, 60, 0x33343a, 0x27282d)` with opacity `0.6` under `this.overlay`, and per-preset
/// `this.scene.background = new THREE.Color(p.bg)`).
/// Intentional RealityKit deviation: RealityKit `MeshResource` uses triangle primitives rather than `GL_LINES`,
/// so the 60 m × 60 m 1 m grid is batched into two horizontal quad-strip `MeshResource` models (centre axes
/// `0x33343a` and 1 m divisions `0x27282d`) lifted `0.002` m above `y = 0` to prevent z-fighting with the ground plane.
@MainActor enum ViewportGrid {
    static let gridExtent = 30 // 60 m × 60 m (-30...30 m) at 1 m spacing, matching THREE.GridHelper(60, 60, ...)
    static let lineThickness: Float = 0.016
    static let elevation: Float = 0.002
    static let skyDomeHalfExtent: Float = 300.0

    static let centerAxisColor = NSColor(
        srgbRed: CGFloat(0x33) / 255.0,
        green: CGFloat(0x34) / 255.0,
        blue: CGFloat(0x3A) / 255.0,
        alpha: 1.0
    )

    static let divisionLineColor = NSColor(
        srgbRed: CGFloat(0x27) / 255.0,
        green: CGFloat(0x28) / 255.0,
        blue: CGFloat(0x2D) / 255.0,
        alpha: 1.0
    )

    /// Canonical background RGB for a `LightingPreset`, matching Blockout `SceneManager.ts:770-776`
    /// and `ShotsMedia.PrevisLook`.
    static func backgroundRGB(for lighting: LightingPreset) -> RGB {
        switch lighting {
        case .day:
            RGB(hex: "#394048")
        case .goldenHour:
            RGB(hex: "#3a2d1e")
        case .night:
            RGB(hex: "#11151c")
        case .interiorWarm:
            RGB(hex: "#27231d")
        case .interiorCool:
            RGB(hex: "#212528")
        }
    }

    static func nsBackgroundColor(for lighting: LightingPreset) -> NSColor {
        let rgb = backgroundRGB(for: lighting)
        return NSColor(srgbRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1.0)
    }

    static func backgroundColor(for lighting: LightingPreset) -> Color {
        let rgb = backgroundRGB(for: lighting)
        return Color(.sRGB, red: rgb.r, green: rgb.g, blue: rgb.b, opacity: 1.0)
    }

    /// Creates an inward-facing unlit sky enclosure for the live `RealityView` so rays above the horizon or
    /// beyond the ground plane display the selected look's canonical background colour.
    static func makeSkyDomeEntity(for lighting: LightingPreset = .day) -> ModelEntity {
        let mesh = (try? makeInwardBoxMesh(halfExtent: skyDomeHalfExtent))
            ?? .generateBox(size: skyDomeHalfExtent * 2)
        let material = UnlitMaterial(color: nsBackgroundColor(for: lighting))
        let entity = ModelEntity(mesh: mesh, materials: [material])
        entity.name = "viewport.skyDome"
        disableOcclusionCulling(on: entity)
        return entity
    }

    static func updateSkyDome(_ skyDome: ModelEntity, for lighting: LightingPreset) {
        let material = UnlitMaterial(color: nsBackgroundColor(for: lighting))
        skyDome.model?.materials = [material]
    }

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

        let halfSpan = Float(gridExtent)
        let halfWidth = lineThickness * 0.5
        let axisCoords: [Float] = [0]
        let divisionCoords: [Float] = (-gridExtent ... gridExtent)
            .filter { $0 != 0 }
            .map { Float($0) }

        var axisMaterial = UnlitMaterial(color: centerAxisColor)
        axisMaterial.blending = .transparent(opacity: .init(floatLiteral: 0.6))
        var divisionMaterial = UnlitMaterial(color: divisionLineColor)
        divisionMaterial.blending = .transparent(opacity: .init(floatLiteral: 0.6))

        if let axisMesh = try? makeGridLinesMesh(
            name: "viewport.groundGrid.axes",
            coordinates: axisCoords,
            halfSpan: halfSpan,
            halfWidth: halfWidth,
            y: elevation
        ) {
            let axesEntity = ModelEntity(mesh: axisMesh, materials: [axisMaterial])
            axesEntity.name = "viewport.groundGrid.axes"
            grid.addChild(axesEntity)
        }

        if let divisionMesh = try? makeGridLinesMesh(
            name: "viewport.groundGrid.divisions",
            coordinates: divisionCoords,
            halfSpan: halfSpan,
            halfWidth: halfWidth,
            y: elevation
        ) {
            let divisionsEntity = ModelEntity(mesh: divisionMesh, materials: [divisionMaterial])
            divisionsEntity.name = "viewport.groundGrid.divisions"
            grid.addChild(divisionsEntity)
        }

        return grid
    }

    private static func makeGridLinesMesh(
        name: String,
        coordinates: [Float],
        halfSpan: Float,
        halfWidth: Float,
        y: Float
    ) throws -> MeshResource {
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        let up = SIMD3<Float>(0, 1, 0)

        func appendQuad(x0: Float, z0: Float, x1: Float, z1: Float) {
            let base = UInt32(positions.count)
            positions.append(SIMD3<Float>(x0, y, z1))
            positions.append(SIMD3<Float>(x1, y, z1))
            positions.append(SIMD3<Float>(x1, y, z0))
            positions.append(SIMD3<Float>(x0, y, z0))
            normals.append(contentsOf: [up, up, up, up])
            indices.append(contentsOf: [base, base + 1, base + 2, base, base + 2, base + 3])
        }

        for coord in coordinates {
            appendQuad(x0: -halfSpan, z0: coord - halfWidth, x1: halfSpan, z1: coord + halfWidth)
            appendQuad(x0: coord - halfWidth, z0: -halfSpan, x1: coord + halfWidth, z1: halfSpan)
        }

        var descriptor = MeshDescriptor(name: name)
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals(normals)
        descriptor.primitives = .triangles(indices)
        return try MeshResource.generate(from: [descriptor])
    }

    private static func makeInwardBoxMesh(halfExtent h: Float) throws -> MeshResource {
        let faces: [([SIMD3<Float>], SIMD3<Float>)] = [
            // Front (z = -h, normal +Z)
            ([SIMD3(-h, -h, -h), SIMD3(h, -h, -h), SIMD3(h, h, -h), SIMD3(-h, h, -h)], SIMD3(0, 0, 1)),
            // Back (z = +h, normal -Z)
            ([SIMD3(h, -h, h), SIMD3(-h, -h, h), SIMD3(-h, h, h), SIMD3(h, h, h)], SIMD3(0, 0, -1)),
            // Left (x = -h, normal +X)
            ([SIMD3(-h, -h, h), SIMD3(-h, -h, -h), SIMD3(-h, h, -h), SIMD3(-h, h, h)], SIMD3(1, 0, 0)),
            // Right (x = +h, normal -X)
            ([SIMD3(h, -h, -h), SIMD3(h, -h, h), SIMD3(h, h, h), SIMD3(h, h, -h)], SIMD3(-1, 0, 0)),
            // Top (y = +h, normal -Y)
            ([SIMD3(-h, h, -h), SIMD3(h, h, -h), SIMD3(h, h, h), SIMD3(-h, h, h)], SIMD3(0, -1, 0)),
            // Bottom (y = -h, normal +Y)
            ([SIMD3(-h, -h, h), SIMD3(h, -h, h), SIMD3(h, -h, -h), SIMD3(-h, -h, -h)], SIMD3(0, 1, 0)),
        ]
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        for (corners, normal) in faces {
            let base = UInt32(positions.count)
            positions.append(contentsOf: corners)
            normals.append(contentsOf: [normal, normal, normal, normal])
            indices.append(contentsOf: [base, base + 1, base + 2, base, base + 2, base + 3])
        }
        var descriptor = MeshDescriptor(name: "viewport.skyDome")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals(normals)
        descriptor.primitives = .triangles(indices)
        return try MeshResource.generate(from: [descriptor])
    }

    static func disableOcclusionCulling(on entity: Entity) {
        #if compiler(>=6.4)
            if #available(macOS 27.0, *) {
                entity.components.set(OcclusionCullingComponent(isEnabled: false))
            }
        #endif
    }
}
