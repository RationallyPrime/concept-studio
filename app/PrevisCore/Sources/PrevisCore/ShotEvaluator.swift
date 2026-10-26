// Translated from Blockout (https://github.com/wassermanproductions/blockout) src/engine/evaluate.ts at 3f2d0564,
// Apache-2.0, by Sam Wasserman (wassermanproductions.com). Changes: contract types, immutable plans built once in
// the initialiser, boarding offsets precomputed instead of cached. See Resources/NOTICE.

import Foundation

// CONTRACTS section 5.4. Legs, paths, easing, holds and joint blending; boarding and attachments as Blockout's
// four passes (A5 replaces them with one dependency-ordered graph); the camera with lens, aim lock, mount and rig
// noise. Bodies, keypoints and validation arrive in A3 and A5.

public struct ShotEvaluator: Sendable {
    private let shot: Shot
    private let aspect: Double
    private let entities: [Resolved]
    private let tracks: [EntityID: ActorPlan]
    private let boardings: [Boarding]
    private let camera: TrackPlan

    struct Resolved: Sendable {
        var entity: PrevisEntity
        var asset: AssetSpec
        var height: Double {
            asset.height * entity.placement.scale
        }
    }

    public init(scene: PrevisScene, shotID: ShotID, catalog: ContentCatalog) throws {
        try self.init(scene: scene, shotID: shotID, catalog: catalog, aspect: nil)
    }

    /// `aspect` replaces the canvas aspect for the field of view: parity tests construct with Blockout's exact
    /// aspect, because the importer maps aspects onto 32-multiple canvases.
    init(scene: PrevisScene, shotID: ShotID, catalog: ContentCatalog, aspect: Double?) throws {
        guard let shot = scene.shots.first(where: { $0.id == shotID }) else {
            throw ShotsError.invalid([
                ShotsProblem(
                    severity: .error,
                    message: "Scene \"\(scene.name)\" has no shot with id \(shotID); pick one of its shots.",
                    sceneID: scene.id,
                    shotID: shotID
                ),
            ])
        }
        var problems: [ShotsProblem] = []
        var resolved: [Resolved] = []
        for entity in scene.entities {
            if let asset = catalog.asset(entity.assetID) {
                resolved.append(Resolved(entity: entity, asset: asset))
            } else {
                problems.append(
                    ShotsProblem(
                        severity: .error,
                        message: "\"\(entity.name)\" uses the unknown asset \(entity.assetID); "
                            + "choose an asset from the catalog.",
                        sceneID: scene.id,
                        shotID: shotID,
                        entityID: entity.id
                    )
                )
            }
        }
        if !problems.isEmpty { throw ShotsError.invalid(problems) }

        let take = scene.blocking.first { $0.id == shot.blockingTakeID } ?? scene.blocking.first
        var plans: [EntityID: ActorPlan] = [:]
        var boardingOrder: [EntityID] = []
        var boardingMarks: [EntityID: [ActorMark]] = [:]
        let known = Set(resolved.map(\.entity.id))
        for track in take?.tracks ?? [] where known.contains(track.entityID) && !track.marks.isEmpty {
            let plan = ActorPlan(marks: track.marks)
            plans[track.entityID] = plan
            for mark in plan.marks where mark.boardID != nil {
                if boardingMarks[track.entityID] == nil { boardingOrder.append(track.entityID) }
                boardingMarks[track.entityID, default: []].append(mark)
            }
        }

        self.shot = shot
        self.aspect = aspect ?? shot.canvas.aspect
        entities = resolved
        tracks = plans
        camera = TrackPlan(waypoints: shot.camera.marks.map(Waypoint.init))
        boardings = boardingOrder.map { id in
            let marks = boardingMarks[id] ?? []
            return Boarding(
                entityID: id,
                marks: marks,
                offsets: Dictionary(
                    marks.compactMap { mark in
                        mark.boardID.map { target in
                            let (position, heading) = Self.pose(
                                of: target,
                                at: mark.time,
                                entities: resolved,
                                tracks: plans
                            )
                            return (mark.id, Boarding.offset(of: mark, from: position, heading: heading))
                        }
                    },
                    uniquingKeysWith: { first, _ in first }
                )
            )
        }
    }

    public var frameCount: Int {
        shot.frameCount
    }

    public func frame(_ index: Int) -> SceneFrame {
        let clamped = min(max(index, 0), max(shot.frameCount - 1, 0))
        return sceneFrame(index: clamped, time: FrameGrid.time(ofFrame: clamped))
    }

    public func frame(at time: Double) -> SceneFrame {
        sceneFrame(index: nil, time: min(max(time.isFinite ? time : 0, 0), shot.duration))
    }

    /// Speed, 180° line, trained range and marks past the end. None are checked yet (A5).
    public func warnings() -> [ShotsProblem] {
        []
    }

    /// Each moving entity's path with its marks, then the camera's.
    public func paths() -> [MotionPath] {
        var out: [MotionPath] = []
        for resolved in entities {
            guard let plan = tracks[resolved.entity.id] else { continue }
            out.append(plan.track.motionPath(subject: .entity(resolved.entity.id)))
        }
        if !shot.camera.marks.isEmpty { out.append(camera.motionPath(subject: .camera)) }
        return out
    }

    // MARK: Frames

    private func sceneFrame(index: Int?, time: Double) -> SceneFrame {
        var poses = entities.map { pose(of: $0, at: time) }
        resolveBoardings(&poses, at: time)
        resolveAttachments(&poses, at: time)
        let frames = zip(entities, poses).map { EntityFrame.posed($0.entity, asset: $0.asset, state: $1) }
        return SceneFrame(
            index: index,
            time: time,
            canvas: shot.canvas,
            camera: cameraFrame(at: time, poses: poses),
            entities: frames
        )
    }

    private func pose(of resolved: Resolved, at time: Double) -> EntityPose {
        let placement = resolved.entity.placement
        guard let plan = tracks[resolved.entity.id] else {
            return EntityPose(position: placement.position, heading: placement.heading)
        }
        return plan.pose(at: time, fallbackHeading: placement.heading)
    }

    /// Where a target stands and faces at `time`, ignoring boarding and attachment.
    private static func pose(
        of id: EntityID,
        at time: Double,
        entities: [Resolved],
        tracks: [EntityID: ActorPlan]
    ) -> (Vec3, Double) {
        guard let resolved = entities.first(where: { $0.entity.id == id }) else { return (.zero, 0) }
        let placement = resolved.entity.placement
        guard let plan = tracks[id] else { return (placement.position, placement.heading) }
        let pose = plan.pose(at: time, fallbackHeading: placement.heading)
        return (pose.position, pose.heading)
    }

    // MARK: Boarding and attachment (Blockout's passes 2 and 3)

    private func resolveBoardings(_ poses: inout [EntityPose], at time: Double) {
        for boarding in boardings {
            guard let active = boarding.marks.last(where: { time >= $0.time }),
                  let targetID = active.boardID,
                  let rider = entities.firstIndex(where: { $0.entity.id == boarding.entityID }),
                  let target = entities.firstIndex(where: { $0.entity.id == targetID }),
                  let offset = boarding.offsets[active.id]
            else { continue }
            let vehicle = poses[target]
            poses[rider].position = offset.apply(toParent: vehicle.position, heading: vehicle.heading)
            poses[rider].heading = vehicle.heading + offset.rotY
            poses[rider].gait = .stand
            poses[rider].speed = vehicle.speed
            poses[rider].distanceTravelled = vehicle.distanceTravelled
            if !active.joints.isEmpty { poses[rider].joints = active.joints }
        }
    }

    private func resolveAttachments(_ poses: inout [EntityPose], at time: Double) {
        for _ in 0 ..< 4 {
            var changed = false
            for (child, resolved) in entities.enumerated() {
                guard let attachment = resolved.entity.attachment,
                      let parent = entities.firstIndex(where: { $0.entity.id == attachment.parentID })
                else { continue }
                if let first = tracks[resolved.entity.id]?.firstTime, time >= first { continue }
                let local = Offset(
                    x: attachment.offset.x,
                    y: attachment.offset.y,
                    z: attachment.offset.z,
                    rotY: 2 * atan2(attachment.rotation.y, attachment.rotation.w)
                )
                let p = poses[parent]
                let position = local.apply(toParent: p.position, heading: p.heading)
                let heading = p.heading + local.rotY
                let c = poses[child]
                if abs(c.position.x - position.x) > 1e-9 || abs(c.position.y - position.y) > 1e-9
                    || abs(c.position.z - position.z) > 1e-9 || abs(c.heading - heading) > 1e-9 {
                    changed = true
                }
                poses[child].position = position
                poses[child].heading = heading
                poses[child].speed = p.speed
                poses[child].distanceTravelled = p.distanceTravelled
            }
            if !changed { break }
        }
    }

    // MARK: Camera

    private func cameraFrame(at time: Double, poses: [EntityPose]) -> CameraFrame {
        let setup = shot.camera
        let marks = setup.marks
        var position: Vec3, pan: Double, tilt: Double, roll: Double, focal: Double, focus: Double?
        let sorted = camera.sortedMarks(of: marks)
        switch marks.count {
        case 0:
            (position, pan, tilt, roll, focal, focus) = (Vec3(5, 1.6, 5), headingOf(dx: -5, dz: -5), 0, 0, 35, nil)
        case 1:
            let m = marks[0]
            (position, pan, tilt, roll, focal, focus) = (
                m.position,
                m.pan,
                m.tilt,
                m.roll,
                m.focalLength,
                m.focusDistance
            )
        default:
            let s = camera.sample(at: time)
            position = s.position
            if let legIndex = s.leg {
                let leg = camera.legs[legIndex]
                let from = sorted[leg.from], to = sorted[leg.to]
                let u = smoothstep(easedProgress(s.legProgress, easeOut: from.easeOut, easeIn: to.easeIn))
                pan = lerpAngle(from.pan, to.pan, u)
                tilt = lerpAngle(from.tilt, to.tilt, u)
                roll = lerpAngle(from.roll, to.roll, u)
                focal = lerp(from.focalLength, to.focalLength, u)
                focus = (from.focusDistance != nil && to.focusDistance != nil)
                    ? lerp(from.focusDistance ?? 0, to.focusDistance ?? 0, u)
                    : (to.focusDistance ?? from.focusDistance)
            } else {
                let m = sorted[s.atMark ?? 0]
                (pan, tilt, roll, focal, focus) = (m.pan, m.tilt, m.roll, m.focalLength, m.focusDistance)
            }
        }

        if setup.rig == .carMount, let id = setup.mountID,
           let mount = entities.firstIndex(where: { $0.entity.id == id }) {
            let m = poses[mount]
            position = Offset(x: position.x, y: position.y, z: position.z, rotY: 0)
                .apply(toParent: m.position, heading: m.heading)
            pan += m.heading
        }

        let aimed = setup.trackIDs.compactMap { id in entities.firstIndex { $0.entity.id == id } }
        if !aimed.isEmpty {
            let count = Double(aimed.count)
            let mean = aimed.reduce(Vec3.zero) { $0 + poses[$1].position } * (1 / count)
            let height = aimed.map { entities[$0].height }.max() ?? 0
            let dx = mean.x - position.x, dy = mean.y + height * 0.8 - position.y, dz = mean.z - position.z
            let flat = hypot(dx, dz)
            if flat > 1e-4 || abs(dy) > 1e-4 {
                pan = headingOf(dx: dx, dz: dz)
                tilt = atan2(dy, max(flat, 1e-4))
                if focus != nil { focus = max(0.3, (dx * dx + dy * dy + dz * dz).squareRoot()) }
            }
        }

        let noise = setup.rig.noise(seed: setup.seed, t: time, intensity: setup.rigIntensity)
        return CameraFrame.make(
            position: position + noise.position,
            pan: pan + noise.pan,
            tilt: tilt + noise.tilt,
            roll: roll + noise.roll,
            focalLength: focal,
            sensor: setup.sensor,
            aspect: aspect
        ).focused(at: focus)
    }
}

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

    init(
        position: Vec3,
        travelHeading: Double? = nil,
        distance: Double,
        speed: Double,
        leg: Int? = nil,
        atMark: Int? = nil,
        legProgress: Double
    ) {
        self.position = position
        self.travelHeading = travelHeading
        self.distance = distance
        self.speed = speed
        self.leg = leg
        self.atMark = atMark
        self.legProgress = legProgress
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
                    legProgress: u
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

    init(marks unsorted: [ActorMark]) {
        track = TrackPlan(waypoints: unsorted.map(Waypoint.init))
        marks = track.sortedMarks(of: unsorted)
    }

    var firstTime: Double {
        track.waypoints.first?.time ?? 0
    }

    func pose(at time: Double, fallbackHeading: Double) -> EntityPose {
        let r = track.sample(at: time)
        let heading = r.travelHeading
            ?? r.atMark.flatMap { marks[$0].arriveHeading }
            ?? track.lastTravelHeading(at: time)
            ?? fallbackHeading
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
