import Foundation

/// Blockout's motion data writes hip swing two ways. Its header (`src/engine/motions.ts` lines 20-21) says a positive
/// `hipLX` or `hipRX` swings the leg back and a negative one raises it forward, and every one-leg raise follows it: a
/// front kick is `hipRX: -1.5`, a knee strike `-1.75`. But every keyframe that bends both knees writes the thighs'
/// forward swing as a *positive* value, nearly always about half the knee bend: a squat is `hip 0.8, knee 1.4`, the
/// seated pose `hip 1.4, knee 1.5`, a boxing guard `hip 0.1, knee 0.3`. Read by the header, as this rig reads every
/// value, those keyframes swing both thighs back and fold the shins up behind, so a seated figure kneels on air with
/// its feet near hip height. Read as forward swing, the feet stay under the body and meet the floor at the authored
/// pelvis drop.
///
/// The correction, by the owner's ruling of 2026-11-09 (recorded in `status/lane-a.md`): in every keyframe where
/// both legs swing back (`hipLX > 0`, `hipRX > 0`) and each knee bends at least as far as its hip swings, both hip
/// values change sign. The exceptions are the two kick wind-ups whose comments say the kicking leg swings back
/// (`windUps`) and the two motions that lie the figure face down (`lyingDown`). Only the bundled catalog is
/// corrected; `motions.v1.json` stays a verbatim extract, and documents imported from Blockout keep the joint values
/// they carry.
enum MotionCorrections {
    struct KeyframeRef: Hashable {
        let motion: String
        let index: Int
    }

    /// "Plant left, swing the right leg back to load the instep kick" and "Plant, wind the kicking leg back".
    static let windUps: Set<KeyframeRef> = [
        KeyframeRef(motion: "soccer-kicks", index: 1),
        KeyframeRef(motion: "soccer-kick", index: 1),
    ]

    /// Torso pitched 1.3 rad or more, pelvis low: this upright rig cannot lay the figure down, and in some of these
    /// keyframes the authored values keep the feet nearer the floor than the flipped ones (`MotionCorrectionTests`), so
    /// the authoring style alone does not decide them. They stay as authored.
    static let lyingDown: Set<String> = ["crawl-fast-military", "trip-and-fall-flat"]

    /// Both thighs written as swinging back while each knee bends at least as far: the authoring style of a
    /// bilateral knee bend.
    static func isBilateralKneeBend(_ joints: [Joint: Double]) -> Bool {
        let hipL = joints[.hipLX] ?? 0, hipR = joints[.hipRX] ?? 0
        return hipL > 0 && hipR > 0 && (joints[.kneeL] ?? 0) >= hipL && (joints[.kneeR] ?? 0) >= hipR
    }

    static func applies(to joints: [Joint: Double], motion: String, index: Int) -> Bool {
        isBilateralKneeBend(joints) && !lyingDown.contains(motion)
            && !windUps.contains(KeyframeRef(motion: motion, index: index))
    }

    static func corrected(_ motion: MotionPreset) -> MotionPreset {
        var motion = motion
        for index in motion.keyframes.indices {
            let joints = motion.keyframes[index].joints
            guard applies(to: joints, motion: motion.id, index: index) else { continue }
            motion.keyframes[index].joints[.hipLX] = -(joints[.hipLX] ?? 0)
            motion.keyframes[index].joints[.hipRX] = -(joints[.hipRX] ?? 0)
        }
        return motion
    }
}
