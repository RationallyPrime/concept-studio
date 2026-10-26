import PrevisCore
import RealityKit

/// Keeps a RealityKit entity tree in step with evaluated frames: one child per PrevisEntity, one model per
/// part. The viewport and the offscreen renderer both draw through it, so they share meshes, materials and the
/// look. Everything is set from the frame; nothing animates on its own.
@MainActor public final class PrevisSceneMapper {
    public let root = Entity()
    public private(set) var look: PrevisLook

    private let environment = Entity()
    private let stage = Entity()
    private let camera = Entity()
    private var containers: [EntityID: Entity] = [:]
    private var owners: [ObjectIdentifier: EntityID] = [:]
    private var parts: [EntityID: [String: MappedPart]] = [:]
    private var meshes: [PartShape: MeshResource] = [:]
    private var materials: [RGB: SimpleMaterial] = [:]
    private var matteActor: EntityID?
    private let matteWhite = UnlitMaterial(color: .white)
    private let matteBlack = UnlitMaterial(color: .black)

    private struct MappedPart {
        let entity: Entity
        let shape: PartShape
        var color: RGB
    }

    public init(look: PrevisLook) {
        self.look = look
        root.addChild(environment)
        root.addChild(stage)
        buildEnvironment()
    }

    public func setLook(_ look: PrevisLook) {
        guard look != self.look else { return }
        self.look = look
        buildEnvironment()
    }

    /// Draws `actor` white and everything else black, unlit, for its matte; nil draws the look again.
    func setMatte(_ actor: EntityID?) {
        guard actor != matteActor else { return }
        matteActor = actor
        for (id, mapped) in parts {
            for part in mapped.values {
                setMaterial(surface(part.color, of: id), on: part.entity)
            }
        }
        buildEnvironment()
    }

    /// Adds, updates and removes children by (entity id, part id). Idempotent.
    public func apply(_ frame: SceneFrame) {
        let present = Set(frame.entities.map(\.id))
        for (id, container) in containers where !present.contains(id) {
            container.removeFromParent()
            owners[ObjectIdentifier(container)] = nil
            containers[id] = nil
            parts[id] = nil
        }
        for entity in frame.entities {
            apply(entity)
        }
    }

    /// The PrevisEntity a RealityKit entity belongs to, if it is part of this tree.
    public func entityID(of entity: Entity) -> EntityID? {
        var node: Entity? = entity
        while let current = node {
            if let id = owners[ObjectIdentifier(current)] { return id }
            node = current.parent
        }
        return nil
    }

    /// The mapper's one camera entity, placed and lensed for `frame`.
    public func cameraEntity(for frame: CameraFrame) -> Entity {
        camera.transform = Transform(
            scale: .one,
            rotation: frame.orientation.simd,
            translation: frame.position.simd
        )
        camera.components.set(
            PerspectiveCameraComponent(
                near: 0.05,
                far: 500,
                fieldOfViewInDegrees: Float(frame.verticalFOV * 180 / .pi),
                fieldOfViewOrientation: .vertical
            )
        )
        return camera
    }

    private func apply(_ frame: EntityFrame) {
        let container: Entity
        if let existing = containers[frame.id] {
            container = existing
        } else {
            container = Entity()
            container.name = "previs:\(frame.id)"
            stage.addChild(container)
            containers[frame.id] = container
            owners[ObjectIdentifier(container)] = frame.id
        }
        var mapped = parts[frame.id] ?? [:]
        let present = Set(frame.parts.map(\.id))
        for (id, part) in mapped where !present.contains(id) {
            part.entity.removeFromParent()
            mapped[id] = nil
        }
        for part in frame.parts {
            if let existing = mapped[part.id], existing.shape == part.shape {
                if existing.color != part.color {
                    setMaterial(surface(part.color, of: frame.id), on: existing.entity)
                    mapped[part.id]?.color = part.color
                }
                existing.entity.transform = Transform(matrix: part.transform.simd)
            } else {
                mapped[part.id]?.entity.removeFromParent()
                let entity = makeModel(part.shape, material: surface(part.color, of: frame.id))
                entity.transform = Transform(matrix: part.transform.simd)
                container.addChild(entity)
                mapped[part.id] = MappedPart(entity: entity, shape: part.shape, color: part.color)
            }
        }
        parts[frame.id] = mapped
    }

    /// A capsule has no RealityKit mesh generator, so it is a cylinder with two spheres under one entity.
    private func makeModel(_ shape: PartShape, material: any RealityKit.Material) -> Entity {
        if case let .capsule(radius, length) = shape {
            let group = Entity()
            let body = ModelEntity(mesh: mesh(.cylinder(radius: radius, height: length)), materials: [material])
            group.addChild(body)
            for end in [-1.0, 1.0] {
                let cap = ModelEntity(mesh: mesh(.sphere(radius: radius)), materials: [material])
                cap.position = SIMD3<Float>(0, Float(end * length / 2), 0)
                group.addChild(cap)
            }
            return group
        }
        return ModelEntity(mesh: mesh(shape), materials: [material])
    }

    private func setMaterial(_ material: any RealityKit.Material, on entity: Entity) {
        if let model = entity as? ModelEntity { model.model?.materials = [material] }
        for child in entity.children {
            setMaterial(material, on: child)
        }
    }

    private func mesh(_ shape: PartShape) -> MeshResource {
        if let cached = meshes[shape] { return cached }
        let mesh: MeshResource = switch shape {
        case let .box(size):
            .generateBox(width: Float(size.x), height: Float(size.y), depth: Float(size.z))
        case let .cylinder(radius, height):
            .generateCylinder(height: Float(height), radius: Float(radius))
        case let .sphere(radius):
            .generateSphere(radius: Float(radius))
        case let .capsule(radius, length):
            .generateCylinder(height: Float(length + 2 * radius), radius: Float(radius))
        case let .cone(radius, height):
            .generateCone(height: Float(height), radius: Float(radius))
        case let .wedge(size):
            (try? WedgeMesh.make(size)) ?? .generateBox(
                width: Float(size.x),
                height: Float(size.y),
                depth: Float(size.z)
            )
        }
        meshes[shape] = mesh
        return mesh
    }

    private func surface(_ color: RGB, of id: EntityID) -> any RealityKit.Material {
        guard let matteActor else { return material(color) }
        return id == matteActor ? matteWhite : matteBlack
    }

    private func material(_ color: RGB) -> SimpleMaterial {
        if let cached = materials[color] { return cached }
        let material = SimpleMaterial(
            color: SimpleMaterial.Color(srgbRed: color.r, green: color.g, blue: color.b, alpha: 1),
            roughness: 1,
            isMetallic: false
        )
        materials[color] = material
        return material
    }

    private func buildEnvironment() {
        for child in Array(environment.children) {
            child.removeFromParent()
        }
        let palette = look.palette
        let groundSurface: any RealityKit.Material = matteActor == nil ? material(palette.ground) : matteBlack
        let ground = ModelEntity(mesh: .generatePlane(width: 200, depth: 200), materials: [groundSurface])
        environment.addChild(ground)
        for light in palette.lights {
            let entity = Entity()
            entity.components.set(
                DirectionalLightComponent(
                    color: DirectionalLightComponent.Color(
                        srgbRed: light.color.r, green: light.color.g, blue: light.color.b, alpha: 1
                    ),
                    intensity: light.intensity
                )
            )
            entity.look(at: .zero, from: light.from, relativeTo: nil)
            environment.addChild(entity)
        }
    }
}

/// A ramp rising toward −Z, centred on the origin, with flat-shaded faces.
enum WedgeMesh {
    static func make(_ size: Vec3) throws -> MeshResource {
        let halfWidth = Float(size.x) / 2, halfDepth = Float(size.z) / 2
        let low = -Float(size.y) / 2, high = Float(size.y) / 2
        let frontLeft = SIMD3<Float>(-halfWidth, low, halfDepth), frontRight = SIMD3<Float>(halfWidth, low, halfDepth)
        let backRight = SIMD3<Float>(halfWidth, low, -halfDepth), backLeft = SIMD3<Float>(-halfWidth, low, -halfDepth)
        let topLeft = SIMD3<Float>(-halfWidth, high, -halfDepth), topRight = SIMD3<Float>(halfWidth, high, -halfDepth)
        // Each triangle winds counter-clockwise seen from outside.
        let triangles: [[SIMD3<Float>]] = [
            [frontLeft, backLeft, backRight], [frontLeft, backRight, frontRight], // bottom
            [backLeft, topLeft, topRight], [backLeft, topRight, backRight], // back
            [frontLeft, frontRight, topRight], [frontLeft, topRight, topLeft], // slope
            [frontLeft, topLeft, backLeft], // left side
            [frontRight, backRight, topRight], // right side
        ]
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        for triangle in triangles {
            let normal = simd_normalize(simd_cross(triangle[1] - triangle[0], triangle[2] - triangle[0]))
            positions += triangle
            normals += [normal, normal, normal]
        }
        var descriptor = MeshDescriptor(name: "wedge")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals(normals)
        descriptor.primitives = .triangles((0 ..< UInt32(positions.count)).map(\.self))
        return try MeshResource.generate(from: [descriptor])
    }
}

extension Vec3 {
    var simd: SIMD3<Float> {
        SIMD3<Float>(Float(x), Float(y), Float(z))
    }
}

extension Quat {
    var simd: simd_quatf {
        simd_quatf(ix: Float(x), iy: Float(y), iz: Float(z), r: Float(w))
    }
}

extension Mat4 {
    /// Column-major, like PrevisCore's storage.
    var simd: simd_float4x4 {
        func column(_ index: Int) -> SIMD4<Float> {
            SIMD4<Float>(Float(m[index * 4]), Float(m[index * 4 + 1]), Float(m[index * 4 + 2]), Float(m[index * 4 + 3]))
        }
        return simd_float4x4(column(0), column(1), column(2), column(3))
    }
}
