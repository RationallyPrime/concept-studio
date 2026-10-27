import Foundation
import PrevisCore

/// Pure value describing the interactive 3D editor camera for orbit, pan and dolly.
/// Produces a `CameraFrame` through `CameraFrame.make` and picking rays through `CameraFrame.ray`.
struct EditorCamera: Sendable, Equatable {
    static let minDistance: Double = 0.5
    static let maxDistance: Double = 200.0
    static let distanceRange: ClosedRange<Double> = minDistance ... maxDistance
    static let maxPitch: Double = (.pi / 2) - 0.01
    static let pitchRange: ClosedRange<Double> = -maxPitch ... maxPitch

    var target: Vec3
    private var clampedDistance: Double
    private var wrappedYaw: Double
    private var clampedPitch: Double
    var focalLength: Double
    var sensor: Sensor

    var distance: Double {
        get { clampedDistance }
        set { clampedDistance = Self.clampDistance(newValue) }
    }

    var yaw: Double {
        get { wrappedYaw }
        set { wrappedYaw = Self.wrapAngle(newValue) }
    }

    var pitch: Double {
        get { clampedPitch }
        set { clampedPitch = Self.clampPitch(newValue) }
    }

    init(
        target: Vec3 = Vec3(0, 1.0, 0),
        distance: Double = 6.5,
        yaw: Double = 0,
        pitch: Double = -0.18,
        focalLength: Double = 35,
        sensor: Sensor = .super35
    ) {
        self.target = target
        clampedDistance = Self.clampDistance(distance)
        wrappedYaw = Self.wrapAngle(yaw)
        clampedPitch = Self.clampPitch(pitch)
        self.focalLength = focalLength > 0 && focalLength.isFinite ? focalLength : 35
        self.sensor = sensor
    }

    static let defaultView = EditorCamera(
        target: Vec3(0, 0.9, -0.5),
        distance: 7.5,
        yaw: 0.18,
        pitch: -0.25,
        focalLength: 24,
        sensor: .super35
    )

    static let topView = EditorCamera(
        target: Vec3(0, 0, -0.8),
        distance: 10.0,
        yaw: 0,
        pitch: -maxPitch,
        focalLength: 24,
        sensor: .super35
    )

    /// Camera orientation in world space (`R = Ry(yaw) * Rx(pitch)`).
    var orientation: Quat {
        originCameraFrame.orientation
    }

    /// Unit vector pointing to the camera's right (+X in camera space).
    var right: Vec3 {
        basisMatrix.transform(Vec3(1, 0, 0))
    }

    /// Unit vector pointing along the camera's local up (+Y in camera space).
    var up: Vec3 {
        basisMatrix.transform(Vec3(0, 1, 0))
    }

    /// Unit vector pointing from the camera toward `target` (−Z in camera space).
    var forward: Vec3 {
        basisMatrix.transform(Vec3(0, 0, -1))
    }

    /// World-space camera position at `distance` behind `target` along `-forward`.
    var position: Vec3 {
        let back = basisMatrix.transform(Vec3(0, 0, 1))
        return Vec3(
            target.x + back.x * clampedDistance,
            target.y + back.y * clampedDistance,
            target.z + back.z * clampedDistance
        )
    }

    /// Orbits around `target` by `deltaYaw` (radians around +Y) and `deltaPitch` (radians around local +X).
    mutating func orbit(deltaYaw: Double, deltaPitch: Double) {
        if deltaYaw.isFinite {
            wrappedYaw = Self.wrapAngle(wrappedYaw + deltaYaw)
        }
        if deltaPitch.isFinite {
            clampedPitch = Self.clampPitch(clampedPitch + deltaPitch)
        }
    }

    func orbiting(deltaYaw: Double, deltaPitch: Double) -> EditorCamera {
        var copy = self
        copy.orbit(deltaYaw: deltaYaw, deltaPitch: deltaPitch)
        return copy
    }

    /// Pans `target` (and therefore `position`) in the camera's image plane.
    mutating func pan(deltaRight: Double, deltaUp: Double) {
        let stepRight = deltaRight.isFinite ? deltaRight : 0
        let stepUp = deltaUp.isFinite ? deltaUp : 0
        let r = right
        let u = up
        target = Vec3(
            target.x + r.x * stepRight + u.x * stepUp,
            target.y + r.y * stepRight + u.y * stepUp,
            target.z + r.z * stepRight + u.z * stepUp
        )
    }

    func panning(deltaRight: Double, deltaUp: Double) -> EditorCamera {
        var copy = self
        copy.pan(deltaRight: deltaRight, deltaUp: deltaUp)
        return copy
    }

    /// Dollies along the view axis by an additive distance delta in metres, clamped to `0.5...200` m.
    mutating func dolly(delta: Double) {
        guard delta.isFinite else { return }
        clampedDistance = Self.clampDistance(clampedDistance + delta)
    }

    func dollying(delta: Double) -> EditorCamera {
        var copy = self
        copy.dolly(delta: delta)
        return copy
    }

    /// Dollies along the view axis by a multiplicative scale factor, clamped to `0.5...200` m.
    mutating func dolly(scale: Double) {
        guard scale.isFinite, scale > 0 else { return }
        clampedDistance = Self.clampDistance(clampedDistance * scale)
    }

    func dollying(scale: Double) -> EditorCamera {
        var copy = self
        copy.dolly(scale: scale)
        return copy
    }

    /// Produces a `CameraFrame` for the viewport's pixel size.
    func cameraFrame(for size: PixelSize) -> CameraFrame {
        let safeSize = Self.resolvedPixelSize(size)
        return cameraFrame(aspect: safeSize.aspect)
    }

    /// Produces a `CameraFrame` for an arbitrary positive aspect ratio.
    func cameraFrame(aspect: Double) -> CameraFrame {
        let resolvedAspect = aspect.isFinite && aspect > 0 ? aspect : 1.0
        return CameraFrame.make(
            position: position,
            pan: wrappedYaw,
            tilt: clampedPitch,
            roll: 0,
            focalLength: focalLength,
            sensor: sensor,
            aspect: resolvedAspect
        ).focused(at: clampedDistance)
    }

    /// Projects a world-space point into viewport pixel coordinates.
    func project(_ point: Vec3, size: PixelSize) -> Point2? {
        let safeSize = Self.resolvedPixelSize(size)
        return cameraFrame(for: safeSize).project(point, size: safeSize)
    }

    /// Builds a world-space picking ray through a viewport pixel.
    func ray(through pixel: Point2, size: PixelSize) -> (origin: Vec3, direction: Vec3) {
        let safeSize = Self.resolvedPixelSize(size)
        return cameraFrame(for: safeSize).ray(through: pixel, size: safeSize)
    }

    private var originCameraFrame: CameraFrame {
        CameraFrame.make(
            position: .zero,
            pan: wrappedYaw,
            tilt: clampedPitch,
            roll: 0,
            focalLength: focalLength,
            sensor: sensor,
            aspect: 1
        )
    }

    private var basisMatrix: Mat4 {
        originCameraFrame.viewMatrix().inverse
    }

    private static func clampDistance(_ value: Double) -> Double {
        guard value.isFinite else { return minDistance }
        return min(max(value, minDistance), maxDistance)
    }

    private static func clampPitch(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, -maxPitch), maxPitch)
    }

    private static func wrapAngle(_ angle: Double) -> Double {
        guard angle.isFinite else { return 0 }
        let rem = angle.remainder(dividingBy: 2 * .pi)
        if rem <= -.pi { return rem + 2 * .pi }
        if rem == -0.0 { return 0.0 }
        return rem
    }

    private static func resolvedPixelSize(_ size: PixelSize) -> PixelSize {
        PixelSize(width: max(size.width, 1), height: max(size.height, 1))
    }
}

private extension CameraFrame {
    func focused(at distance: Double?) -> CameraFrame {
        var copy = self
        copy.focusDistance = distance
        return copy
    }
}
