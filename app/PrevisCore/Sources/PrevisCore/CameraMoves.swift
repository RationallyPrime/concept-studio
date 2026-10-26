import Foundation

public enum CameraMoves { // several subjects act as one virtual subject at their midpoint
    /// Marks for a starter camera move around `subjects`, over the whole shot, starting from the shot's first camera
    /// mark. With several subjects the move follows a virtual subject at their midpoint, as tall as the tallest, and
    /// facing the average of their headings. `trackIDs` is the subjects when the move aim-locks, else empty.
    public static func marks(
        _ moveID: String,
        scene: PrevisScene,
        shotID: ShotID,
        subjects: [EntityID],
        catalog: ContentCatalog
    ) throws -> (marks: [CameraMark], trackIDs: [EntityID]) {
        guard let item = catalog.cameraMoves.first(where: { $0.id == moveID }) else {
            throw ShotsError
                .unknownContent("The camera move \"\(moveID)\" is not in the catalog; pick one from the list.")
        }
        let evaluator = try ShotEvaluator(scene: scene, shotID: shotID, catalog: catalog)
        let shot = try scene.shot(shotID)
        let people = try subjects.map { try scene.subject($0, shotID: shotID, catalog: catalog) }
        guard !people.isEmpty else {
            throw ShotsError.invalid([
                ShotsProblem(
                    severity: .error,
                    message: "A camera move needs at least one subject; select someone to frame.",
                    sceneID: scene.id,
                    shotID: shotID
                ),
            ])
        }
        let first = shot.camera.marks.enumerated()
            .min { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }?.element
        let context = CameraMoveContext(
            subjectAt: { t in
                let frame = evaluator.frame(at: t)
                return Self.virtualSubject(people.compactMap { id in frame.entities.first { $0.id == id.entity } })
            },
            subjectHeight: people.map(\.height).max() ?? 1.75,
            camera: CameraStart(
                position: first?.position ?? Vec3(0, 1.6, 6),
                pan: first?.pan ?? 0,
                tilt: first?.tilt ?? 0,
                focalLength: first?.focalLength ?? 35
            ),
            duration: shot.duration
        )
        guard let specs = CameraMovePresets.generate(moveID, context) else {
            throw ShotsError.notImplemented("The camera move \"\(moveID)\" is in the catalog but has no generator yet.")
        }
        let marks = specs.map { spec in
            CameraMark(
                id: PrevisIDs.make("mark"),
                time: spec.time,
                hold: spec.hold,
                easeIn: spec.easeIn,
                easeOut: spec.easeOut,
                position: spec.position,
                pan: spec.pan,
                tilt: spec.tilt,
                roll: spec.roll,
                focalLength: spec.focalLength
            )
        }
        return (marks, item.track == true ? subjects : [])
    }

    /// The midpoint of the subjects, facing the average of their directions.
    private static func virtualSubject(_ frames: [EntityFrame]) -> SubjectSample {
        guard let only = frames.first else { return SubjectSample(x: 0, y: 0, z: 0, heading: 0) }
        if frames.count == 1 { return SubjectSample(
            x: only.position.x,
            y: only.position.y,
            z: only.position.z,
            heading: only.heading
        ) }
        let n = Double(frames.count)
        let sum = frames.reduce(Vec3.zero) { $0 + $1.position }
        let sin = frames.reduce(0) { $0 + Foundation.sin($1.heading) }
        let cos = frames.reduce(0) { $0 + Foundation.cos($1.heading) }
        let heading = abs(sin) < 1e-9 && abs(cos) < 1e-9 ? only.heading : atan2(sin, cos)
        return SubjectSample(x: sum.x / n, y: sum.y / n, z: sum.z / n, heading: heading)
    }
}

struct MoveSubject {
    var entity: EntityID
    var height: Double
}

extension PrevisScene {
    func shot(_ id: ShotID) throws -> Shot {
        guard let shot = shots.first(where: { $0.id == id }) else {
            throw ShotsError.invalid([
                ShotsProblem(
                    severity: .error,
                    message: "Scene \"\(name)\" has no shot with id \(id); pick one of its shots.",
                    sceneID: self.id,
                    shotID: id
                ),
            ])
        }
        return shot
    }

    /// An entity of this scene with its standing height at its scale.
    func subject(_ id: EntityID, shotID: ShotID, catalog: ContentCatalog) throws -> MoveSubject {
        guard let entity = entities.first(where: { $0.id == id }), let asset = catalog.asset(entity.assetID) else {
            throw ShotsError.invalid([
                ShotsProblem(
                    severity: .error,
                    message: "The subject \(id) is not in scene \"\(name)\"; pick one of its entities.",
                    sceneID: self.id,
                    shotID: shotID,
                    entityID: id
                ),
            ])
        }
        return MoveSubject(entity: id, height: asset.height * entity.placement.scale)
    }
}
