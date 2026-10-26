import PrevisCore
import RealityKit

/// Keeps a RealityKit entity tree in step with evaluated frames: one child per PrevisEntity, one model per part.
/// The viewport and the offscreen renderer both draw through it. Mapping lands in B1.
@MainActor public final class PrevisSceneMapper {
    public let root = Entity()
    public private(set) var look: PrevisLook

    public init(look: PrevisLook) {
        self.look = look
    }

    public func setLook(_ look: PrevisLook) {
        self.look = look
    }

    /// Adds, updates and removes children by (entity id, part id). Idempotent.
    public func apply(_ frame: SceneFrame) {}

    /// The PrevisEntity a RealityKit entity belongs to, if it is part of this tree.
    public func entityID(of entity: Entity) -> EntityID? {
        nil
    }

    public func cameraEntity(for camera: CameraFrame) -> Entity {
        Entity()
    }
}
