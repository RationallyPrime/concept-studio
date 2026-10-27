import Foundation
import PrevisCore

/// Where `CameraLegs` cuts a shot: at the marks that place the camera and move its subjects, timed as the evaluator
/// times them; and how far camera and subject go between cuts.
extension CameraLegs {
    struct Cuts {
        var stretches: [Span]
        var keyed: [Span]
        var jumps: Set<Int> // the first frames past a jump
        var legs: Set<ClosedRange<Int>> // the camera's own legs, from leaving one mark to reaching the next
    }

    /// The stretches between cuts wherever a mark that moves the camera or its subjects holds: the camera's own, the
    /// car's it rides, and its reference subjects'. `keyed` cuts only where the camera is placed, at its own marks and
    /// its car's. A jump to a mark at the same time is cut on both sides, so it is a one-frame stretch of its own.
    static func cuts(of shot: Shot, in scene: PrevisScene, subjects: [EntityID], last: Int) -> Cuts {
        guard last > 0 else {
            return Cuts(stretches: [Span(from: 0, to: 0)], keyed: [Span(from: 0, to: 0)], jumps: [], legs: [])
        }
        let tracks = scene.blocking.first { $0.id == shot.blockingTakeID }?.tracks ?? []
        let held = { (entity: EntityID) in
            marked(
                tracks.filter { $0.entityID == entity }.flatMap(\.marks).map { ($0.time, $0.hold, $0.position) },
                last: last, inward: true
            )
        }
        let camera = marked(shot.camera.marks.map { ($0.time, $0.hold, $0.position) }, last: last)
        let car = shot.camera.rig == .carMount ? shot.camera.mountID.map(held) : nil
        let placed = Set([0, last] + camera.frames + (car?.frames ?? []))
        let moved = placed.union(subjects.flatMap { held($0).frames })
        let spans = { (frames: Set<Int>) in
            let sorted = frames.sorted()
            return zip(sorted, sorted.dropFirst()).map { Span(from: $0, to: $1) }
        }
        return Cuts(
            stretches: spans(moved), keyed: spans(placed), jumps: Set(camera.jumps + (car?.jumps ?? [])),
            legs: Set(camera.legs)
        )
    }

    /// The frames where a track's marks hold, as the evaluator times its legs (`TrackPlan`, after Blockout
    /// `evaluate.ts:66-68`): each mark's time, and the moment it leaves, its hold cut short a tenth of a second before
    /// the next mark. A jump is a crossing to another place along a leg too short to take a frame; it lies between the
    /// last frame before the leg ends and the first after, which the evaluator puts past it. `inward`, for an
    /// entity's track, rounds each time at a mark toward the frames where it is there, up from its arrival and down
    /// from its departure, so a stretch where it stands holds no frame of its travel; the camera's own round to the
    /// nearest frame.
    static func marked(
        _ marks: [(time: Double, hold: Double, position: Vec3)], last: Int, inward: Bool = false
    ) -> (frames: [Int], jumps: [Int], legs: [ClosedRange<Int>]) {
        let sorted = marks.enumerated().sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }
            .map(\.element)
        let frame = { (time: Double) in min(max(FrameGrid.frame(atTime: max(time, 0)), 0), last) }
        let at = { (time: Double, way: FloatingPointRoundingRule) in
            inward ? min(max(Int((time * Double(FrameGrid.fps)).rounded(way)), 0), last) : frame(time)
        }
        var frames = sorted.first.map { [at($0.time, .up)] } ?? [], jumps: [Int] = [], legs: [ClosedRange<Int>] = []
        for (from, to) in zip(sorted, sorted.dropFirst()) {
            let depart = min(from.time + from.hold, max(from.time, to.time - 0.1))
            frames += [at(depart, .down), at(to.time, .up)]
            if frame(depart) < frame(to.time) {
                legs.append(frame(depart) ... frame(to.time))
            } else if length(difference(to.position, from.position)) >= 0.005 {
                let past = Int((max(to.time, depart + 0.001) * Double(FrameGrid.fps)).rounded(.down)) + 1
                if past > 0, past <= last {
                    frames += [past - 1, past]
                    jumps.append(past)
                }
            }
        }
        return (frames, jumps, legs)
    }

    /// The span each stretch's relative moves are read over (see `direction`): none where the subject stands still,
    /// so each piece is read on its own; where he moves at all, the camera's whole leg or hold around the stretch,
    /// from one place it was put to the next.
    static func references(_ cuts: Cuts, samples: [Sample]) -> [Span?] {
        cuts.stretches.map { stretch in
            guard subjectTravel(stretch, samples: samples) >= standing else { return nil }
            return cuts.keyed.first { $0.from <= stretch.from && stretch.to <= $0.to } ?? stretch
        }
    }

    /// How far the camera goes over a span, leaving out any jump.
    static func pathLength(_ span: Span, samples: [Sample]) -> Double {
        zip(samples[span.from ..< span.to], samples[span.from + 1 ... span.to]).reduce(0) {
            $1.1.jumped ? $0 : $0 + length(difference($1.1.camera.position, $1.0.camera.position))
        }
    }

    /// How far the reference subject itself goes over a span; 0 without one.
    static func subjectTravel(_ span: Span, samples: [Sample]) -> Double {
        zip(samples[span.from ..< span.to], samples[span.from + 1 ... span.to]).reduce(0) { total, step in
            guard let start = step.0.subject, let end = step.1.subject else { return total }
            return total + length(difference(end, start))
        }
    }

    /// Signed actual camera-height change, excluding cut jumps just as path length does.
    static func cameraRise(_ samples: ArraySlice<Sample>) -> Double {
        zip(samples.dropLast(), samples.dropFirst()).reduce(0) { total, step in
            step.1.jumped ? total : total + step.1.camera.position.y - step.0.camera.position.y
        }
    }
}
