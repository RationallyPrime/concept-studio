// Translated from Blockout (https://github.com/wassermanproductions/blockout) src/engine/evaluate.ts
// (resolveBoardings, resolveMarriages) at 3f2d0564, Apache-2.0, by Sam Wasserman (wassermanproductions.com). Changes:
// one graph, resolved parents-first with full transforms, instead of four fixed passes. See Resources/NOTICE.

import Foundation

extension Quat {
    /// The inverse of a unit quaternion.
    var inverse: Quat {
        Quat(x: -x, y: -y, z: -z, w: w)
    }

    /// The heading (yaw about +Y) of the direction a body with this orientation faces, nil if it faces straight up or
    /// down.
    var heading: Double? {
        let forward = rotate(Vec3(0, 0, -1))
        guard abs(forward.x) > 1e-9 || abs(forward.z) > 1e-9 else { return nil }
        return headingOf(dx: forward.x, dz: forward.z)
    }
}

enum AttachmentCycles {
    /// Every attachment cycle among `entities`, each as the ids on it in attachment order, found once.
    static func find(in entities: [PrevisEntity]) -> [[EntityID]] {
        var seen: Set<Set<EntityID>> = []
        var found: [[EntityID]] = []
        for entity in entities {
            var chain = [entity.id]
            var current = entity
            while let parent = current.attachment?.parentID, let next = entities.first(where: { $0.id == parent }) {
                if let start = chain.firstIndex(of: parent) {
                    let cycle = Array(chain[start...])
                    if seen.insert(Set(cycle)).inserted { found.append(cycle) }
                    break
                }
                chain.append(parent)
                current = next
            }
        }
        return found
    }
}

/// How a child sits in its parent's frame: where, and turned how, both in the parent's full orientation.
struct Mounting: Sendable {
    var offset: Vec3
    var rotation: Quat
}

/// One boarding mark: from `time` on the rider rides `target`, standing at the offset captured at that moment.
struct BoardingMark: Sendable {
    var id: MarkID
    var time: Double
    var target: Int
    var joints: [Joint: Double]
    var position: Vec3
    var arriveHeading: Double?
}

/// The attachments and boardings of a scene as one graph over its entities. Each entity has at most one parent at a
/// time: its boarded vehicle once a boarding mark is reached, else the parent it is attached to until its own first
/// mark. Entities are resolved parents first, so any chain lands whatever its order in the document.
struct AttachmentGraph: Sendable {
    let attached: [Int: (parent: Int, mounting: Mounting)]
    let firstMark: [Int: Double]
    let boardings: [Int: [BoardingMark]]
    private(set) var captured: [MarkID: Mounting] = [:]

    init(entities: [PrevisEntity], tracks: [EntityID: ActorPlan]) {
        let index = Dictionary(entities.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        var attached: [Int: (parent: Int, mounting: Mounting)] = [:]
        var firstMark: [Int: Double] = [:]
        var boardings: [Int: [BoardingMark]] = [:]
        for (child, entity) in entities.enumerated() {
            if let link = entity.attachment, let parent = index[link.parentID] {
                attached[child] = (parent, Mounting(offset: link.offset, rotation: link.rotation))
            }
            guard let plan = tracks[entity.id] else { continue }
            firstMark[child] = plan.firstTime
            let marks = plan.marks.compactMap { mark -> BoardingMark? in
                guard let target = mark.boardID.flatMap({ index[$0] }) else { return nil }
                return BoardingMark(
                    id: mark.id, time: mark.time, target: target, joints: mark.joints,
                    position: mark.position, arriveHeading: mark.arriveHeading
                )
            }
            if !marks.isEmpty { boardings[child] = marks }
        }
        self.attached = attached
        self.firstMark = firstMark
        self.boardings = boardings
    }

    /// Captures each boarding's offset from the vehicle's resolved pose at the moment of boarding, earliest first.
    /// Boardings at one instant are ordered by dependency: a vehicle that is itself boarding (or carried by something
    /// that is) at that instant is captured before its rider, so the rider is saved against the vehicle's boarded pose
    /// whatever the order of the entities or of the dictionary. Only the relationships in force at that instant count:
    /// an attachment already overridden by its entity's own blocking cannot make a dependency. Ties between
    /// independent boardings fall back to rider index, then the mark's order.
    mutating func capture(basePoses: (Double) -> [EntityPose]) {
        let all = boardings.keys.sorted()
            .flatMap { rider in boardings[rider, default: []].map { (rider: rider, mark: $0) } }
        for time in Set(all.map(\.mark.time)).sorted() {
            var pending = all.filter { $0.mark.time == time }
            while !pending.isEmpty {
                let riders = Set(pending.map(\.rider))
                let ready = pending.firstIndex { entry in
                    carriers(of: entry.mark.target, at: time, pending: pending).isDisjoint(with: riders)
                } ?? 0
                let mark = pending.remove(at: ready).mark
                var poses = basePoses(time)
                resolve(&poses, at: time)
                let parent = poses[mark.target]
                let inverse = parent.frame.inverse
                let facing = mark.arriveHeading ?? parent.heading
                captured[mark.id] = Mounting(
                    offset: inverse.rotate(mark.position - parent.position),
                    rotation: inverse * .yaw(facing)
                )
            }
        }
    }

    /// `entity` and everything that carries it at `time`, transitively. A rider with a boarding still to be captured at
    /// this instant is carried by that boarding's target; any other entity by the edge in force.
    private func carriers(
        of entity: Int, at time: Double, pending: [(rider: Int, mark: BoardingMark)]
    ) -> Set<Int> {
        var found = Set<Int>()
        var frontier = [entity]
        while let next = frontier.popLast() {
            guard found.insert(next).inserted else { continue }
            let boarding = pending.filter { $0.rider == next }
            if boarding.isEmpty {
                if let parent = edge(of: next, at: time)?.parent { frontier.append(parent) }
            } else {
                frontier += boarding.map(\.mark.target)
            }
        }
        return found
    }

    /// The parent edge in force for `child` at `time`: a captured boarding, else a live attachment.
    private func edge(of child: Int, at time: Double) -> (parent: Int, mounting: Mounting, boarding: BoardingMark?)? {
        if let mark = boardings[child]?.last(where: { time >= $0.time && captured[$0.id] != nil }),
           let mounting = captured[mark.id] {
            return (mark.target, mounting, mark)
        }
        if let link = attached[child], time < (firstMark[child] ?? .infinity) {
            return (link.parent, link.mounting, nil)
        }
        return nil
    }

    func resolve(_ poses: inout [EntityPose], at time: Double) {
        var edges: [Int: (parent: Int, mounting: Mounting, boarding: BoardingMark?)] = [:]
        for child in poses.indices {
            if let edge = edge(of: child, at: time) { edges[child] = edge }
        }
        var state = [Int: Bool](minimumCapacity: poses.count) // false: in progress, true: done
        func visit(_ child: Int) {
            guard state[child] == nil else { return }
            state[child] = false
            guard let edge = edges[child] else {
                state[child] = true
                return
            }
            // a cycle among live edges leaves the child where its own marks put it
            if state[edge.parent] == nil { visit(edge.parent) }
            guard state[edge.parent] == true else {
                state[child] = true
                return
            }
            let parent = poses[edge.parent]
            poses[child].position = parent.position + parent.frame.rotate(edge.mounting.offset)
            let orientation = parent.frame * edge.mounting.rotation
            poses[child].orientation = orientation
            poses[child].heading = orientation.heading ?? poses[child].heading
            poses[child].speed = parent.speed
            poses[child].distanceTravelled = parent.distanceTravelled
            if let boarding = edge.boarding {
                poses[child].gait = .stand
                if !boarding.joints.isEmpty { poses[child].joints = boarding.joints }
            }
            state[child] = true
        }
        for child in poses.indices {
            visit(child)
        }
    }
}
