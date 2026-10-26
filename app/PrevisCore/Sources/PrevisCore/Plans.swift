// Translated from Blockout (https://github.com/wassermanproductions/blockout) src/engine/{evaluate,path}.ts at
// 3f2d0564,
// Apache-2.0, by Sam Wasserman (wassermanproductions.com). Changes: immutable plans built once from the marks, with
// A5's corrected facing. See Resources/NOTICE.

import Foundation

// MARK: - Plans

/// A mark's timing and route, the part shared by actor and camera marks.
struct Waypoint: Sendable {
    var id: MarkID
    var time: Double
    var hold: Double
    var easeIn: Double
    var easeOut: Double
    var position: Vec3
    var via: [Vec3]

    init(_ mark: ActorMark) {
        (id, time, hold, easeIn, easeOut, position, via) =
            (mark.id, mark.time, mark.hold, mark.easeIn, mark.easeOut, mark.position, mark.via)
    }

    init(_ mark: CameraMark) {
        (id, time, hold, easeIn, easeOut, position, via) =
            (mark.id, mark.time, mark.hold, mark.easeIn, mark.easeOut, mark.position, mark.via)
    }
}

struct Leg: Sendable {
    var from: Int
    var to: Int
    var depart: Double
    var arrive: Double
    var path: PathCurve
    var distanceBefore: Double
}

struct TrackSample {
    var position: Vec3
    var travelHeading: Double?
    var distance: Double
    var speed: Double
    var leg: Int?
    var atMark: Int?
    var legProgress: Double
    var pathDistance: Double

    init(
        position: Vec3,
        travelHeading: Double? = nil,
        distance: Double,
        speed: Double,
        leg: Int? = nil,
        atMark: Int? = nil,
        legProgress: Double,
        pathDistance: Double = 0
    ) {
        self.position = position
        self.travelHeading = travelHeading
        self.distance = distance
        self.speed = speed
        self.leg = leg
        self.atMark = atMark
        self.legProgress = legProgress
        self.pathDistance = pathDistance
    }
}

/// Marks sorted stably by `(time, index)` and the legs between them.
struct TrackPlan: Sendable {
    let waypoints: [Waypoint]
    let order: [Int]
    let legs: [Leg]

    init(waypoints unsorted: [Waypoint]) {
        let ordered = unsorted.enumerated().sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }
        order = ordered.map(\.offset)
        waypoints = ordered.map(\.element)
        var built: [Leg] = []
        var before = 0.0
        for i in 0 ..< max(waypoints.count - 1, 0) {
            let from = waypoints[i], to = waypoints[i + 1]
            let depart = min(from.time + from.hold, max(from.time, to.time - 0.1))
            let arrive = max(to.time, depart + 0.001)
            let path = PathCurve([from.position] + to.via + [to.position])
            built.append(Leg(from: i, to: i + 1, depart: depart, arrive: arrive, path: path, distanceBefore: before))
            before += path.length
        }
        legs = built
    }

    /// `marks` in the order they were given, sorted the way this plan sorted its waypoints.
    func sortedMarks<Mark>(of marks: [Mark]) -> [Mark] {
        order.map { marks[$0] }
    }

    func sample(at t: Double) -> TrackSample {
        guard let firstMark = waypoints.first else {
            return TrackSample(position: .zero, distance: 0, speed: 0, legProgress: 0)
        }
        if legs.isEmpty || t <= firstMark.time {
            return TrackSample(position: firstMark.position, distance: 0, speed: 0, atMark: 0, legProgress: 0)
        }
        for (index, leg) in legs.enumerated() {
            let from = waypoints[leg.from], to = waypoints[leg.to]
            if t < leg.depart {
                return TrackSample(
                    position: from.position,
                    distance: leg.distanceBefore,
                    speed: 0,
                    atMark: leg.from,
                    legProgress: 0
                )
            }
            if t <= leg.arrive {
                let span = leg.arrive - leg.depart
                let u = (t - leg.depart) / span
                let progress = easedProgress(u, easeOut: from.easeOut, easeIn: to.easeIn)
                let d = progress * leg.path.length
                let du = 0.001
                let next = easedProgress(min(1, u + du), easeOut: from.easeOut, easeIn: to.easeIn)
                return TrackSample(
                    position: leg.path.point(at: d),
                    travelHeading: leg.path.length > 0.001 ? leg.path.heading(at: d) : nil,
                    distance: leg.distanceBefore + d,
                    speed: ((next - progress) * leg.path.length) / (du * span),
                    leg: index,
                    legProgress: u,
                    pathDistance: d
                )
            }
        }
        let last = legs[legs.count - 1]
        return TrackSample(
            position: waypoints[last.to].position,
            distance: last.distanceBefore + last.path.length,
            speed: 0,
            atMark: last.to,
            legProgress: 1
        )
    }

    /// The end heading of the latest finished leg that moved.
    func lastTravelHeading(at t: Double) -> Double? {
        legs.last { t >= $0.arrive && $0.path.length > 0.001 }.map { $0.path.heading(at: $0.path.length) }
    }

    func motionPath(subject: MotionPath.Subject) -> MotionPath {
        var points: [Vec3] = []
        for (index, leg) in legs.enumerated() {
            points += index == 0 ? leg.path.samples : Array(leg.path.samples.dropFirst())
        }
        if points.isEmpty, let only = waypoints.first { points = [only.position] }
        return MotionPath(
            subject: subject,
            points: points,
            marks: waypoints.map { PathMark(id: $0.id, time: $0.time, position: $0.position) }
        )
    }
}

/// An actor's track: its plan, marks in plan order, and the time of its first mark.
struct ActorPlan: Sendable {
    let track: TrackPlan
    let marks: [ActorMark]
    let corrections: Corrections
    /// The facing on arriving at each mark, and on leaving it (after any turn the mark authors).
    private let arrival: [Double]
    private let departure: [Double]

    init(marks unsorted: [ActorMark], placementHeading: Double = 0, corrections: Corrections = []) {
        let plan = TrackPlan(waypoints: unsorted.map(Waypoint.init))
        let sorted = plan.sortedMarks(of: unsorted)
        track = plan
        marks = sorted
        self.corrections = corrections

        // Facings are only needed by the corrected heading; Blockout's reads them from the path as it goes.
        var arrive = [Double](repeating: placementHeading, count: sorted.count)
        var leave = arrive
        let turns = corrections.contains(.authoredTurns), vertical = corrections.contains(.verticalHeading)
        for index in sorted.indices {
            if index > 0 {
                let leg = plan.legs[index - 1], mark = sorted[index]
                if turns, let heading = mark.arriveHeading, mark.hold <= 0 {
                    arrive[index] = heading
                } else if leg.path.length > 0.001 {
                    arrive[index] = vertical
                        ? leg.path.headingIfMoving(at: leg.path.length) ?? leave[index - 1]
                        : leg.path.heading(at: leg.path.length)
                } else {
                    arrive[index] = leave[index - 1]
                }
            }
            leave[index] = sorted[index].arriveHeading ?? arrive[index]
        }
        arrival = arrive
        departure = leave
    }

    var firstTime: Double {
        track.waypoints.first?.time ?? 0
    }

    func pose(at time: Double, fallbackHeading: Double) -> EntityPose {
        let r = track.sample(at: time)
        let heading = corrections.isDisjoint(with: [.authoredTurns, .verticalHeading])
            ? blockoutHeading(r, at: time, fallback: fallbackHeading)
            : facing(r, at: time, fallback: fallbackHeading)
        var gait = r.atMark.map { marks[$0].gait } ?? .stand
        var joints: [Joint: Double] = r.atMark.map { marks[$0].joints } ?? [:]
        if let legIndex = r.leg {
            let leg = track.legs[legIndex]
            let from = marks[leg.from], to = marks[leg.to]
            gait = to.gait.travels ? to.gait : .walk
            let u = easedProgress(r.legProgress, easeOut: from.easeOut, easeIn: to.easeIn)
            joints = Self.blend(from.joints, to.joints, u)
        }
        return EntityPose(
            position: r.position,
            heading: heading,
            gait: gait,
            speed: r.speed,
            distanceTravelled: r.distance,
            joints: joints
        )
    }

    /// Blockout's rule: the travel heading, else the heading authored at the mark, else the last travel heading, else
    /// the placement. An authored turn therefore snaps on at the end of a leg, and a vertical leg faces −Z.
    private func blockoutHeading(_ r: TrackSample, at time: Double, fallback: Double) -> Double {
        r.travelHeading
            ?? r.atMark.flatMap { marks[$0].arriveHeading }
            ?? track.lastTravelHeading(at: time)
            ?? fallback
    }

    private func facing(_ r: TrackSample, at time: Double, fallback: Double) -> Double {
        let turns = corrections.contains(.authoredTurns), vertical = corrections.contains(.verticalHeading)
        if let index = r.leg {
            let leg = track.legs[index]
            let from = marks[leg.from], to = marks[leg.to]
            let start = departure[leg.from]
            // An authored turn at a mark with no hold blends over the whole leg that arrives at it.
            if turns, let heading = to.arriveHeading, to.hold <= 0 {
                return lerpAngle(start, heading, easedProgress(r.legProgress, easeOut: from.easeOut, easeIn: to.easeIn))
            }
            if let travel = r.travelHeading {
                return vertical ? leg.path.headingIfMoving(at: r.pathDistance) ?? start : travel
            }
            // A leg that goes nowhere: Blockout falls back to the placement; the corrected turn keeps the facing.
            return turns ? start : blockoutHeading(r, at: time, fallback: fallback)
        }
        guard let mark = r.atMark else { return fallback }
        guard turns else { return blockoutHeading(r, at: time, fallback: fallback) }
        let m = marks[mark]
        guard let heading = m.arriveHeading else { return arrival[mark] }
        // An authored turn at a mark with a hold blends over that hold; one with none is already done.
        let window = track.legs.first { $0.from == mark }.map { $0.depart - m.time } ?? m.hold
        guard m.hold > 0, window > 0, time < m.time + window else { return heading }
        let u = easedProgress((time - m.time) / window, easeOut: m.easeIn, easeIn: m.easeOut)
        return lerpAngle(arrival[mark], heading, u)
    }

    /// Joints missing from one side read as 0.
    static func blend(_ from: [Joint: Double], _ to: [Joint: Double], _ u: Double) -> [Joint: Double] {
        var out: [Joint: Double] = [:]
        for joint in Set(from.keys).union(to.keys) {
            let a = from[joint] ?? 0, b = to[joint] ?? 0
            out[joint] = a + (b - a) * u
        }
        return out
    }
}

extension Gait {
    /// Whether travelling toward a mark in this gait keeps it; the others walk while moving.
    var travels: Bool {
        switch self {
        case .walk, .jog, .run, .crouch: true
        case .stand, .sit, .lie, .gesture, .fall: false
        }
    }
}

/// A position and yaw in a parent's frame.
struct Offset: Sendable {
    var x: Double, y: Double, z: Double, rotY: Double

    func apply(toParent position: Vec3, heading: Double) -> Vec3 {
        let c = cos(heading), s = sin(heading)
        return Vec3(position.x + x * c + z * s, position.y + y, position.z - x * s + z * c)
    }
}

/// A rider's boardings: the marks that board, and the offset captured at each from the vehicle's pose then.
struct Boarding: Sendable {
    var entityID: EntityID
    var marks: [ActorMark]
    var offsets: [MarkID: Offset]

    static func offset(of mark: ActorMark, from vehicle: Vec3, heading: Double) -> Offset {
        let dx = mark.position.x - vehicle.x, dz = mark.position.z - vehicle.z
        let c = cos(heading), s = sin(heading)
        return Offset(
            x: dx * c - dz * s,
            y: mark.position.y - vehicle.y,
            z: dx * s + dz * c,
            rotY: mark.arriveHeading.map { $0 - heading } ?? 0
        )
    }
}
