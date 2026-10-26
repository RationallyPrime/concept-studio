// Translated from Blockout (https://github.com/wassermanproductions/blockout) src/renderer/viewport/builders.ts
// (buildPerson, animatePerson) at 3f2d0564, Apache-2.0, by Sam Wasserman (wassermanproductions.com). Changes: pure
// function of the evaluated pose, no scene graph; the rig is scaled to the catalog height (Blockout's overshoots it by
// 0.14 m); COCO-18 keypoints added. See Resources/NOTICE.

import Foundation

/// The posed capsule mannequin. Pivots are nodes with Euler XYZ rotations; forward is −Z; the character's right
/// side is +X.
enum PersonRig {
    /// Blockout's standing figure is 0.14·s taller than its catalog height (s = H / 1.78): the neck and head add
    /// 0.06·s above the head sphere's base, and the pelvis and torso pivots add 0.08·s. This scales H so the
    /// standing head top lands on the catalog height.
    private static let heightFit = 1 / (1 + 0.14 / 1.78)

    // The sign mapping. Blockout's motion data and gait constants describe arm, leg, torso and head X rotations the
    // way its header says (negative raises an arm or swings a leg forward, positive leans the torso forward and bends
    // an elbow), but its geometry turns the other way: a negative shoulder X sends the arm backward, and its seated
    // figure sits thighs-back. This rig keeps one convention, in `Angles`: a positive X on a shoulder, elbow or hip
    // swings the limb forward (toward −Z), a negative X on the torso or head pitches it forward, and a negative X on
    // a knee bends it. The data's signs are mapped to that in `angles(...)` only; nothing else flips a sign. The
    // Y and Z overrides keep the signs of Blockout's table (LANE-A-CORE.md), which BodyTests does not exercise.

    /// Rig angles in radians and metres, in the convention above.
    struct Angles {
        var rootX = 0.0, rootY = 0.0, rootZ = 0.0
        var torso = Vec3.zero, head = Vec3.zero
        var shoulderL = Vec3.zero, shoulderR = Vec3.zero
        var elbowL = Vec3.zero, elbowR = Vec3.zero
        var hipL = Vec3.zero, hipR = Vec3.zero
        var kneeL = 0.0, kneeR = 0.0
    }

    /// Proportions for a figure of the catalog height, at entity scale 1.
    struct Proportions {
        let s: Double, legLen: Double, headR: Double, torsoLen: Double, bodyW: Double
        let armR: Double, upperArm: Double, lowerArm: Double
        let legR: Double, upperLeg: Double, lowerLeg: Double

        init(catalogHeight: Double) {
            let h = catalogHeight * PersonRig.heightFit
            s = h / 1.78
            legLen = h * 0.47
            headR = h * 0.13 * 0.5
            torsoLen = h - legLen - headR * 2
            bodyW = 0.34 * s
            armR = 0.055 * s
            upperArm = torsoLen * 0.5
            lowerArm = torsoLen * 0.48
            legR = 0.075 * s
            upperLeg = legLen * 0.52
            lowerLeg = legLen * 0.48
        }
    }

    static func strideLength(of gait: Gait) -> Double {
        switch gait {
        case .walk: 1.45
        case .jog: 2.0
        case .run: 3.6
        case .crouch: 0.9
        case .stand, .sit, .lie, .gesture, .fall: 0
        }
    }

    /// The gait cycle fraction, 0 ..< 1: `distanceTravelled / (stride · max(scale, 0.2))`.
    static func phase(gait: Gait, distance: Double, scale: Double) -> Double {
        let stride = strideLength(of: gait)
        guard stride > 0 else { return 0 }
        let cycles = distance / (stride * max(scale, 0.2))
        return cycles - cycles.rounded(.down)
    }

    /// The gait pose, then the joint overrides on top.
    static func angles(
        gait: Gait,
        phase p: Double,
        time t: Double,
        speed: Double,
        proportions q: Proportions,
        baseLean: Double,
        joints: [Joint: Double]
    ) -> Angles {
        var a = Angles()
        let swing = sin(p * 2 * .pi)
        a.torso.x = -baseLean
        switch gait {
        case .stand, .gesture:
            a.rootY = sin(t * 1.5) * 0.005
            if gait == .gesture {
                a.shoulderR.x = 2.3
                a.elbowR.z = sin(t * 2) * 0.3
                a.elbowR.x = 0.4
            }
        case .walk, .jog, .run:
            let amp = gait == .walk ? 0.5 : gait == .jog ? 0.8 : 1.1
            let bob = gait == .walk ? 0.02 : gait == .jog ? 0.04 : 0.06
            let leg = swing * amp
            a.hipL.x = leg
            a.hipR.x = -leg
            a.shoulderL.x = -leg * 0.8
            a.shoulderR.x = leg * 0.8
            a.kneeL = -max(0, -sin(p * 2 * .pi)) * 0.8
            a.kneeR = -max(0, -sin(p * 2 * .pi + .pi)) * 0.8
            a.elbowL.x = 0.3
            a.elbowR.x = 0.3
            a.rootY = abs(swing) * bob
            if gait == .run { a.torso.x = -(baseLean + 0.15) }
        case .crouch:
            a.rootY = -q.legLen * 0.3
            a.hipL.x = 0.9
            a.hipR.x = 0.9
            a.kneeL = -1.4
            a.kneeR = -1.4
            a.torso.x = -(baseLean + 0.3)
            if speed > 0 {
                a.hipL.x += swing * 0.25
                a.hipR.x -= swing * 0.25
            }
        case .sit:
            a.rootY = -(q.legLen - 0.45 * q.s)
            a.hipL.x = .pi / 2
            a.hipR.x = .pi / 2
            a.kneeL = -.pi / 2
            a.kneeR = -.pi / 2
        case .lie:
            a.rootX = -.pi / 2
            a.rootY = 0.18 * q.s
            a.rootZ = q.legLen * 0.5
        case .fall:
            a.rootX = 1.4
            a.rootY = 0.25 * q.s
            a.rootZ = -q.legLen * 0.3
            a.shoulderL.x = 2.2
            a.shoulderR.x = 2.2
            a.hipL.x = 0.3
            a.hipR.x = -0.2
        }
        func joint(_ j: Joint) -> Double {
            joints[j] ?? 0
        }
        a.shoulderL.x -= joint(.shoulderLX)
        a.shoulderR.x -= joint(.shoulderRX)
        a.shoulderL.z += joint(.shoulderLZ)
        a.shoulderR.z -= joint(.shoulderRZ)
        a.elbowL.x += joint(.elbowL)
        a.elbowR.x += joint(.elbowR)
        a.hipL.x -= joint(.hipLX)
        a.hipR.x -= joint(.hipRX)
        a.hipL.z += joint(.hipLZ)
        a.hipR.z -= joint(.hipRZ)
        a.kneeL -= joint(.kneeL)
        a.kneeR -= joint(.kneeR)
        a.torso.x -= joint(.torsoX)
        a.torso.y += joint(.torsoY)
        a.torso.z -= joint(.torsoZ)
        a.head.x -= joint(.headX)
        a.head.y += joint(.headY)
        a.head.z -= joint(.headZ)
        return a
    }

    /// Adds the parts and returns the 18 keypoints in COCO order, in world space.
    static func build(
        asset: AssetSpec,
        scale: Double,
        state: EntityPose,
        into builder: inout BodyBuilder
    ) -> [Keypoint] {
        let q = Proportions(catalogHeight: asset.height)
        let a = angles(
            gait: state.gait,
            phase: phase(gait: state.gait, distance: state.distanceTravelled, scale: scale),
            time: state.time,
            speed: state.speed,
            proportions: q,
            baseLean: asset.id == "person.elderly" ? 0.18 : 0,
            joints: state.joints
        )

        let root = Mat4.node(Vec3(0, a.rootY, a.rootZ), Vec3(a.rootX, 0, 0))
        let pelvis = root * .translation(Vec3(0, q.legLen, 0))
        builder.add(
            "pelvis",
            .box(size: Vec3(q.bodyW, 0.18 * q.s, 0.2 * q.s)),
            at: pelvis * .translation(Vec3(0, 0.02 * q.s, 0)),
            color: 0x83838B
        )
        let torso = pelvis * .node(Vec3(0, 0.08 * q.s, 0), a.torso)
        builder.add(
            "torso",
            .capsule(radius: q.bodyW * 0.5, length: q.torsoLen * 0.7),
            at: torso * .translation(Vec3(0, q.torsoLen * 0.5, 0)),
            color: 0x8F8F97
        )
        let head = torso * .node(Vec3(0, q.torsoLen, 0), a.head)
        builder.add(
            "neck",
            .cylinder(radius: 0.05 * q.s, height: 0.08 * q.s),
            at: head * .translation(Vec3(0, 0.04 * q.s, 0)),
            color: 0x83838B
        )
        let headCentre = Vec3(0, q.headR + 0.06 * q.s, 0)
        builder.add("head", .sphere(radius: q.headR), at: head * .translation(headCentre), color: 0x94949C)

        var points: [KeypointName: Vec3] = [:]
        let shoulderY = q.torsoLen * 0.92
        let leftShoulder = torso * .node(Vec3(-q.bodyW * 0.55, shoulderY, 0), a.shoulderL)
        let rightShoulder = torso * .node(Vec3(q.bodyW * 0.55, shoulderY, 0), a.shoulderR)
        addArm(
            "L",
            shoulder: leftShoulder,
            elbow: a.elbowL,
            q,
            &builder,
            &points,
            [.leftShoulder, .leftElbow, .leftWrist]
        )
        addArm(
            "R",
            shoulder: rightShoulder,
            elbow: a.elbowR,
            q,
            &builder,
            &points,
            [.rightShoulder, .rightElbow, .rightWrist]
        )
        let leftHip = pelvis * .node(Vec3(-q.bodyW * 0.28, 0, 0), a.hipL)
        let rightHip = pelvis * .node(Vec3(q.bodyW * 0.28, 0, 0), a.hipR)
        addLeg("L", hip: leftHip, knee: a.kneeL, q, &builder, &points, [.leftHip, .leftKnee, .leftAnkle])
        addLeg("R", hip: rightHip, knee: a.kneeR, q, &builder, &points, [.rightHip, .rightKnee, .rightAnkle])

        // Neck at the torso top; the face on the head sphere: nose forward (−Z), eyes and ears to either side.
        points[.neck] = builder.worldPoint(torso.transform(Vec3(0, q.torsoLen, 0)))
        func onHead(_ direction: Vec3) -> Vec3 {
            builder.worldPoint(head.transform(headCentre + direction.normalized * q.headR))
        }
        points[.nose] = onHead(Vec3(0, -0.1, -1))
        points[.rightEye] = onHead(Vec3(0.35, 0.2, -0.9))
        points[.leftEye] = onHead(Vec3(-0.35, 0.2, -0.9))
        points[.rightEar] = onHead(Vec3(1, 0, 0.1))
        points[.leftEar] = onHead(Vec3(-1, 0, 0.1))
        return KeypointName.allCases.compactMap { name in points[name].map { Keypoint(name: name, position: $0) } }
    }

    /// Upper arm, elbow and forearm. `keys` are the shoulder, elbow and wrist keypoints.
    private static func addArm(
        _ side: String,
        shoulder: Mat4,
        elbow angles: Vec3,
        _ q: Proportions,
        _ builder: inout BodyBuilder,
        _ points: inout [KeypointName: Vec3],
        _ keys: [KeypointName]
    ) {
        builder.add(
            "upperArm\(side)",
            .capsule(radius: q.armR, length: q.upperArm * 0.7),
            at: shoulder * .translation(Vec3(0, -q.upperArm * 0.5, 0)),
            color: 0x88888F
        )
        let elbow = shoulder * .node(Vec3(0, -q.upperArm, 0), angles)
        builder.add(
            "lowerArm\(side)",
            .capsule(radius: q.armR * 0.9, length: q.lowerArm * 0.7),
            at: elbow * .translation(Vec3(0, -q.lowerArm * 0.5, 0)),
            color: 0x8C8C94
        )
        points[keys[0]] = builder.worldPoint(shoulder.transform(.zero))
        points[keys[1]] = builder.worldPoint(elbow.transform(.zero))
        points[keys[2]] = builder.worldPoint(elbow.transform(Vec3(0, -q.lowerArm, 0)))
    }

    /// Thigh, knee, shin and foot. `keys` are the hip, knee and ankle keypoints.
    private static func addLeg(
        _ side: String,
        hip: Mat4,
        knee angle: Double,
        _ q: Proportions,
        _ builder: inout BodyBuilder,
        _ points: inout [KeypointName: Vec3],
        _ keys: [KeypointName]
    ) {
        builder.add(
            "thigh\(side)",
            .capsule(radius: q.legR, length: q.upperLeg * 0.7),
            at: hip * .translation(Vec3(0, -q.upperLeg * 0.5, 0)),
            color: 0x86868E
        )
        let knee = hip * .node(Vec3(0, -q.upperLeg, 0), Vec3(angle, 0, 0))
        builder.add(
            "shin\(side)",
            .capsule(radius: q.legR * 0.85, length: q.lowerLeg * 0.7),
            at: knee * .translation(Vec3(0, -q.lowerLeg * 0.5, 0)),
            color: 0x8A8A92
        )
        builder.add(
            "foot\(side)",
            .box(size: Vec3(q.legR * 2, 0.06 * q.s, 0.22 * q.s)),
            at: knee * .translation(Vec3(0, -q.lowerLeg + 0.03 * q.s, -0.05 * q.s)),
            color: 0x6F6F76
        )
        points[keys[0]] = builder.worldPoint(hip.transform(.zero))
        points[keys[1]] = builder.worldPoint(knee.transform(.zero))
        points[keys[2]] = builder.worldPoint(knee.transform(Vec3(0, -q.lowerLeg, 0)))
    }
}
