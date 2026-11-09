import Foundation
@testable import PrevisCore
import Testing

/// `MotionCorrections`: Blockout's bilateral knee bends write the thighs' forward swing with a positive `hipX`, against
/// its own header. Each fact is measured on the posed rig, with the keyframe's pelvis drop applied.
struct MotionCorrectionTests {
    private let catalog: ContentCatalog
    private let authored: [MotionPreset]

    init() throws {
        catalog = try ContentCatalog.bundled()
        authored = try ContentCatalog.authoredMotions()
    }

    private func body(_ key: MotionKeyframe) throws -> EntityFrame {
        var scene = PrevisScene.make(id: "s", name: "s", takeID: "t", shotID: "h", cameraMarkID: "c")
        scene.entities = [
            PrevisEntity(
                id: "e",
                assetID: "person.man",
                name: "Body",
                placement: Placement(position: .zero, heading: 0, scale: 1)
            ),
        ]
        scene.blocking[0].tracks = [
            Track(entityID: "e", marks: [
                ActorMark(
                    id: "m", time: 0, hold: 0, easeIn: 0, easeOut: 0,
                    position: Vec3(0, key.move?.up ?? 0, 0), gait: .stand, joints: key.joints
                ),
            ]),
        ]
        let evaluator = try ShotEvaluator(scene: scene, shotID: "h", catalog: catalog)
        return try #require(evaluator.frame(0).entities.first)
    }

    private func point(_ name: KeypointName, _ frame: EntityFrame) throws -> Vec3 {
        try #require(frame.keypoints.first { $0.name == name }).position
    }

    /// Mean distance of the two ankles from where a standing man's ankles are.
    private func footGap(_ frame: EntityFrame, standing: Double) throws -> Double {
        let left = try point(.leftAnkle, frame).y, right = try point(.rightAnkle, frame).y
        return (abs(left - standing) + abs(right - standing)) / 2
    }

    private func standingAnkle() throws -> Double {
        try point(.leftAnkle, body(MotionKeyframe(t: 0)))
            .y
    }

    private func keyframe(_ motion: String, _ index: Int, from presets: [MotionPreset]) throws -> MotionKeyframe {
        let preset = try #require(presets.first { $0.id == motion })
        return preset.keyframes[index]
    }

    @Test func theSeatedPoseHasTheKneesAheadAndTheFeetOnTheFloor() throws {
        let seated = try keyframe("sit-down", 2, from: catalog.motions)
        #expect(seated.joints[.hipLX] == -1.4 && seated.joints[.hipRX] == -1.4)
        let man = try body(seated)
        for (knee, hip) in [(KeypointName.leftKnee, KeypointName.leftHip), (.rightKnee, .rightHip)] {
            let reach = try -(point(knee, man).z - point(hip, man).z)
            #expect(reach > 0.3, "\(knee) is \(reach) m ahead of the hip")
        }
        let gap = try footGap(man, standing: standingAnkle())
        let authoredGap = try footGap(body(keyframe("sit-down", 2, from: authored)), standing: standingAnkle())
        #expect(gap < 0.15, "the feet are \(gap) m off the floor")
        #expect(authoredGap > 0.5, "as authored, the feet are \(authoredGap) m off the floor")
    }

    @Test func aSquatKeepsTheFeetOnTheFloor() throws {
        let gap = try footGap(body(keyframe("squat-exercise", 1, from: catalog.motions)), standing: standingAnkle())
        let authoredGap = try footGap(body(keyframe("squat-exercise", 1, from: authored)), standing: standingAnkle())
        #expect(authoredGap > 0.3, "as authored, the feet are \(authoredGap) m off the floor")
        #expect(gap < 0.2, "the feet are \(gap) m off the floor")
    }

    @Test(arguments: ["front-kick", "knee-strike", "high-kick", "takedown-lunge", "kneel-tie-shoe"])
    func oneLegMovesAndSplitStancesAreUnchanged(motion: String) throws {
        let corrected = try #require(catalog.motion(motion))
        let original = try #require(authored.first { $0.id == motion })
        for (index, key) in corrected.keyframes.enumerated() where !MotionCorrections.isBilateralKneeBend(
            original.keyframes[index].joints
        ) {
            #expect(key == original.keyframes[index], "\(motion) keyframe \(index)")
        }
    }

    @Test func theKickWindUpsKeepTheirBackSwing() throws {
        for ref in MotionCorrections.windUps {
            let key = try keyframe(ref.motion, ref.index, from: catalog.motions)
            #expect(try key == keyframe(ref.motion, ref.index, from: authored))
            let man = try body(key)
            let behind = try point(.rightAnkle, man).z - point(.rightHip, man).z
            #expect(behind > 0.1, "\(ref.motion): the kicking foot is \(behind) m behind the hip")
        }
    }

    /// Exactly the bilateral knee bends change, and in them only the two hip swings, which change sign.
    @Test func theCorrectionChangesOnlyTheHipSwingOfBilateralKneeBends() throws {
        var changed = 0
        for original in authored {
            let corrected = try #require(catalog.motion(original.id))
            for (index, before) in original.keyframes.enumerated() {
                let after = corrected.keyframes[index]
                let flipped = MotionCorrections.applies(to: before.joints, motion: original.id, index: index)
                var expected = before
                if flipped {
                    expected.joints[.hipLX] = -(before.joints[.hipLX] ?? 0)
                    expected.joints[.hipRX] = -(before.joints[.hipRX] ?? 0)
                    changed += 1
                }
                #expect(after == expected, "\(original.id) keyframe \(index)")
            }
        }
        #expect(changed == 171)
    }

    /// Every corrected keyframe that keeps the pelvis at or below standing height puts the feet nearer the floor than
    /// the authored value does, or within 8 cm of it where the bend is too slight for the floor to tell.
    @Test func everyGroundedCorrectionBringsTheFeetNearerTheFloor() throws {
        let standing = try standingAnkle()
        for original in authored {
            let corrected = try #require(catalog.motion(original.id))
            for (index, before) in original.keyframes.enumerated() where before != corrected.keyframes[index] {
                guard (before.move?.up ?? 0) <= 0 else { continue }
                let was = try footGap(body(before), standing: standing)
                let now = try footGap(body(corrected.keyframes[index]), standing: standing)
                #expect(
                    now < was || now < 0.08,
                    "\(original.id) keyframe \(index): feet \(now) m off the floor, authored \(was)"
                )
            }
        }
    }
}

extension MotionCorrectionTests {
    /// The two lying motions stay as authored. On this upright rig the floor does not vindicate the flip for them:
    /// in some of their knee bends it lifts the feet farther off the floor, and flipping only the others would swing
    /// the thighs through between keyframes.
    @Test(arguments: MotionCorrections.lyingDown.sorted())
    func lyingMotionsStayAsAuthoredBecauseFlippingLiftsTheFeet(motion: String) throws {
        let original = try #require(authored.first { $0.id == motion })
        #expect(catalog.motion(motion) == original)
        let standing = try standingAnkle()
        let bends = original.keyframes.filter { MotionCorrections.isBilateralKneeBend($0.joints) }
        #expect(!bends.isEmpty)
        let worse = try bends.filter { key in
            var flipped = key
            flipped.joints[.hipLX] = -(key.joints[.hipLX] ?? 0)
            flipped.joints[.hipRX] = -(key.joints[.hipRX] ?? 0)
            return try footGap(body(flipped), standing: standing) > footGap(body(key), standing: standing)
        }
        #expect(!worse.isEmpty, "\(motion): flipping lifts the feet in \(worse.count) of \(bends.count)")
    }
}
