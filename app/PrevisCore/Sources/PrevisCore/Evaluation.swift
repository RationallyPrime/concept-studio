import Foundation

// Evaluation values, CONTRACTS section 5.4. The evaluator itself is in ShotEvaluator.swift; bodies are in Bodies.swift.

public struct SceneFrame: Sendable, Equatable {
    public var index: Int? // set when evaluated on the grid
    public var time: Double
    public var canvas: ShotCanvas
    public var camera: CameraFrame // field of view for the canvas aspect
    public var entities: [EntityFrame] // document order

    public init(
        index: Int? = nil,
        time: Double,
        canvas: ShotCanvas,
        camera: CameraFrame,
        entities: [EntityFrame] = []
    ) {
        self.index = index
        self.time = time
        self.canvas = canvas
        self.camera = camera
        self.entities = entities
    }
}

public struct CameraFrame: Sendable, Equatable {
    public var position: Vec3
    public var pan: Double, tilt: Double, roll: Double
    public var focalLength: Double
    public var focusDistance: Double?
    public var verticalFOV: Double // radians

    static let near = 0.05
    static let far = 500.0

    public init(
        position: Vec3,
        pan: Double,
        tilt: Double,
        roll: Double,
        focalLength: Double,
        focusDistance: Double? = nil,
        verticalFOV: Double
    ) {
        self.position = position
        self.pan = pan
        self.tilt = tilt
        self.roll = roll
        self.focalLength = focalLength
        self.focusDistance = focusDistance
        self.verticalFOV = verticalFOV
    }

    /// R = Ry(pan) · Rx(tilt) · Rz(roll); the camera looks down its local −Z and positive tilt looks up.
    public var orientation: Quat {
        .yaw(pan) * .pitch(tilt) * .roll(roll)
    }

    /// World → camera.
    public func viewMatrix() -> Mat4 {
        (Mat4.translation(position) * Mat4.rotation(orientation)).inverse
    }

    /// A pinhole with the vertical field of view; near 0.05, far 500.
    public func projection(aspect: Double) -> Mat4 {
        let f = 1 / tan(verticalFOV / 2)
        let (n, fa) = (Self.near, Self.far)
        return Mat4([
            f / aspect, 0, 0, 0,
            0, f, 0, 0,
            0, 0, (fa + n) / (n - fa), -1,
            0, 0, 2 * fa * n / (n - fa), 0,
        ])
    }

    /// Pixels with the origin at the top left and y down; nil when the point is not in front of the camera.
    public func project(_ point: Vec3, size: PixelSize) -> Point2? {
        let c = viewMatrix().transform(point)
        guard -c.z > 0 else { return nil }
        let f = 1 / tan(verticalFOV / 2)
        let x = (f / size.aspect) * c.x / -c.z
        let y = f * c.y / -c.z
        return Point2(x: (x + 1) / 2 * Double(size.width), y: (1 - y) / 2 * Double(size.height))
    }

    /// The world-space ray from the camera through a pixel; `direction` has unit length.
    public func ray(through pixel: Point2, size: PixelSize) -> (origin: Vec3, direction: Vec3) {
        let f = 1 / tan(verticalFOV / 2)
        let x = pixel.x / Double(size.width) * 2 - 1
        let y = 1 - pixel.y / Double(size.height) * 2
        let local = Vec3(x * size.aspect / f, y / f, -1)
        return (position, orientation.rotate(local).normalized)
    }

    /// `vfov = 2·atan(min(sensorH, sensorW/aspect) / (2·f))`.
    public static func make(
        position: Vec3,
        pan: Double,
        tilt: Double,
        roll: Double,
        focalLength: Double,
        sensor: Sensor,
        aspect: Double
    ) -> CameraFrame {
        let gate = sensor.gate
        let vfov = 2 * atan(min(gate.height, gate.width / aspect) / (2 * focalLength))
        return CameraFrame(
            position: position,
            pan: pan,
            tilt: tilt,
            roll: roll,
            focalLength: focalLength,
            verticalFOV: vfov
        )
    }

    func focused(at distance: Double?) -> CameraFrame {
        var copy = self
        copy.focusDistance = distance
        return copy
    }
}

public struct EntityFrame: Sendable, Equatable {
    public var id: EntityID
    public var assetID: String
    public var name: String
    public var label: EntityLabel?
    public var isActor: Bool // rigged asset or labelled: gets a matte and a layout box
    public var position: Vec3
    public var heading: Double
    public var gait: Gait
    public var speed: Double
    public var distanceTravelled: Double
    public var joints: [Joint: Double] // evaluated pose overrides, before the gait pose
    public var parts: [PosedPart]
    public var keypoints: [Keypoint] // COCO-18 world positions; empty unless rig == .person
    public var bounds: Box3

    public init(
        id: EntityID,
        assetID: String,
        name: String,
        label: EntityLabel? = nil,
        isActor: Bool,
        position: Vec3,
        heading: Double,
        gait: Gait,
        speed: Double,
        distanceTravelled: Double,
        joints: [Joint: Double] = [:],
        parts: [PosedPart] = [],
        keypoints: [Keypoint] = [],
        bounds: Box3
    ) {
        self.id = id
        self.assetID = assetID
        self.name = name
        self.label = label
        self.isActor = isActor
        self.position = position
        self.heading = heading
        self.gait = gait
        self.speed = speed
        self.distanceTravelled = distanceTravelled
        self.joints = joints
        self.parts = parts
        self.keypoints = keypoints
        self.bounds = bounds
    }

    /// The entity's body at the evaluated pose: a rig, static parts or a grey box (see Bodies.swift).
    static func posed(_ entity: PrevisEntity, asset: AssetSpec, state: EntityPose) -> EntityFrame {
        let body = Bodies.build(entity, asset: asset, state: state)
        return EntityFrame(
            id: entity.id,
            assetID: entity.assetID,
            name: entity.name,
            label: entity.label,
            isActor: asset.rig != .none || entity.label != nil,
            position: state.position,
            heading: state.heading,
            gait: state.gait,
            speed: state.speed,
            distanceTravelled: state.distanceTravelled,
            joints: state.joints,
            parts: body.parts,
            keypoints: body.keypoints,
            bounds: body.bounds
        )
    }
}

/// An entity's evaluated pose before its body is built.
struct EntityPose {
    var position: Vec3
    var heading: Double
    var gait: Gait = .stand
    var speed = 0.0
    var distanceTravelled = 0.0
    var joints: [Joint: Double] = [:]
    var time = 0.0
}

public struct PosedPart: Sendable, Equatable {
    public var id: String // stable within the entity across frames
    public var shape: PartShape
    public var transform: Mat4 // part → world, including the entity scale
    public var color: RGB

    public init(id: String, shape: PartShape, transform: Mat4, color: RGB) {
        self.id = id
        self.shape = shape
        self.transform = transform
        self.color = color
    }
}

public struct Keypoint: Sendable, Equatable {
    public var name: KeypointName
    public var position: Vec3

    public init(name: KeypointName, position: Vec3) {
        self.name = name
        self.position = position
    }
}

public enum KeypointName: Int, Sendable, CaseIterable { // OpenPose COCO-18 order
    case nose = 0, neck, rightShoulder, rightElbow, rightWrist, leftShoulder, leftElbow, leftWrist
    case rightHip, rightKnee, rightAnkle, leftHip, leftKnee, leftAnkle, rightEye, leftEye, rightEar, leftEar
}

public struct MotionPath: Sendable, Equatable {
    public enum Subject: Sendable, Equatable { case entity(EntityID), camera }
    public var subject: Subject
    public var points: [Vec3]
    public var marks: [PathMark]

    public init(subject: Subject, points: [Vec3] = [], marks: [PathMark] = []) {
        self.subject = subject
        self.points = points
        self.marks = marks
    }
}

public struct PathMark: Sendable, Equatable {
    public var id: MarkID
    public var time: Double
    public var position: Vec3

    public init(id: MarkID, time: Double, position: Vec3) {
        self.id = id
        self.time = time
        self.position = position
    }
}
