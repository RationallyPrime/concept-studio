// Translated from Blockout (https://github.com/wassermanproductions/blockout) src/engine/evaluate.ts at 3f2d0564,
// Apache-2.0, by Sam Wasserman (wassermanproductions.com). Changes: contract types, immutable plans built once in
// the initialiser, boarding offsets precomputed instead of cached. See Resources/NOTICE.

import Foundation

// CONTRACTS section 5.4. Legs, paths, easing, holds and joint blending; boarding and attachments as Blockout's
// four passes (A5 replaces them with one dependency-ordered graph); the camera with lens, aim lock, mount and rig
// noise. Bodies, keypoints and validation arrive in A3 and A5.

/// Where this evaluator departs from Blockout's. Blockout's behaviour is kept reachable, as `[]`, so the parity
/// tests can prove the port against its oracle; the public initialiser uses `.all`.
struct Corrections: OptionSet, Sendable {
    let rawValue: Int

    /// An authored turn (`arriveHeading`) blends over the hold at its mark, or over the whole leg when the mark has
    /// no hold, instead of snapping when the leg ends (defect 1).
    static let authoredTurns = Corrections(rawValue: 1)
    /// A leg with no horizontal motion keeps its heading instead of facing −Z (defect 2).
    static let verticalHeading = Corrections(rawValue: 2)
    /// One easing for position and orientation: the camera's pan, tilt, roll and lens no longer apply a smoothstep on
    /// top of the position easing (defect 6).
    static let singleEasing = Corrections(rawValue: 4)
    /// Attachments and boardings are one graph, resolved parents first with full transforms, a boarded vehicle's own
    /// attachment included; Blockout runs four fixed passes in a fixed order (defects 3 and 4).
    static let attachmentGraph = Corrections(rawValue: 8)

    static let all: Corrections = [.authoredTurns, .verticalHeading, .singleEasing, .attachmentGraph]
}

public struct ShotEvaluator: Sendable {
    let corrections: Corrections
    let sceneID: SceneID
    let shot: Shot
    let aspect: Double
    let entities: [Resolved]
    let tracks: [EntityID: ActorPlan]
    private let boardings: [Boarding]
    private let graph: AttachmentGraph?
    let camera: TrackPlan

    struct Resolved: Sendable {
        var entity: PrevisEntity
        var asset: AssetSpec
        var height: Double {
            asset.height * entity.placement.scale
        }
    }

    public init(scene: PrevisScene, shotID: ShotID, catalog: ContentCatalog) throws {
        try self.init(scene: scene, shotID: shotID, catalog: catalog, aspect: nil, corrections: .all)
    }

    /// `aspect` replaces the canvas aspect for the field of view: parity tests construct with Blockout's exact
    /// aspect, because the importer maps aspects onto 32-multiple canvases. `corrections` selects which of this
    /// evaluator's departures from Blockout apply; the parity tests pass `[]`.
    init(
        scene: PrevisScene,
        shotID: ShotID,
        catalog: ContentCatalog,
        aspect: Double?,
        corrections: Corrections = .all
    ) throws {
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
        let resolved = try Self.resolve(scene, shot: shot, catalog: catalog, corrections: corrections)
        let plans = Self.plans(scene, shot: shot, resolved: resolved, corrections: corrections)

        self.corrections = corrections
        graph = corrections.contains(.attachmentGraph) ? Self.graph(resolved, plans) : nil
        sceneID = scene.id
        self.shot = shot
        self.aspect = aspect ?? shot.canvas.aspect
        entities = resolved
        tracks = plans
        camera = TrackPlan(waypoints: shot.camera.marks.map(Waypoint.init))
        boardings = Self.boardings(resolved, plans)
    }

    /// Every entity with its asset, or an error naming each unknown asset and each attachment cycle.
    private static func resolve(
        _ scene: PrevisScene,
        shot: Shot,
        catalog: ContentCatalog,
        corrections: Corrections
    ) throws -> [Resolved] {
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
                        shotID: shot.id,
                        entityID: entity.id
                    )
                )
            }
        }
        if !problems.isEmpty { throw ShotsError.invalid(problems) }
        if corrections.contains(.attachmentGraph) {
            let cycles = AttachmentCycles.find(in: scene.entities)
            if !cycles.isEmpty {
                throw ShotsError.invalid(cycles.map { cycle in
                    let names = cycle.map { id in "\"\(scene.entities.first { $0.id == id }?.name ?? id)\"" }
                    return ShotsProblem(
                        severity: .error,
                        message: "\(names.joined(separator: " and ")) are attached to each other in a cycle; "
                            + "detach one of them.",
                        sceneID: scene.id,
                        shotID: shot.id,
                        entityID: cycle[0]
                    )
                })
            }
        }
        return resolved
    }

    private static func plans(
        _ scene: PrevisScene,
        shot: Shot,
        resolved: [Resolved],
        corrections: Corrections
    ) -> [EntityID: ActorPlan] {
        let take = scene.blocking.first { $0.id == shot.blockingTakeID } ?? scene.blocking.first
        var plans: [EntityID: ActorPlan] = [:]
        for track in take?.tracks ?? [] where !track.marks.isEmpty {
            guard let entity = resolved.first(where: { $0.entity.id == track.entityID })?.entity else { continue }
            plans[track.entityID] = ActorPlan(
                marks: track.marks,
                placementHeading: entity.placement.heading,
                corrections: corrections
            )
        }
        return plans
    }

    private static func graph(_ resolved: [Resolved], _ plans: [EntityID: ActorPlan]) -> AttachmentGraph {
        var graph = AttachmentGraph(entities: resolved.map(\.entity), tracks: plans)
        graph.capture { time in
            resolved.map { item in
                let placement = item.entity.placement
                return plans[item.entity.id]?.pose(at: time, fallbackHeading: placement.heading)
                    ?? EntityPose(position: placement.position, heading: placement.heading)
            }
        }
        return graph
    }

    /// Blockout's boardings, each with the offset captured from the vehicle's own track pose at the boarding mark.
    private static func boardings(_ resolved: [Resolved], _ plans: [EntityID: ActorPlan]) -> [Boarding] {
        resolved.compactMap { item -> Boarding? in
            guard let plan = plans[item.entity.id] else { return nil }
            let marks = plan.marks.filter { $0.boardID != nil }
            guard !marks.isEmpty else { return nil }
            let offsets = marks.compactMap { mark -> (MarkID, Offset)? in
                guard let target = mark.boardID else { return nil }
                let (position, heading) = Self.pose(of: target, at: mark.time, entities: resolved, tracks: plans)
                return (mark.id, Boarding.offset(of: mark, from: position, heading: heading))
            }
            return Boarding(
                entityID: item.entity.id,
                marks: marks,
                offsets: Dictionary(offsets, uniquingKeysWith: { first, _ in first })
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

    /// Things the shot allows but the user should look at: a leg faster or slower than its gait, the camera crossing
    /// the
    /// line between two people, a frame count outside the trained range, marks past the end of the shot, and the two
    /// Blockout behaviours that are kept (marks at the same time teleport; a pan turns the short way round).
    public func warnings() -> [ShotsProblem] {
        computeWarnings()
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
        if let graph {
            graph.resolve(&poses, at: time)
        } else {
            resolveBoardings(&poses, at: time)
            resolveAttachments(&poses, at: time)
        }
        for index in poses.indices {
            poses[index].time = time
        }
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

    // MARK: Blockout's boarding and attachment passes (used when `.attachmentGraph` is off)

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
                let eased = easedProgress(s.legProgress, easeOut: from.easeOut, easeIn: to.easeIn)
                // Blockout eases orientation and lens twice, once as position and again with a smoothstep.
                let u = corrections.contains(.singleEasing) ? eased : smoothstep(eased)
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
