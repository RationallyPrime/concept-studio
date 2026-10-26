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

    /// Captures each boarding's offset from the vehicle's resolved pose at the moment of boarding, earliest first, so a
    /// vehicle that is itself attached or boarded is resolved before its rider is placed.
    mutating func capture(basePoses: (Double) -> [EntityPose]) {
        let all = boardings.flatMap { rider, marks in marks.map { (rider: rider, mark: $0) } }
            .enumerated().sorted { ($0.element.mark.time, $0.offset) < ($1.element.mark.time, $1.offset) }
            .map(\.element)
        for (_, mark) in all {
            var poses = basePoses(mark.time)
            resolve(&poses, at: mark.time)
            let parent = poses[mark.target]
            let inverse = parent.frame.inverse
            let facing = mark.arriveHeading ?? parent.heading
            captured[mark.id] = Mounting(
                offset: inverse.rotate(mark.position - parent.position),
                rotation: inverse * .yaw(facing)
            )
        }
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
