import Foundation

/// A still of a real set and its reusable camera match in the scene's shared coordinate system.
/// `imagePath` is relative to the project's `.conceptstudio` directory.
public struct LocationPlate: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var imagePath: String
    public var pixelSize: PixelSize
    public var calibration: PlateCalibration

    public init(
        id: String,
        name: String,
        imagePath: String,
        pixelSize: PixelSize,
        calibration: PlateCalibration = PlateCalibration()
    ) {
        self.id = id
        self.name = name
        self.imagePath = imagePath
        self.pixelSize = pixelSize
        self.calibration = calibration
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        try self.init(
            id: c.require("id"),
            name: c.value("name", "Plate"),
            imagePath: c.require("imagePath"),
            pixelSize: c.require("pixelSize"),
            calibration: c.value("calibration", PlateCalibration())
        )
    }

    /// Whether a marked solid is between the camera and a world point.
    public func isOccluded(_ point: Vec3, camera: CameraFrame, setPieces: [PlateSetPiece]) -> Bool {
        PlateSetPiece.occludes(point, camera: camera, pieces: setPieces)
    }

    /// The highest marked standing surface under this X/Z position, or the floor at zero.
    public func surfaceHeight(at point: Vec3, setPieces: [PlateSetPiece]) -> Double {
        setPieces.filter { $0.supportsStanding && $0.containsHorizontally(point) }
            .map { $0.position.y + $0.size.y }.reduce(0, max)
    }

    /// The complete original plate fits inside the output canvas, with even letterboxing if needed.
    public func imageRect(in size: PixelSize) -> PlateImageRect {
        let width = min(Double(size.width), Double(size.height) * pixelSize.aspect)
        let height = width / pixelSize.aspect
        return PlateImageRect(
            x: (Double(size.width) - width) / 2, y: (Double(size.height) - height) / 2,
            width: width, height: height
        )
    }

    public func project(_ point: Vec3, camera: CameraFrame, size: PixelSize) -> Point2? {
        guard let pixel = camera.project(point, size: pixelSize) else { return nil }
        let rect = imageRect(in: size)
        return Point2(
            x: rect.x + pixel.x / Double(pixelSize.width) * rect.width,
            y: rect.y + pixel.y / Double(pixelSize.height) * rect.height
        )
    }

    /// A ray through the fitted image. Pixels in the letterbox do not intersect the plate.
    public func ray(through pixel: Point2, camera: CameraFrame, size: PixelSize) -> (origin: Vec3, direction: Vec3)? {
        let rect = imageRect(in: size)
        guard pixel.x >= rect.x, pixel.x <= rect.x + rect.width,
              pixel.y >= rect.y, pixel.y <= rect.y + rect.height else { return nil }
        let native = Point2(
            x: (pixel.x - rect.x) / rect.width * Double(pixelSize.width),
            y: (pixel.y - rect.y) / rect.height * Double(pixelSize.height)
        )
        return camera.ray(through: native, size: pixelSize)
    }

    /// Places a foot on the nearest visible marked standing surface, falling back to the floor.
    /// The point is expressed in the matched plate's pixel coordinates.
    public func placementPoint(
        at pixel: Point2,
        size: PixelSize,
        setPieces: [PlateSetPiece],
        camera: CameraFrame? = nil
    ) -> Vec3? {
        let camera = camera ?? calibration.frame(aspect: pixelSize.aspect)
        guard let ray = ray(through: pixel, camera: camera, size: size), ray.direction.y < -1e-8 else { return nil }
        var candidates: [(distance: Double, point: Vec3)] = []
        let floorDistance = -ray.origin.y / ray.direction.y
        if floorDistance > 0 {
            candidates.append((floorDistance, ray.origin + ray.direction * floorDistance))
        }
        for piece in setPieces where piece.supportsStanding {
            let distance = (piece.position.y + piece.size.y - ray.origin.y) / ray.direction.y
            let point = ray.origin + ray.direction * distance
            if distance > 0, piece.containsHorizontally(point) {
                candidates.append((distance, point))
            }
        }
        return candidates.min { $0.distance < $1.distance }?.point
    }
}

public struct PlateImageRect: Sendable, Equatable {
    public var x: Double, y: Double, width: Double, height: Double
}

/// Metres, radians and millimetres, with the same projection as the shot camera.
public struct PlateCalibration: Codable, Sendable, Equatable {
    public var sensor: Sensor
    public var position: Vec3
    public var pan: Double
    public var tilt: Double
    public var roll: Double
    public var focalLength: Double
    public var confirmed: Bool

    public init(
        sensor: Sensor = .super35,
        position: Vec3 = Vec3(0, 1.6, 6),
        pan: Double = 0,
        tilt: Double = 0,
        roll: Double = 0,
        focalLength: Double = 35,
        confirmed: Bool = false
    ) {
        self.sensor = sensor
        self.position = position
        self.pan = pan
        self.tilt = tilt
        self.roll = roll
        self.focalLength = focalLength
        self.confirmed = confirmed
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        try self.init(
            sensor: c.value("sensor", .super35),
            position: c.value("position", Vec3(0, 1.6, 6)),
            pan: c.value("pan", 0),
            tilt: c.value("tilt", 0),
            roll: c.value("roll", 0),
            focalLength: c.value("focalLength", 35),
            confirmed: c.value("confirmed", false)
        )
    }

    public func frame(aspect: Double) -> CameraFrame {
        .make(
            position: position, pan: pan, tilt: tilt, roll: roll,
            focalLength: focalLength, sensor: sensor, aspect: aspect
        )
    }

    /// Includes lens/sensor equivalence through field of view, so physically equivalent optics match.
    public func matches(_ camera: CameraFrame, aspect: Double) -> Bool {
        let reference = frame(aspect: aspect)
        let angularDifference = abs(atan2(sin(camera.pan - pan), cos(camera.pan - pan)))
        return (camera.position - position).length <= 0.01
            && angularDifference <= 0.001
            && abs(camera.tilt - tilt) <= 0.001
            && abs(camera.roll - roll) <= 0.001
            && abs(camera.verticalFOV - reference.verticalFOV) <= 0.001
    }
}

/// A world-aligned solid whose position is the centre of its bottom face.
public struct PlateSetPiece: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var position: Vec3
    public var size: Vec3
    public var occludes: Bool
    public var supportsStanding: Bool

    public init(
        id: String,
        name: String,
        position: Vec3,
        size: Vec3,
        occludes: Bool = true,
        supportsStanding: Bool = true
    ) {
        self.id = id
        self.name = name
        self.position = position
        self.size = size
        self.occludes = occludes
        self.supportsStanding = supportsStanding
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        try self.init(
            id: c.require("id"),
            name: c.value("name", "Set piece"),
            position: c.value("position", .zero),
            size: c.value("size", Vec3(1, 1, 1)),
            occludes: c.value("occludes", true),
            supportsStanding: c.value("supportsStanding", true)
        )
    }

    public var bounds: Box3 {
        Box3(
            min: Vec3(position.x - size.x / 2, position.y, position.z - size.z / 2),
            max: Vec3(position.x + size.x / 2, position.y + size.y, position.z + size.z / 2)
        )
    }

    public func containsHorizontally(_ point: Vec3) -> Bool {
        let box = bounds
        return point.x >= box.min.x && point.x <= box.max.x && point.z >= box.min.z && point.z <= box.max.z
    }

    public static func occludes(_ point: Vec3, camera: CameraFrame, pieces: [PlateSetPiece]) -> Bool {
        let offset = point - camera.position
        let distance = offset.length
        guard distance > 0 else { return false }
        return pieces.contains { piece in
            guard piece.occludes,
                  let hit = piece.rayIntersection(origin: camera.position, direction: offset * (1 / distance))
            else { return false }
            return hit < distance - 0.001
        }
    }

    /// Distance along `direction` to the first intersection, or nil when the ray misses or points away.
    /// With a unit direction the result is in metres. A ray beginning inside the solid returns zero.
    public func rayIntersection(origin: Vec3, direction: Vec3) -> Double? {
        let box = bounds
        let axes = [
            (origin.x, direction.x, box.min.x, box.max.x),
            (origin.y, direction.y, box.min.y, box.max.y),
            (origin.z, direction.z, box.min.z, box.max.z),
        ]
        var entry = 0.0
        var exit = Double.infinity
        for (origin, direction, low, high) in axes {
            if abs(direction) < 1e-12 {
                if origin < low || origin > high { return nil }
            } else {
                let first = (low - origin) / direction
                let last = (high - origin) / direction
                entry = max(entry, min(first, last))
                exit = min(exit, max(first, last))
                if exit < entry { return nil }
            }
        }
        return exit >= 0 ? entry : nil
    }
}
