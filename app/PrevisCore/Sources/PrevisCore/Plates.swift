import Foundation

// Location plates, CONTRACTS section 5.7. A plate is an approved still of the empty set. A shot blocked over a
// plate takes its first camera position from the plate's match, so a stand-in on the plate's floor has the size
// and place a person there would have. Nothing here reads the image: the match is solved from what the user
// marks on it.

public typealias PlateID = String

public struct LocationPlate: Codable, Sendable, Equatable, Identifiable {
    public var id: PlateID
    public var name: String
    public var file: String // the image's file name inside the project's Shots/Plates folder
    public var size: PixelSize // the image's own pixels
    public var match: PlateMatch? // nil until the camera has been matched
    public var guides: PlateGuides // what the user marked to make the match, kept so it can be corrected

    public var aspect: Double {
        size.aspect
    }

    public init(
        id: PlateID,
        name: String,
        file: String,
        size: PixelSize,
        match: PlateMatch? = nil,
        guides: PlateGuides
    ) {
        self.id = id
        self.name = name
        self.file = file
        self.size = size
        self.match = match
        self.guides = guides
    }
}

/// The camera that took a plate, in the scene's world: the plate's floor is the ground plane, y = 0.
public struct PlateMatch: Codable, Sendable, Equatable {
    public var position: Vec3 // y is the camera's height above the plate's floor
    public var pan: Double, tilt: Double, roll: Double
    public var focalLength: Double // millimetres
    public var sensor: Sensor

    public init(position: Vec3, pan: Double, tilt: Double, roll: Double, focalLength: Double, sensor: Sensor) {
        self.position = position
        self.pan = pan
        self.tilt = tilt
        self.roll = roll
        self.focalLength = focalLength
        self.sensor = sensor
    }

    /// A level camera at standing eye height: where a plate starts before it is matched.
    public static let unmatched = PlateMatch(
        position: Vec3(0, 1.6, 0), pan: 0, tilt: 0, roll: 0, focalLength: 35, sensor: .super35
    )

    public func camera(aspect: Double) -> CameraFrame {
        CameraFrame.make(
            position: position, pan: pan, tilt: tilt, roll: roll, focalLength: focalLength, sensor: sensor,
            aspect: aspect
        )
    }

    /// The camera mark a shot on this plate starts from.
    public func cameraMark(id: MarkID) -> CameraMark {
        CameraMark(
            id: id, time: 0, hold: 0, easeIn: 0, easeOut: 0, position: position, pan: pan, tilt: tilt, roll: roll,
            focalLength: focalLength
        )
    }

    /// Whether `camera` is this plate's camera, closely enough that stand-ins still sit on the plate's floor:
    /// within a centimetre, a twentieth of a degree and a tenth of a millimetre of lens.
    public func agrees(with camera: CameraFrame) -> Bool {
        let offset = camera.position - position
        return offset.length < 0.01 && abs(angleDifference(camera.pan, pan)) < 0.001
            && abs(camera.tilt - tilt) < 0.001 && abs(angleDifference(camera.roll, roll)) < 0.001
            && abs(camera.focalLength - focalLength) < 0.1
    }

    /// Where the horizon crosses the left and right edges of an image of `size`, in pixels; nil when the camera
    /// looks straight up or down.
    public func horizon(size: PixelSize) -> (left: Point2, right: Point2)? {
        let frame = camera(aspect: size.aspect)
        let up = frame.orientation.conjugate.rotate(Vec3(0, 1, 0))
        guard abs(up.y) > 1e-6 else { return nil }
        let focal = Double(size.height) / 2 / tan(frame.verticalFOV / 2)
        let half = Double(size.width) / 2
        func row(_ x: Double) -> Double {
            // A camera-space direction (x, −y, −f) is level when it is square to `up`.
            (up.x * x - up.z * focal) / up.y + Double(size.height) / 2
        }
        return (Point2(x: 0, y: row(-half)), Point2(x: Double(size.width), y: row(half)))
    }
}

/// A line the user drew on a plate. Both ends are fractions of the plate's width and height, from the top left.
public struct PlateLine: Codable, Sendable, Equatable {
    public var a: Point2, b: Point2

    public init(a: Point2, b: Point2) {
        self.a = a
        self.b = b
    }
}

/// Something of known height standing on the plate's floor: its foot and its top, as fractions of the plate.
public struct PlateHeightReference: Codable, Sendable, Equatable {
    public var foot: Point2, top: Point2
    public var height: Double // metres

    public init(foot: Point2, top: Point2, height: Double) {
        self.foot = foot
        self.top = top
        self.height = height
    }
}

public struct PlateGuides: Codable, Sendable, Equatable {
    /// Two lines that are parallel in the set and level with its floor, such as the two long edges of a table.
    public var linesA: [PlateLine]
    /// Two more, square to the first two on the floor, such as the table's short edges.
    public var linesB: [PlateLine]
    public var heightReference: PlateHeightReference?

    public init(linesA: [PlateLine] = [], linesB: [PlateLine] = [], heightReference: PlateHeightReference? = nil) {
        self.linesA = linesA
        self.linesB = linesB
        self.heightReference = heightReference
    }

    public static let none = PlateGuides()
}

public extension LocationPlate {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        try self.init(
            id: c.require("id"),
            name: c.value("name", ""),
            file: c.value("file", ""),
            size: c.value("size", PixelSize(width: 1440, height: 2560)),
            match: c.optional("match"),
            guides: c.value("guides", .none)
        )
    }
}

public extension PlateMatch {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        let base = PlateMatch.unmatched
        try self.init(
            position: c.value("position", base.position),
            pan: c.value("pan", 0),
            tilt: c.value("tilt", 0),
            roll: c.value("roll", 0),
            focalLength: c.value("focalLength", base.focalLength),
            sensor: c.value("sensor", base.sensor)
        )
    }
}

public extension PlateGuides {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        try self.init(
            linesA: c.value("linesA", []),
            linesB: c.value("linesB", []),
            heightReference: c.optional("heightReference")
        )
    }
}

/// Where a plate sits on a canvas when both are seen through the same camera. The plate keeps its shape and is
/// centred; with a canvas of the plate's own shape it covers the canvas exactly.
public enum PlateFit {
    /// A rectangle in canvas pixels, origin at the top left.
    public struct Rect: Sendable, Equatable {
        public var x: Double, y: Double, width: Double, height: Double
    }

    /// The plate's rectangle on the canvas. It can be larger or smaller than the canvas when their shapes differ.
    public static func rect(plate: PixelSize, canvas: PixelSize, sensor: Sensor) -> Rect {
        let scale = sensor.gateHeight(aspect: plate.aspect) / sensor.gateHeight(aspect: canvas.aspect)
        let height = Double(canvas.height) * scale
        let width = height * plate.aspect
        return Rect(
            x: (Double(canvas.width) - width) / 2, y: (Double(canvas.height) - height) / 2, width: width,
            height: height
        )
    }

    /// The part of the plate's width the canvas shows beyond or short of the plate, as a fraction: 0 when the
    /// shapes agree, positive when the canvas is wider than the plate.
    public static func widthMismatch(plate: PixelSize, canvas: PixelSize, sensor: Sensor) -> Double {
        let fit = rect(plate: plate, canvas: canvas, sensor: sensor)
        return Double(canvas.width) / fit.width - 1
    }
}

/// Solves a plate's camera from the lines and the height reference the user marked on it.
public enum PlateSolve {
    /// - `focalLength`: the lens in millimetres when the user sets it; nil solves it from the two sets of lines.
    /// - `cameraHeight`: the camera's height in metres when the user sets it; nil solves it from the height
    ///   reference, or keeps `current`'s.
    /// - `current`: the match being corrected. Whatever the guides don't determine is kept from it.
    ///
    /// The world is turned so that the first set of lines runs along a world axis: set pieces placed square to the
    /// world then sit square to the plate's furniture.
    public static func match(
        guides: PlateGuides,
        size: PixelSize,
        sensor: Sensor,
        focalLength: Double? = nil,
        cameraHeight: Double? = nil,
        current: PlateMatch? = nil
    ) throws -> PlateMatch {
        let base = current ?? .unmatched
        let gate = sensor.gateHeight(aspect: size.aspect)
        let pointA = vanishingPoint(guides.linesA, size: size)
        let pointB = vanishingPoint(guides.linesB, size: size)
        if !guides.linesA.isEmpty, pointA == nil {
            throw problem("The first two lines are the same line. Draw them along two different edges.")
        }
        if !guides.linesB.isEmpty, pointB == nil {
            throw problem("The second two lines are the same line. Draw them along two different edges.")
        }

        var focalPixels = (focalLength ?? base.focalLength) * Double(size.height) / gate
        if focalLength == nil, let a = pointA, let b = pointB, linesGiveLens(guides, size: size) {
            // Two level directions square to each other: their camera-space directions have a zero dot product.
            let squared = -(a.x * b.x + a.y * b.y) / (a.w * b.w)
            guard squared > 0 else {
                throw problem(
                    "These two sets of lines can't be square to each other through any lens. Draw each set along "
                        + "edges that are parallel in the set, the two sets at a right angle on the floor, "
                        + "or set the lens yourself."
                )
            }
            focalPixels = squared.squareRoot()
        }
        let lens = focalPixels * gate / Double(size.height)
        guard lens.isFinite, (6 ... 400).contains(lens) else {
            throw problem(
                "The lines give a \(Int(lens.rounded())) mm lens, which no camera here has. Check that each set "
                    + "follows parallel edges, or set the lens yourself."
            )
        }

        var match = base
        match.sensor = sensor
        match.focalLength = lens
        if let a = pointA {
            let directionA = Vec3(a.x, -a.y, -focalPixels * a.w).normalized
            let up: Vec3
            if let b = pointB {
                let directionB = Vec3(b.x, -b.y, -focalPixels * b.w).normalized
                let normal = directionA.cross(directionB)
                guard normal.length > 1e-6 else {
                    throw problem("Both sets of lines run the same way. Draw the second set across the first.")
                }
                up = normal.y < 0 ? normal.normalized * -1 : normal.normalized
            } else if abs(a.w) > 1e-9 {
                // One set of lines and a level horizon: the horizon runs through their vanishing point.
                let tilt = atan(a.y / a.w / focalPixels)
                up = Vec3(0, cos(tilt), -sin(tilt))
            } else {
                up = base.camera(aspect: size.aspect).orientation.conjugate.rotate(Vec3(0, 1, 0))
            }
            let level = directionA - up * directionA.dot(up)
            guard level.length > 1e-6 else {
                throw problem("The first set of lines points straight up or down. Draw it along the floor.")
            }
            let x = level.normalized
            let z = x.cross(up)
            // The camera looks down its own −Z; in the world that is (−x.z, −up.z, −z.z).
            match.tilt = asin(min(max(-up.z, -1), 1))
            let pan = atan2(x.z, z.z)
            match.pan = pan - (pan / (.pi / 2)).rounded() * (.pi / 2)
            match.roll = atan2(up.x, up.y)
        }

        var height = cameraHeight ?? base.position.y
        if cameraHeight == nil, let reference = guides.heightReference {
            height = try Self.height(from: reference, match: match, size: size)
        }
        guard height.isFinite, height > 0.05, height < 200 else {
            throw problem("The camera height comes out at \(height) m. Check the height reference.")
        }
        match.position = Vec3(base.position.x, height, base.position.z)
        return match
    }

    /// Whether both pairs of lines are there and each converges in the picture. A camera that looks straight
    /// along the set sees one pair as parallel lines; that pair still gives the horizon, but no lens, and the
    /// lens of `current` (or the one given) is used.
    public static func linesGiveLens(_ guides: PlateGuides, size: PixelSize) -> Bool {
        guard let a = vanishingPoint(guides.linesA, size: size), let b = vanishingPoint(guides.linesB, size: size)
        else { return false }
        // A pair that meets further than a hundred picture-heights away is parallel for this purpose.
        let far = 100 * Double(max(size.width, size.height))
        func converges(_ point: (x: Double, y: Double, w: Double)) -> Bool {
            abs(point.w) * far > max(abs(point.x), abs(point.y))
        }
        return converges(a) && converges(b)
    }

    /// The camera height at which something `reference.height` tall, standing on the floor at the marked foot,
    /// reaches the marked top.
    private static func height(
        from reference: PlateHeightReference, match: PlateMatch, size: PixelSize
    ) throws -> Double {
        guard reference.height.isFinite, reference.height > 0 else {
            throw problem("The height reference needs a height above zero, in metres.")
        }
        var unit = match
        unit.position = .zero
        let camera = unit.camera(aspect: size.aspect)
        func ray(_ point: Point2) -> Vec3 {
            camera.ray(
                through: Point2(x: point.x * Double(size.width), y: point.y * Double(size.height)), size: size
            ).direction
        }
        let foot = ray(reference.foot), top = ray(reference.top)
        guard foot.y < -1e-6 else {
            throw problem(
                "The foot of the height reference is on or above the horizon, so it can't be on the floor. "
                    + "Put the foot where the object meets the floor."
            )
        }
        // With the camera h above the floor, the foot is h · run away, and the top's ray is h · run · rise higher
        // than the camera there.
        let run = hypot(foot.x, foot.z) / -foot.y
        let rise = top.y / max(hypot(top.x, top.z), 1e-9)
        let denominator = 1 + run * rise
        guard denominator > 0.02 else {
            throw problem("The top of the height reference is below its foot. Drag the top above the foot.")
        }
        return reference.height / denominator
    }

    /// Where two image lines meet, in homogeneous pixels measured from the image centre with y down. `w` near zero
    /// means the lines are parallel in the image too. Nil when the two are one line, or there are fewer than two.
    private static func vanishingPoint(_ lines: [PlateLine], size: PixelSize) -> (x: Double, y: Double, w: Double)? {
        guard lines.count >= 2 else { return nil }
        let width = Double(size.width), height = Double(size.height)
        func line(_ line: PlateLine) -> Vec3 {
            let a = Vec3((line.a.x - 0.5) * width, (line.a.y - 0.5) * height, 1)
            let b = Vec3((line.b.x - 0.5) * width, (line.b.y - 0.5) * height, 1)
            return a.cross(b).normalized
        }
        let meet = line(lines[0]).cross(line(lines[1]))
        let largest = max(abs(meet.x), abs(meet.y), abs(meet.z) * max(width, height))
        guard largest > 1e-9 else { return nil }
        // Scaled so that x and y are pixels when the lines meet inside or near the image.
        let scale = 1 / max(abs(meet.x), abs(meet.y), abs(meet.z))
        return (meet.x * scale, meet.y * scale, meet.z * scale)
    }

    private static func problem(_ message: String) -> ShotsError {
        ShotsError.invalid([ShotsProblem(severity: .error, message: message)])
    }
}

/// The signed difference `a − b`, wrapped to −π ... π.
func angleDifference(_ a: Double, _ b: Double) -> Double {
    var d = (a - b).truncatingRemainder(dividingBy: 2 * .pi)
    if d > .pi { d -= 2 * .pi }
    if d < -.pi { d += 2 * .pi }
    return d
}

extension Sensor {
    /// The height of the gate a canvas of `aspect` uses, in millimetres: the full gate height, or less when the
    /// canvas is wider than the gate.
    func gateHeight(aspect: Double) -> Double {
        min(gate.height, gate.width / aspect)
    }
}
