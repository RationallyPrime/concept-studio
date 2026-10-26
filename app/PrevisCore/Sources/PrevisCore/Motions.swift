// Translated from Blockout (https://github.com/wassermanproductions/blockout) src/engine/sequences.ts
// (appendMotion, choreographMotion) at 3f2d0564, Apache-2.0, by Sam Wasserman (wassermanproductions.com).
// Changes: one play-through at an entity's pose, as a track edit; an overlay that samples a motion at the marks of an
// existing track. See Resources/NOTICE.

import Foundation

public enum Motions {
    /// Lays `motionID` down as marks starting at `time` (seconds), once through, at the pose the entity has then.
    ///
    /// Marks of `track` before `time` are kept and marks at or after it are replaced, so a motion can be dropped into
    /// the
    /// middle of a take. Each keyframe becomes a standing mark with that keyframe's joints; a keyframe's `move` shifts
    /// it
    /// forward along the heading and up. Only people can play a motion. A motion that reads best repeated plays once;
    /// the
    /// caller repeats it by applying it again at the end.
    public static func apply(
        _ motionID: String,
        to entity: PrevisEntity,
        track: Track?,
        at time: Double,
        catalog: ContentCatalog
    ) throws -> Track {
        let motion = try preset(motionID, catalog: catalog)
        guard catalog.asset(entity.assetID)?.rig == .person else {
            throw ShotsError.invalid([
                ShotsProblem(
                    severity: .error,
                    message: "\"\(entity.name)\" is not a person, so it cannot play the motion \"\(motion.name)\"; "
                        + "choose a character.",
                    entityID: entity.id
                ),
            ])
        }
        guard time.isFinite, time >= 0 else {
            throw ShotsError.invalid([
                ShotsProblem(
                    severity: .error,
                    message: "A motion starts at zero seconds or later, not \(time).",
                    entityID: entity.id
                ),
            ])
        }
        let kept = (track?.marks ?? []).filter { $0.time < time - 1e-9 }
        let here = pose(of: entity, track: track, at: time)
        let forward = Vec3(-sin(here.heading), 0, -cos(here.heading))
        let marks = motion.keyframes.map { keyframe in
            let move = keyframe.move ?? RootMove(forward: 0, up: 0)
            return ActorMark(
                id: PrevisIDs.make("mark"),
                time: time + keyframe.t,
                hold: 0,
                easeIn: 0,
                easeOut: 0,
                position: Vec3(
                    here.position.x + forward.x * move.forward,
                    max(0, here.position.y + move.up),
                    here.position.z + forward.z * move.forward
                ),
                gait: .stand,
                joints: keyframe.joints
            )
        }
        return Track(entityID: entity.id, marks: kept + marks)
    }

    /// Walk-and-talk: samples an upper-body motion at the times of `track`'s marks, counted from its first mark, and
    /// sets
    /// those joints on the marks. Positions, timing, gaits and the legs' joints are untouched.
    ///
    /// A motion that loops repeats; one that does not holds its last pose. The sampling is only as fine as the track's
    /// marks, so a track with a mark every half second or so follows a gesture well, and one with two marks only gets
    /// its
    /// two end poses.
    public static func overlay(_ motionID: String, onto track: Track, catalog: ContentCatalog) throws -> Track {
        let motion = try preset(motionID, catalog: catalog)
        guard motion.upperBodyOnly else {
            throw ShotsError.invalid([
                ShotsProblem(
                    severity: .error,
                    message: "The motion \"\(motion.name)\" moves the legs, so it cannot be laid over a walk; "
                        + "choose an upper-body motion such as a wave or a nod.",
                    entityID: track.entityID
                ),
            ])
        }
        guard let start = track.marks.map(\.time).min() else { return track }
        var result = track
        for index in result.marks.indices {
            let local = result.marks[index].time - start
            for (joint, value) in sample(motion, at: local) {
                result.marks[index].joints[joint] = value
            }
        }
        return result
    }

    private static func preset(_ id: String, catalog: ContentCatalog) throws -> MotionPreset {
        guard let motion = catalog.motion(id) else {
            throw ShotsError.unknownContent("The motion \"\(id)\" is not in the catalog; pick one from the list.")
        }
        return motion
    }

    /// Where the entity stands and faces at `time`: on its track if it has marks, else at its placement.
    private static func pose(
        of entity: PrevisEntity,
        track: Track?,
        at time: Double
    ) -> (position: Vec3, heading: Double) {
        let placement = entity.placement
        guard let marks = track?.marks, !marks.isEmpty else { return (placement.position, placement.heading) }
        let state = ActorPlan(marks: marks).pose(at: time, fallbackHeading: placement.heading)
        return (state.position, state.heading)
    }

    /// The motion's joints at `t` seconds: linear between keyframes; a joint a keyframe omits reads as 0.
    static func sample(_ motion: MotionPreset, at t: Double) -> [Joint: Double] {
        let keys = motion.keyframes
        guard let first = keys.first, let last = keys.last else { return [:] }
        var time = t
        if motion.loop, motion.duration > 0 {
            time = t.truncatingRemainder(dividingBy: motion.duration)
            if time < 0 { time += motion.duration }
        }
        if time <= first.t { return first.joints }
        if time >= last.t { return last.joints }
        let upper = keys.firstIndex { $0.t >= time } ?? keys.count - 1
        let a = keys[upper - 1], b = keys[upper]
        let u = b.t > a.t ? (time - a.t) / (b.t - a.t) : 0
        var out: [Joint: Double] = [:]
        for joint in Set(a.joints.keys).union(b.joints.keys) {
            out[joint] = lerp(a.joints[joint] ?? 0, b.joints[joint] ?? 0, u)
        }
        return out
    }
}
