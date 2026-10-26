import Foundation

/// The pose of the entity a `carMount` camera rides at one instant. The evaluator reads such a camera's marks relative
/// to it (position rotated by the mount's heading and added to its position; `pan` plus its heading), so generators
/// that
/// work in world space convert their marks with this before returning them.
struct MountFrame {
    var position: Vec3
    var heading: Double

    /// The mount of `shot`'s camera in `frame`, if the shot's camera is mounted on an entity that is in the scene.
    init?(shot: Shot, frame: SceneFrame) {
        guard shot.camera.rig == .carMount,
              let id = shot.camera.mountID,
              let mount = frame.entities.first(where: { $0.id == id })
        else { return nil }
        position = mount.position
        heading = mount.heading
    }

    /// World space → the mount's frame.
    func local(_ world: Vec3) -> Vec3 {
        let dx = world.x - position.x, dz = world.z - position.z
        let c = cos(heading), s = sin(heading)
        return Vec3(dx * c - dz * s, world.y - position.y, dx * s + dz * c)
    }

    /// The mount's frame → world space.
    func world(_ local: Vec3) -> Vec3 {
        Offset(x: local.x, y: local.y, z: local.z, rotY: 0).apply(toParent: position, heading: heading)
    }
}
