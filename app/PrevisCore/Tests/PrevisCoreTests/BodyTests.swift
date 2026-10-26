import Foundation
@testable import PrevisCore
import Testing

/// Numeric behaviour of posed bodies. Each test states a real-world fact; the pose comes from a motion's peak
/// keyframe joints held on a mark.
struct BodyTests {
    private let catalog: ContentCatalog

    init() throws {
        catalog = try ContentCatalog.bundled()
    }

    private func body(
        _ assetID: String = "person.man",
        scale: Double = 1,
        gait: Gait = .stand,
        joints: [Joint: Double] = [:]
    ) throws -> EntityFrame {
        var scene = PrevisScene.make(id: "s", name: "s", takeID: "t", shotID: "h", cameraMarkID: "c")
        scene.entities = [
            PrevisEntity(
                id: "e",
                assetID: assetID,
                name: "Body",
                placement: Placement(position: .zero, heading: 0, scale: scale)
            ),
        ]
        scene.blocking[0].tracks = [
            Track(
                entityID: "e",
                marks: [
                    ActorMark(
                        id: "m", time: 0, hold: 0, easeIn: 0, easeOut: 0,
                        position: .zero, gait: gait, joints: joints
                    ),
                ]
            ),
        ]
        let evaluator = try ShotEvaluator(scene: scene, shotID: "h", catalog: catalog)
        return try #require(evaluator.frame(0).entities.first)
    }

    private func keypoint(_ name: KeypointName, in frame: EntityFrame) throws -> Vec3 {
        try #require(frame.keypoints.first { $0.name == name }, "no \(name)").position
    }

    /// Joints of `motion` at the keyframe nearest `time`.
    private func joints(of motion: String, at time: Double) throws -> [Joint: Double] {
        let preset = try #require(catalog.motion(motion))
        let key = try #require(preset.keyframes.min { abs($0.t - time) < abs($1.t - time) })
        return key.joints
    }

    /// Distance ahead of `origin` along the facing direction (heading 0 faces −Z).
    private func ahead(_ point: Vec3, of origin: Vec3) -> Double {
        -(point.z - origin.z)
    }

    @Test(arguments: [1.0, 1.2])
    func aStandingManStandsOnTheGroundAtTheCatalogHeight(scale: Double) throws {
        let man = try body(scale: scale)
        #expect(abs(man.bounds.min.y) < 0.02, "feet at y = \(man.bounds.min.y)")
        #expect(abs(man.bounds.max.y - 1.78 * scale) < 0.02, "head top at y = \(man.bounds.max.y)")
    }

    @Test func aJabPutsThePunchingWristAheadOfTheChest() throws {
        let man = try body(joints: joints(of: "jab-cross", at: 0.3))
        let reach = try ahead(keypoint(.rightWrist, in: man), of: keypoint(.neck, in: man))
        #expect(reach > 0.3, "wrist is \(reach) m ahead of the chest")
    }

    @Test func sittingPutsTheKneesAheadOfTheHips() throws {
        let man = try body(gait: .sit)
        for (knee, hip) in [(KeypointName.leftKnee, KeypointName.leftHip), (.rightKnee, .rightHip)] {
            let reach = try ahead(keypoint(knee, in: man), of: keypoint(hip, in: man))
            #expect(reach > 0.2, "\(knee) is \(reach) m ahead of the hip")
        }
    }

    @Test func atTheTopOfAWaveTheHandIsAboveTheHead() throws {
        let man = try body(joints: joints(of: "wave", at: 0.55))
        let hand = try keypoint(.rightWrist, in: man).y
        let head = try max(keypoint(.leftEar, in: man).y, keypoint(.rightEar, in: man).y)
        #expect(hand > head, "hand at y = \(hand), head at y = \(head)")
    }

    @Test func atTheExtensionOfAFrontKickTheAnkleIsAheadOfTheHips() throws {
        let man = try body(joints: joints(of: "front-kick", at: 0.55))
        let reach = try ahead(keypoint(.rightAnkle, in: man), of: keypoint(.rightHip, in: man))
        #expect(reach > 0.3, "ankle is \(reach) m ahead of the hip")
    }

    /// A positive `shoulderLZ`, `shoulderRZ`, `hipLZ` or `hipRZ` abducts the limb outward, away from the midline, on
    /// both
    /// sides (plan maintainer's disposition, PR 65). Blockout's table moves them the other way; see the convention
    /// paragraph in LANE-A-CORE.md.
    @Test func zOverridesMoveLimbsOutwardOnBothSides() throws {
        let man = try body(joints: [.shoulderLZ: 0.5, .shoulderRZ: 0.5, .hipLZ: 0.5, .hipRZ: 0.5])
        let left = try keypoint(.leftWrist, in: man).x - keypoint(.leftShoulder, in: man).x
        let right = try keypoint(.rightWrist, in: man).x - keypoint(.rightShoulder, in: man).x
        let leftLeg = try keypoint(.leftAnkle, in: man).x - keypoint(.leftHip, in: man).x
        let rightLeg = try keypoint(.rightAnkle, in: man).x - keypoint(.rightHip, in: man).x
        #expect(left < -0.05 && right > 0.05 && leftLeg < -0.05 && rightLeg > 0.05)
    }

    @Test func atJumpingJacksOpenTheAnklesAndWristsAreOutsideTheHipsAndShoulders() throws {
        let man = try body(joints: joints(of: "jumping-jacks", at: 0.5))
        for (outer, inner, side) in [
            (KeypointName.leftAnkle, KeypointName.leftHip, -1.0),
            (.rightAnkle, .rightHip, 1.0),
            (.leftWrist, .leftShoulder, -1.0),
            (.rightWrist, .rightShoulder, 1.0),
        ] {
            let out = try (keypoint(outer, in: man).x - keypoint(inner, in: man).x) * side
            #expect(out > 0.1, "\(outer) is \(out) m outside \(inner)")
        }
    }

    @Test func atTheExtensionOfASideKickTheKickingAnkleIsOutsideItsHip() throws {
        let man = try body(joints: joints(of: "side-kick", at: 0.6))
        let out = try keypoint(.rightAnkle, in: man).x - keypoint(.rightHip, in: man).x
        #expect(out > 0.4, "ankle is \(out) m outside the hip")
    }

    @Test func keypointsFollowCocoOrderWithTheCharactersRightOnPlusX() throws {
        let man = try body()
        #expect(man.keypoints.map(\.name) == KeypointName.allCases)
        #expect(try keypoint(.rightShoulder, in: man).x > keypoint(.leftShoulder, in: man).x)
        #expect(try keypoint(.rightHip, in: man).x > keypoint(.leftHip, in: man).x)
        #expect(try ahead(keypoint(.nose, in: man), of: keypoint(.neck, in: man)) > 0)
        #expect(try keypoint(.neck, in: man).y > keypoint(.rightShoulder, in: man).y)
    }

    @Test func aBodyKeepsItsPartIDsAndShapesAcrossFrames() throws {
        let scene = try #require(ShotsSamples.twoPersonWalk(small: true).scenes.first)
        let evaluator = try ShotEvaluator(scene: scene, shotID: #require(scene.shots.first?.id), catalog: catalog)
        let first = try #require(evaluator.frame(0).entities.first)
        let later = try #require(evaluator.frame(15).entities.first)
        #expect(first.parts.map(\.id) == later.parts.map(\.id))
        #expect(first.parts.map(\.shape) == later.parts.map(\.shape))
        #expect(first.parts.map(\.transform) != later.parts.map(\.transform))
        #expect(Set(first.parts.map(\.id)).count == first.parts.count)
    }

    @Test func quadrupedsStandOnTheGroundAndFaceForward() throws {
        for id in ["animal.dog", "animal.cat", "animal.horse"] {
            let animal = try body(id)
            let height = try #require(catalog.asset(id)).height
            #expect(abs(animal.bounds.min.y) < 0.05 * height + 0.01, "\(id) feet at \(animal.bounds.min.y)")
            #expect(animal.bounds.max.y > height * 0.9 && animal.bounds.max.y < height * 1.6)
            let head = try #require(animal.parts.first { $0.id == "head" }).transform.m
            let tail = try #require(animal.parts.first { $0.id == "tail" }).transform.m
            #expect(head[14] < tail[14], "\(id): the head is forward (−Z) of the tail")
            #expect(animal.keypoints.isEmpty && animal.isActor)
        }
    }

    /// PR 65 r4377007303: the gait phase is `distance / (stride · scale)`. A walking animal at scale 2 that has covered
    /// 0.725 m is a quarter of the way through its 2.9 m scaled stride (phase 0.25, legs at full swing); unscaled it
    /// would be half way (phase 0.5, legs neutral). A scale-2 animal must therefore pose exactly like a scale-1 animal
    /// at half the distance, with every part twice as big.
    @Test(arguments: ["animal.dog", "animal.cat", "animal.horse"])
    func aScaledQuadrupedCyclesItsLegsAtTheScaledStride(id: String) throws {
        let asset = try #require(catalog.asset(id))
        func pose(scale: Double, distance: Double) -> EntityFrame {
            let entity = PrevisEntity(
                id: "e",
                assetID: id,
                name: "Animal",
                placement: Placement(position: .zero, heading: 0, scale: scale)
            )
            let state = EntityPose(position: .zero, heading: 0, gait: .walk, speed: 1, distanceTravelled: distance)
            return EntityFrame.posed(entity, asset: asset, state: state)
        }
        let scaled = pose(scale: 2, distance: 0.725)
        let unscaledQuarterCycle = pose(scale: 1, distance: 0.3625)
        let unscaledHalfCycle = pose(scale: 1, distance: 0.725)

        for leg in ["legFrontLeft", "legBackRight"] {
            let big = try #require(scaled.parts.first { $0.id == leg }).transform.m
            let small = try #require(unscaledQuarterCycle.parts.first { $0.id == leg }).transform.m
            let neutral = try #require(unscaledHalfCycle.parts.first { $0.id == leg }).transform.m
            #expect(zip(big.prefix(15), small.prefix(15)).allSatisfy { abs($0 - 2 * $1) < 1e-9 }, "\(leg) pose")
            // full swing differs visibly from the neutral pose the unscaled stride would give
            #expect(zip(big.prefix(15), neutral.prefix(15)).contains { abs($0 - 2 * $1) > 1e-3 }, "\(leg) not neutral")
        }
    }

    @Test func staticAssetsUseTheirPartsAndOthersAGreyBox() throws {
        let chair = try body("furniture.chair")
        #expect(chair.parts.count > 1 && chair.bounds.min.y > -0.01 && chair.bounds.max.y < 1.2)
        #expect(!chair.isActor && chair.keypoints.isEmpty)
        let stairs = try body("prim.stairs", scale: 2)
        #expect(abs(stairs.bounds.max.y - 2 * 2) < 0.01, "stairs rise 2 m at scale 1")
        let bird = try body("animal.bird")
        #expect(bird.parts.count == 1 && bird.parts.first?.id == "body")
    }
}
