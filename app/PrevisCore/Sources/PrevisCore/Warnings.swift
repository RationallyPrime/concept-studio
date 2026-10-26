// Translated from Blockout (https://github.com/wassermanproductions/blockout) src/engine/gaits.ts (checkSpeed) and
// src/engine/evaluate.ts (warnings, lineCrossings) at 3f2d0564, Apache-2.0, by Sam Wasserman
// (wassermanproductions.com). Changes: plain-sentence problems on the contract's `ShotsProblem`; the trained range,
// marks
// past the end and the two kept Blockout behaviours are new. See Resources/NOTICE.

import Foundation

extension Gait {
    /// Plausible speeds in m/s for a human-scale actor, and whether the gait travels.
    var speedRange: (min: Double, max: Double, travels: Bool) {
        switch self {
        case .stand, .sit, .lie, .gesture, .fall: (0, 0, false)
        case .walk: (0.4, 2.2, true)
        case .jog: (2, 4, true)
        case .run: (3.5, 9, true)
        case .crouch: (0, 1, true)
        }
    }
}

extension ShotEvaluator {
    func computeWarnings() -> [ShotsProblem] {
        speedWarnings() + lineWarnings() + rangeWarnings() + pastTheEndWarnings() + keptBehaviourWarnings()
    }

    private func problem(_ message: String, entity: EntityID? = nil, mark: MarkID? = nil) -> ShotsProblem {
        ShotsProblem(
            severity: .warning,
            message: message,
            sceneID: sceneID,
            shotID: shot.id,
            entityID: entity,
            markID: mark
        )
    }

    private func label(_ resolved: Resolved) -> String {
        let name = resolved.entity.label?.text ?? ""
        return "\"\(name.isEmpty ? resolved.entity.name : name)\""
    }

    // MARK: Speed

    private func speedWarnings() -> [ShotsProblem] {
        var out: [ShotsProblem] = []
        for resolved in entities {
            guard let plan = tracks[resolved.entity.id] else { continue }
            for leg in plan.track.legs {
                let duration = leg.arrive - leg.depart
                guard duration > 0, leg.path.length >= 0.05 else { continue }
                let to = plan.marks[leg.to]
                let speed = leg.path.length / duration
                let range = to.gait.speedRange
                let scale = resolved.asset.speedScale
                let text = String(format: "%.1f", speed)
                let mark = to.id
                if !range.travels {
                    guard speed > 0.01 else { continue }
                    out.append(problem(
                        "\(label(resolved)) is told to \(to.gait.rawValue) but moves \(text) m/s; "
                            + "give that leg a travelling gait such as walk.",
                        entity: resolved.entity.id,
                        mark: mark
                    ))
                } else if speed > range.max * scale * 1.05 {
                    let faster = to.gait == .walk ? "jog" : to.gait == .jog ? "run" : nil
                    let fix = faster.map { "use \($0) or give the leg more time" } ?? "give the leg more time"
                    out.append(problem(
                        "\(label(resolved)) travels \(text) m/s as a \(to.gait.rawValue), faster than about "
                            + "\(String(format: "%.1f", range.max * scale)) m/s; \(fix).",
                        entity: resolved.entity.id,
                        mark: mark
                    ))
                } else if range.min > 0, speed < range.min * scale * 0.5, speed > 0.01 {
                    let slower = to.gait == .run ? "jog" : to.gait == .jog ? "walk" : nil
                    let fix = slower.map { "use \($0) or shorten the leg's time" } ?? "shorten the leg's time"
                    out.append(problem(
                        "\(label(resolved)) travels only \(text) m/s as a \(to.gait.rawValue), well below "
                            + "\(String(format: "%.1f", range.min * scale)) m/s; \(fix).",
                        entity: resolved.entity.id,
                        mark: mark
                    ))
                }
            }
        }
        return out
    }

    // MARK: The 180° rule

    /// Consecutive camera marks on opposite sides of the line between the first two people flip screen direction.
    private func lineWarnings() -> [ShotsProblem] {
        let people = entities.filter { $0.asset.rig == .person }
        guard people.count >= 2, shot.camera.marks.count >= 2 else { return [] }
        let (a, b) = (people[0], people[1])
        let marks = shot.camera.marks.enumerated()
            .sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }.map(\.element)

        func side(of mark: CameraMark) -> Double {
            let frame = frame(at: mark.time)
            guard let pa = frame.entities.first(where: { $0.id == a.entity.id })?.position,
                  let pb = frame.entities.first(where: { $0.id == b.entity.id })?.position
            else { return 0 }
            let axisX = pb.x - pa.x, axisZ = pb.z - pa.z
            if axisX * axisX + axisZ * axisZ < 0.01 { return 0 }
            let cross = axisX * (mark.position.z - pa.z) - axisZ * (mark.position.x - pa.x)
            return abs(cross) < 0.2 ? 0 : (cross > 0 ? 1 : -1)
        }

        var out: [ShotsProblem] = []
        var previous: (side: Double, index: Int)?
        for (index, mark) in marks.enumerated() {
            let current = side(of: mark)
            guard current != 0 else { continue }
            if let previous, previous.side != current {
                out.append(problem(
                    "The camera crosses the line between \(label(a)) and \(label(b)), between marks "
                        + "\(previous.index + 1) and \(index + 1), which flips screen direction; "
                        + "keep the camera on one side or cut on purpose.",
                    mark: mark.id
                ))
            }
            previous = (current, index)
        }
        return out
    }

    // MARK: Range and the end of the shot

    private func rangeWarnings() -> [ShotsProblem] {
        guard !FrameGrid.trainedRange.contains(shot.frameCount) else { return [] }
        let range = FrameGrid.trainedRange
        return [problem(
            "This shot is \(shot.frameCount) frames; the video model is trained on \(range.lowerBound) to "
                + "\(range.upperBound), so results outside that range are less reliable."
        )]
    }

    private func pastTheEndWarnings() -> [ShotsProblem] {
        let end = shot.duration
        var out: [ShotsProblem] = []
        for resolved in entities {
            for mark in tracks[resolved.entity.id]?.marks ?? [] where mark.time > end + 1e-9 {
                out.append(problem(
                    "A mark of \(label(resolved)) is at \(String(format: "%.2f", mark.time)) s, after the shot ends at "
                        + "\(String(format: "%.2f", end)) s; move it earlier or lengthen the shot.",
                    entity: resolved.entity.id,
                    mark: mark.id
                ))
            }
        }
        for mark in shot.camera.marks where mark.time > end + 1e-9 {
            out.append(problem(
                "A camera mark is at \(String(format: "%.2f", mark.time)) s, after the shot ends at "
                    + "\(String(format: "%.2f", end)) s; move it earlier or lengthen the shot.",
                mark: mark.id
            ))
        }
        return out
    }

    // MARK: Blockout behaviours that are kept

    private func keptBehaviourWarnings() -> [ShotsProblem] {
        var out: [ShotsProblem] = []
        func coincident(_ times: [(MarkID, Double)], subject: String, entity: EntityID?) {
            for (earlier, later) in zip(times, times.dropFirst()) where later.1 - earlier.1 < 0.001 {
                out.append(problem(
                    "Two marks of \(subject) are at the same time, so it jumps between them instead of travelling; "
                        + "separate their times.",
                    entity: entity,
                    mark: later.0
                ))
            }
        }
        for resolved in entities {
            guard let plan = tracks[resolved.entity.id] else { continue }
            coincident(
                plan.track.waypoints.map { ($0.id, $0.time) },
                subject: label(resolved),
                entity: resolved.entity.id
            )
        }
        coincident(camera.waypoints.map { ($0.id, $0.time) }, subject: "the camera", entity: nil)

        let sorted = camera.sortedMarks(of: shot.camera.marks)
        for (from, to) in zip(sorted, sorted.dropFirst()) where abs(to.pan - from.pan) > .pi {
            out.append(problem(
                "The camera pan turns by more than half a circle between two marks, and always takes the short way "
                    + "round; add a mark halfway to pan the long way.",
                mark: to.id
            ))
        }
        return out
    }
}
