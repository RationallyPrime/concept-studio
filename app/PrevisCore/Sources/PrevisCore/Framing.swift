// Translated from Blockout (https://github.com/wassermanproductions/blockout) src/engine/camera.ts (frameSubject,
// SHOT_SIZES) and src/renderer/viewport/SceneManager.ts (autoFrame, applyFraming) at 3f2d0564, Apache-2.0, by Sam
// Wasserman (wassermanproductions.com). Changes: pure functions over an evaluated frame; the camera aims at the framed
// region (Blockout's tilt was always 0); every distance that fits something in the frame uses the canvas aspect, not
// the
// full sensor width. See Resources/NOTICE.

import Foundation

public enum Framing {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case wide, full, medium, closeUp, twoShot, overShoulder, reverse, top, low, dutch
    }

    /// A camera mark that frames `subjects` as `kind` at frame `atFrame`, with the shot's lens, sensor and canvas
    /// aspect.
    ///
    /// The shot sizes (`wide`, `full`, `medium`, `closeUp`) frame the first subject from the side the camera is on, at
    /// the camera's height, aimed at the middle of the visible part. `twoShot` fits every subject across the frame;
    /// `overShoulder` needs two. `reverse` swings the camera to the opposite side of the subjects' midpoint, `top`
    /// looks
    /// straight down, `low` looks up from knee height and `dutch` cycles the horizon between level, right and left.
    public static func cameraMark(
        _ kind: Kind,
        scene: PrevisScene,
        shotID: ShotID,
        subjects: [EntityID],
        atFrame: Int,
        catalog: ContentCatalog
    ) throws -> CameraMark {
        let shot = try scene.shot(shotID)
        let evaluator = try ShotEvaluator(scene: scene, shotID: shotID, catalog: catalog)
        let frame = evaluator.frame(atFrame)
        let people = try subjects.map { id -> Subject in
            let known = try scene.subject(id, shotID: shotID, catalog: catalog)
            guard let entity = frame.entities.first(where: { $0.id == id }) else {
                throw problem(
                    scene,
                    shotID,
                    "The subject \(id) is not in scene \"\(scene.name)\"; pick one of its entities."
                )
            }
            return Subject(position: entity.position, height: known.height)
        }
        guard let primary = people.first else {
            throw problem(scene, shotID, "Framing needs at least one subject; select someone to frame.")
        }
        let lens = frame.camera.focalLength
        let optics = Optics(sensor: shot.camera.sensor, focalLength: lens, aspect: shot.canvas.aspect)
        let camera = frame.camera
        let context = Context(camera: camera.position, optics: optics, people: people, primary: primary)

        let pose: Pose = switch kind {
        case .wide, .full, .medium, .closeUp: context.shotSize(kind, azimuthFrom: camera.position)
        case .twoShot: try context.twoShot(scene, shotID)
        case .overShoulder: try context.overShoulder(scene, shotID)
        case .reverse: context.reverse()
        case .top: context.top(pan: camera.pan)
        case .low: context.low()
        case .dutch: context.dutch(camera)
        }
        return CameraMark(
            id: PrevisIDs.make("mark"),
            time: FrameGrid.time(ofFrame: min(max(atFrame, 0), evaluator.frameCount - 1)),
            hold: 0,
            easeIn: 0,
            easeOut: 0,
            position: pose.position,
            pan: pose.pan,
            tilt: pose.tilt,
            roll: pose.roll,
            focalLength: lens
        )
    }

    private static func problem(_ scene: PrevisScene, _ shotID: ShotID, _ message: String) -> ShotsError {
        ShotsError.invalid([ShotsProblem(severity: .error, message: message, sceneID: scene.id, shotID: shotID)])
    }

    private struct Subject {
        var position: Vec3
        var height: Double
    }

    private struct Pose {
        var position: Vec3
        var pan: Double
        var tilt: Double
        var roll = 0.0
    }

    /// Lens, sensor and canvas aspect: the crop-to-aspect model, so a portrait canvas uses a narrower width of the
    /// gate.
    private struct Optics {
        let sensor: Sensor
        let focalLength: Double
        let aspect: Double

        var verticalFOV: Double {
            let gate = sensor.gate
            return 2 * atan(min(gate.height, gate.width / aspect) / (2 * focalLength))
        }

        /// The horizontal field of view of the canvas, which for a portrait canvas is much narrower than the gate's.
        var horizontalFOV: Double {
            2 * atan(tan(verticalFOV / 2) * aspect)
        }
    }

    /// Visible fraction of a standing subject, and how much of the frame height it should fill.
    private static func size(of kind: Kind) -> (visible: Double, fill: Double) {
        switch kind {
        case .wide: (1, 0.65)
        case .full: (1, 0.92)
        case .medium: (0.45, 0.92)
        default: (0.18, 0.9) // close-up
        }
    }

    private struct Context {
        let camera: Vec3
        let optics: Optics
        let people: [Subject]
        let primary: Subject

        func panTilt(from: Vec3, to: Vec3) -> (pan: Double, tilt: Double) {
            let flat = (pow(to.x - from.x, 2) + pow(to.z - from.z, 2)).squareRoot()
            return (headingOf(dx: to.x - from.x, dz: to.z - from.z), atan2(to.y - from.y, max(flat, 1e-4)))
        }

        func midpoint() -> Vec3 {
            people.reduce(Vec3.zero) { $0 + $1.position } * (1 / Double(people.count))
        }

        // MARK: Shot sizes

        func shotSize(_ kind: Kind, azimuthFrom camera: Vec3) -> Pose {
            let (visibleFraction, fill) = Framing.size(of: kind)
            let visible = primary.height * visibleFraction
            let distance = visible / fill / (2 * tan(optics.verticalFOV / 2))
            let targetHeight = primary.height - visible / 2
            var azimuth = atan2(camera.x - primary.position.x, camera.z - primary.position.z)
            if !azimuth.isFinite { azimuth = 0 }
            let position = Vec3(
                primary.position.x + sin(azimuth) * distance,
                camera.y,
                primary.position.z + cos(azimuth) * distance
            )
            // Blockout set the camera height to the target height, which made the tilt always 0. The camera keeps its
            // own
            // height and tilts to the middle of the visible part.
            let target = Vec3(primary.position.x, primary.position.y + targetHeight, primary.position.z)
            let (pan, tilt) = panTilt(from: position, to: target)
            return Pose(position: position, pan: pan, tilt: tilt)
        }

        // MARK: Two-shot

        func twoShot(_ scene: PrevisScene, _ shotID: ShotID) throws -> Pose {
            guard people.count >= 2, let first = people.first, let last = people.last else {
                throw Framing.problem(scene, shotID, "A two-shot needs two characters; select both.")
            }
            let mid = midpoint()
            var axis = Vec3(last.position.x - first.position.x, 0, last.position.z - first.position.z)
            axis = axis.length * axis.length < 1e-6 ? Vec3(1, 0, 0) : axis.normalized
            var perpendicular = Vec3(axis.z, 0, -axis.x)
            // stay on the camera's current side of the line (the 180° rule)
            if (camera - mid).dot(perpendicular) < 0 { perpendicular *= -1 }
            let span = (people.map { abs(($0.position - mid).dot(axis)) * 2 }.max() ?? 0) + 1.6
            let tallest = people.map(\.height).max() ?? primary.height
            // fit the span across the canvas width and the tallest across its height, whichever needs more room
            let distance = max(
                span / 2 / tan(optics.horizontalFOV / 2),
                (tallest + 0.4) / 2 / tan(optics.verticalFOV / 2),
                1.5
            )
            let position = Vec3(mid.x, mid.y + tallest * 0.62, mid.z) + perpendicular * distance
            let (pan, tilt) = panTilt(from: position, to: Vec3(mid.x, mid.y + tallest * 0.55, mid.z))
            return Pose(position: position, pan: pan, tilt: tilt)
        }

        // MARK: Over the shoulder

        func overShoulder(_ scene: PrevisScene, _ shotID: ShotID) throws -> Pose {
            guard people.count >= 2 else {
                throw Framing.problem(scene, shotID, "An over-the-shoulder shot needs two characters; select both.")
            }
            let (a, b) = (people[0], people[1])
            let aNear = distance(camera, a.position) <= distance(camera, b.position)
            let (near, far) = aNear ? (a, b) : (b, a)
            var back = Vec3(near.position.x - far.position.x, 0, near.position.z - far.position.z)
            back = back.length * back.length < 1e-6 ? Vec3(0, 0, 1) : back.normalized
            var side = Vec3(back.z, 0, -back.x)
            if (camera - near.position).dot(side) < 0 { side *= -1 }
            let ground = near.position + back * 0.75 + side * 0.45
            let position = Vec3(ground.x, near.position.y + near.height * 0.92, ground.z)
            let (pan, tilt) = panTilt(
                from: position,
                to: Vec3(far.position.x, far.position.y + far.height * 0.88, far.position.z)
            )
            return Pose(position: position, pan: pan, tilt: tilt)
        }

        // MARK: Reverse, top, low, dutch

        func reverse() -> Pose {
            let mid = people.count >= 2 ? (people[0].position + people[1].position) * 0.5 : primary.position
            let position = Vec3(2 * mid.x - camera.x, camera.y, 2 * mid.z - camera.z)
            let look = Vec3(mid.x, primary.position.y + primary.height * 0.75, mid.z)
            let (pan, tilt) = panTilt(from: position, to: look)
            return Pose(position: position, pan: pan, tilt: tilt)
        }

        /// Looking straight down, high enough to fit everyone across both the canvas height and its width.
        func top(pan: Double) -> Pose {
            let mid = midpoint()
            let span = people.reduce(3.0) { max($0, distance(mid, $1.position) * 2 + 2) }
            let reach = max(span / 2 / tan(optics.verticalFOV / 2), span / 2 / tan(optics.horizontalFOV / 2))
            let height = max(4, reach + 1)
            return Pose(position: Vec3(mid.x, mid.y + height, mid.z + 0.01), pan: pan, tilt: -.pi / 2 + 0.001)
        }

        func low() -> Pose {
            var toCamera = Vec3(camera.x - primary.position.x, 0, camera.z - primary.position.z)
            toCamera = toCamera.length * toCamera.length < 1e-4 ? Vec3(0, 0, 1) : toCamera
            let away = min(max(toCamera.length, 1.6), 4)
            let ground = primary.position + toCamera.normalized * away
            let position = Vec3(ground.x, primary.position.y + 0.35, ground.z)
            let look = Vec3(primary.position.x, primary.position.y + primary.height * 0.95, primary.position.z)
            let (pan, tilt) = panTilt(from: position, to: look)
            return Pose(position: position, pan: pan, tilt: tilt)
        }

        /// Level, then right (+0.35), then left, then level again, keeping the camera where it is.
        func dutch(_ current: CameraFrame) -> Pose {
            let next = abs(current.roll) < 0.05 ? 0.35 : current.roll > 0 ? -0.35 : 0
            return Pose(position: current.position, pan: current.pan, tilt: current.tilt, roll: next)
        }
    }
}
