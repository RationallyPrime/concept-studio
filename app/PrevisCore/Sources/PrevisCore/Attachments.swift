// Translated from Blockout (https://github.com/wassermanproductions/blockout) src/renderer/store.ts (marry offset
// capture) and src/engine/evaluate.ts (resolveMarriages) at 3f2d0564, Apache-2.0, by Sam Wasserman
// (wassermanproductions.com). Changes: pure functions over an evaluated frame; the rotation is a quaternion. See
// Resources/NOTICE.

import Foundation

public enum Attachments {
    /// The attachment that keeps `child` exactly where it stands at frame `atFrame`, riding `parent` from then on: the
    /// child's offset in the parent's frame and its rotation relative to the parent's.
    public static func attachment(
        child: EntityID,
        parent: EntityID,
        scene: PrevisScene,
        shotID: ShotID,
        atFrame: Int,
        catalog: ContentCatalog
    ) throws -> EntityAttachment {
        guard child != parent else {
            throw problem(scene, shotID, child, "An entity cannot be attached to itself; pick a different parent.")
        }
        try requireEntity(child, in: scene, shotID)
        try requireEntity(parent, in: scene, shotID)
        if riders(of: child, in: scene).contains(parent) {
            let names = [child, parent].map { id in scene.entities.first { $0.id == id }?.name ?? id }
            throw problem(
                scene,
                shotID,
                child,
                "Attaching \"\(names[0])\" to \"\(names[1])\" would make a cycle, because "
                    + "\"\(names[1])\" already rides "
                    + "\"\(names[0])\"; detach one of them first."
            )
        }
        let frame = try ShotEvaluator(scene: scene, shotID: shotID, catalog: catalog).frame(atFrame)
        guard let childFrame = frame.entities.first(where: { $0.id == child }),
              let parentFrame = frame.entities.first(where: { $0.id == parent })
        else {
            throw problem(scene, shotID, child, "The entity is not in the scene at that frame.")
        }
        // The inverse of how a rider is placed: rotate the world offset into the parent's frame.
        let dx = childFrame.position.x - parentFrame.position.x, dz = childFrame.position.z - parentFrame.position.z
        let c = cos(parentFrame.heading), s = sin(parentFrame.heading)
        return EntityAttachment(
            parentID: parent,
            offset: Vec3(dx * c - dz * s, childFrame.position.y - parentFrame.position.y, dx * s + dz * c),
            rotation: .yaw(childFrame.heading - parentFrame.heading)
        )
    }

    /// The placement `child` should take if it is detached at frame `atFrame`: where it stands and faces then, with its
    /// own scale, so detaching does not move it.
    public static func placementWhenDetached(
        child: EntityID,
        scene: PrevisScene,
        shotID: ShotID,
        atFrame: Int,
        catalog: ContentCatalog
    ) throws -> Placement {
        try requireEntity(child, in: scene, shotID)
        let frame = try ShotEvaluator(scene: scene, shotID: shotID, catalog: catalog).frame(atFrame)
        guard let entity = scene.entities.first(where: { $0.id == child }),
              let childFrame = frame.entities.first(where: { $0.id == child })
        else {
            throw problem(scene, shotID, child, "The entity is not in the scene at that frame.")
        }
        return Placement(position: childFrame.position, heading: childFrame.heading, scale: entity.placement.scale)
    }

    private static func requireEntity(_ id: EntityID, in scene: PrevisScene, _ shotID: ShotID) throws {
        guard scene.entities.contains(where: { $0.id == id }) else {
            throw problem(
                scene,
                shotID,
                id,
                "The entity \(id) is not in scene \"\(scene.name)\"; pick one of its entities."
            )
        }
    }

    /// Everything attached to `id`, directly or through other entities.
    private static func riders(of id: EntityID, in scene: PrevisScene) -> Set<EntityID> {
        var found: Set<EntityID> = []
        var frontier = [id]
        while let next = frontier.popLast() {
            for entity in scene.entities where entity.attachment?.parentID == next && !found.contains(entity.id) {
                found.insert(entity.id)
                frontier.append(entity.id)
            }
        }
        return found
    }

    private static func problem(
        _ scene: PrevisScene,
        _ shotID: ShotID,
        _ entity: EntityID,
        _ message: String
    ) -> ShotsError {
        ShotsError.invalid([
            ShotsProblem(severity: .error, message: message, sceneID: scene.id, shotID: shotID, entityID: entity),
        ])
    }
}
