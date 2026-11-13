import Foundation
import PrevisCore

/// What the camera-match screen edits, and the camera those choices give. Every change solves again, so the grid
/// and the reference figure over the plate always show the camera that would be saved.
struct PlateMatchModel: Equatable {
    enum Handle: Hashable {
        case lineA(Int, end: Int), lineB(Int, end: Int), foot, top, figure
    }

    let size: PixelSize
    var linesA: [PlateLine]
    var linesB: [PlateLine]
    var usesLinesA: Bool {
        didSet { solve() }
    }

    var usesLinesB: Bool {
        didSet { solve() }
    }

    var lensFromLines: Bool {
        didSet { solve() }
    }

    var heightFromReference: Bool {
        didSet { solve() }
    }

    var sensor: Sensor {
        didSet { solve() }
    }

    var reference: PlateHeightReference
    /// The values typed when the lines don't decide them, in millimetres, metres and degrees.
    var lens: Double
    var height: Double
    var tiltDegrees: Double
    var rollDegrees: Double
    var panDegrees: Double
    var cameraX: Double
    var cameraZ: Double
    /// Where the reference figure stands on the floor, and how tall it is.
    var figureX: Double
    var figureZ: Double
    var figureHeight = 1.8

    private(set) var solved: PlateMatch
    private(set) var problem: String?

    init(plate: LocationPlate) {
        size = plate.size
        let match = plate.match ?? .unmatched
        solved = match
        let guides = plate.guides
        usesLinesA = guides.linesA.count >= 2
        usesLinesB = guides.linesB.count >= 2
        linesA = usesLinesA ? Array(guides.linesA.prefix(2)) : Self.startLinesA
        linesB = usesLinesB ? Array(guides.linesB.prefix(2)) : Self.startLinesB
        heightFromReference = guides.heightReference != nil
        reference = guides.heightReference ?? PlateHeightReference(
            foot: Point2(x: 0.5, y: 0.8), top: Point2(x: 0.5, y: 0.55), height: 1
        )
        lensFromLines = usesLinesA && usesLinesB
        sensor = match.sensor
        lens = match.focalLength
        height = match.position.y
        tiltDegrees = match.tilt * 180 / .pi
        rollDegrees = match.roll * 180 / .pi
        panDegrees = match.pan * 180 / .pi
        cameraX = match.position.x
        cameraZ = match.position.z
        figureX = match.position.x - 6 * sin(match.pan)
        figureZ = match.position.z - 6 * cos(match.pan)
        solve()
    }

    /// Two lines that lean toward each other like a table's long edges, and two across them: somewhere to start
    /// dragging from.
    private static let startLinesA = [
        PlateLine(a: Point2(x: 0.08, y: 0.62), b: Point2(x: 0.92, y: 0.56)),
        PlateLine(a: Point2(x: 0.08, y: 0.84), b: Point2(x: 0.92, y: 0.70)),
    ]
    private static let startLinesB = [
        PlateLine(a: Point2(x: 0.22, y: 0.92), b: Point2(x: 0.36, y: 0.58)),
        PlateLine(a: Point2(x: 0.80, y: 0.92), b: Point2(x: 0.66, y: 0.58)),
    ]

    /// Whether the lines decide the lens, so its field only reports.
    var lensIsSolved: Bool {
        usesLinesA && usesLinesB && lensFromLines && PlateSolve.linesGiveLens(guides, size: size)
    }

    /// Set when the lens is asked of the lines but one pair is parallel in the picture, so they can't give it.
    var lensNote: String? {
        guard usesLinesA, usesLinesB, lensFromLines, !PlateSolve.linesGiveLens(guides, size: size) else { return nil }
        return "One pair of lines is parallel in the picture, so the lines can't give the lens. "
            + "The lens typed here is used."
    }

    /// Whether the lines decide the tilt and the turn; with both sets they decide the roll too.
    var anglesAreSolved: Bool {
        usesLinesA
    }

    var guides: PlateGuides {
        PlateGuides(
            linesA: usesLinesA ? linesA : [],
            linesB: usesLinesB ? linesB : [],
            heightReference: heightFromReference ? reference : nil
        )
    }

    mutating func solve() {
        let typed = PlateMatch(
            position: Vec3(cameraX, height, cameraZ),
            pan: panDegrees * .pi / 180,
            tilt: tiltDegrees * .pi / 180,
            roll: usesLinesA && !usesLinesB ? 0 : rollDegrees * .pi / 180,
            focalLength: lens,
            sensor: sensor
        )
        do {
            let match = try PlateSolve.match(
                guides: guides, size: size, sensor: sensor, focalLength: lensIsSolved ? nil : lens,
                cameraHeight: heightFromReference ? nil : height, current: typed
            )
            solved = match
            problem = nil
            // The fields show what the lines found, so switching a set of lines off keeps the same camera.
            lens = match.focalLength
            height = match.position.y
            tiltDegrees = match.tilt * 180 / .pi
            rollDegrees = match.roll * 180 / .pi
            panDegrees = match.pan * 180 / .pi
        } catch {
            problem = error.localizedDescription
        }
    }

    /// The plate with this match, as it would be saved.
    func result(for plate: LocationPlate) -> LocationPlate {
        var plate = plate
        plate.match = solved
        plate.guides = guides
        return plate
    }

    // MARK: Handles

    /// Where a handle is on the plate, as fractions from the top left; nil when the figure is out of view.
    func position(of handle: Handle) -> Point2? {
        switch handle {
        case let .lineA(index, end): end == 0 ? linesA[index].a : linesA[index].b
        case let .lineB(index, end): end == 0 ? linesB[index].a : linesB[index].b
        case .foot: reference.foot
        case .top: reference.top
        case .figure: project(Vec3(figureX, 0, figureZ))
        }
    }

    mutating func move(_ handle: Handle, to point: Point2) {
        let point = Point2(x: min(max(point.x, 0), 1), y: min(max(point.y, 0), 1))
        switch handle {
        case let .lineA(index, end): if end == 0 { linesA[index].a = point } else { linesA[index].b = point }
        case let .lineB(index, end): if end == 0 { linesB[index].a = point } else { linesB[index].b = point }
        case .foot: reference.foot = point
        case .top: reference.top = point
        case .figure:
            // The figure follows the pointer along the floor.
            let ray = solved.camera(aspect: size.aspect).ray(
                through: Point2(x: point.x * Double(size.width), y: point.y * Double(size.height)), size: size
            )
            guard ray.direction.y < -1e-3 else { return }
            let distance = -ray.origin.y / ray.direction.y
            guard distance < 150 else { return }
            figureX = ray.origin.x + ray.direction.x * distance
            figureZ = ray.origin.z + ray.direction.z * distance
            return
        }
        solve()
    }

    /// Puts the reference figure six metres in front of the camera.
    mutating func recallFigure() {
        figureX = solved.position.x - 6 * sin(solved.pan)
        figureZ = solved.position.z - 6 * cos(solved.pan)
    }

    /// A world point as fractions of the plate; nil behind the camera.
    func project(_ point: Vec3) -> Point2? {
        guard let pixel = solved.camera(aspect: size.aspect).project(point, size: size) else { return nil }
        return Point2(x: pixel.x / Double(size.width), y: pixel.y / Double(size.height))
    }

    /// The floor's one-metre grid around the camera, as runs of plate fractions ready to stroke.
    func floorGrid(reach: Int = 24) -> [[Point2]] {
        let centreX = solved.position.x.rounded(), centreZ = solved.position.z.rounded()
        var runs: [[Point2]] = []
        func add(_ points: [Vec3]) {
            var run: [Point2] = []
            for point in points {
                if let projected = project(point), abs(projected.x) < 6, abs(projected.y) < 6 {
                    run.append(projected)
                } else {
                    if run.count > 1 { runs.append(run) }
                    run = []
                }
            }
            if run.count > 1 { runs.append(run) }
        }
        let steps = stride(from: -Double(reach), through: Double(reach), by: 0.5)
        for offset in -reach ... reach {
            add(steps.map { Vec3(centreX + $0, 0, centreZ + Double(offset)) })
            add(steps.map { Vec3(centreX + Double(offset), 0, centreZ + $0) })
        }
        return runs
    }

    /// The reference figure's foot and head on the plate; nil when it is out of view.
    var figureSpan: (foot: Point2, head: Point2)? {
        guard let foot = project(Vec3(figureX, 0, figureZ)),
              let head = project(Vec3(figureX, figureHeight, figureZ))
        else { return nil }
        return (foot, head)
    }

    /// The horizon's ends at the plate's left and right edges, as fractions.
    var horizon: (left: Point2, right: Point2)? {
        guard let line = solved.horizon(size: size) else { return nil }
        let height = Double(size.height)
        return (Point2(x: 0, y: line.left.y / height), Point2(x: 1, y: line.right.y / height))
    }

    /// The camera in one sentence, for the summary line and VoiceOver.
    var summary: String {
        let tilt = solved.tilt * 180 / .pi
        let angle = abs(tilt) < 0.5 ? "level" : String(format: "tilted %.1f° %@", abs(tilt), tilt < 0 ? "down" : "up")
        return String(
            format: "Camera %.2f m above the floor, %@, %.0f mm lens.",
            solved.position.y,
            angle,
            solved.focalLength
        )
    }
}
