// Translated from Blockout (https://github.com/wassermanproductions/blockout) src/renderer/viewport/builders.ts
// (buildQuadruped and its animate closure) at 3f2d0564, Apache-2.0, by Sam Wasserman (wassermanproductions.com).
// Changes: pure function of the evaluated pose, no scene graph. See Resources/NOTICE.

import Foundation

/// Dog, cat and horse: a capsule body on four capsule legs, a neck and head at the front (−Z) and a tail at the
/// back. Proportions follow the catalog height.
enum QuadrupedRig {
    private struct Leg {
        var id: String
        var x: Double
        var z: Double
        var angle: Double
    }

    static func build(asset: AssetSpec, scale: Double, state: EntityPose, into builder: inout BodyBuilder) {
        let h = asset.height
        let bodyLen = h * 1.7
        let bodyR = h * 0.28
        let legH = h * 0.55
        let bodyY = legH
        let phase = PersonRig.phase(gait: state.gait, distance: state.distanceTravelled, scale: scale)
        let swing = sin(phase * 2 * .pi)
        let amp = min(1, 0.2 + state.speed * 0.15)
        let moving = state.speed > 0.01

        builder.add(
            "body",
            .capsule(radius: bodyR, length: bodyLen - bodyR * 2),
            at: .node(Vec3(0, bodyY, 0), Vec3(.pi / 2, 0, 0)),
            color: 0x87878F
        )

        // Diagonal pairs swing together: front left with back right.
        let legX = bodyR * 0.7
        let legs: [Leg] = [
            Leg(id: "legFrontLeft", x: -legX, z: -bodyLen * 0.32, angle: swing * amp),
            Leg(id: "legFrontRight", x: legX, z: -bodyLen * 0.32, angle: -swing * amp),
            Leg(id: "legBackLeft", x: -legX, z: bodyLen * 0.32, angle: -swing * amp),
            Leg(id: "legBackRight", x: legX, z: bodyLen * 0.32, angle: swing * amp),
        ]
        for leg in legs {
            let hip = Mat4.node(Vec3(leg.x, bodyY, leg.z), Vec3(leg.angle, 0, 0))
            builder.add(
                leg.id,
                .capsule(radius: h * 0.08, length: legH * 0.6),
                at: hip * .translation(Vec3(0, -legH * 0.5, 0)),
                color: 0x82828A
            )
        }

        let bob = moving ? 0 : sin(state.time * 1.2) * 0.08
        let neckPivot = Mat4.node(Vec3(0, bodyY + bodyR * 0.3, -bodyLen * 0.32 - bodyR * 0.4), Vec3(bob, 0, 0))
        builder.add(
            "neck",
            .capsule(radius: bodyR * 0.5, length: h * 0.4),
            at: neckPivot * .node(Vec3(0, h * 0.2, -h * 0.12), Vec3(0.6, 0, 0)),
            color: 0x84848C
        )
        let head = neckPivot * .translation(Vec3(0, h * 0.42, -h * 0.28))
        builder.add(
            "head",
            .box(size: Vec3(bodyR * 0.9, bodyR * 0.85, bodyR * 1.2)),
            at: head,
            color: 0x8F8F97
        )
        builder.add(
            "snout",
            .box(size: Vec3(bodyR * 0.5, bodyR * 0.4, bodyR * 0.5)),
            at: head * .translation(Vec3(0, -bodyR * 0.1, -bodyR * 0.85)),
            color: 0x86868E
        )

        let wag = sin(state.time * 3 + phase * 2 * .pi) * 0.15
        let tail = Mat4.node(Vec3(0, bodyY + bodyR * 0.4, bodyLen * 0.32 + bodyR * 0.3), Vec3(wag, 0, 0))
        builder.add(
            "tail",
            .capsule(radius: bodyR * 0.22, length: h * 0.5),
            at: tail * .node(Vec3(0, h * 0.1, h * 0.18), Vec3(-0.8, 0, 0)),
            color: 0x82828A
        )
    }
}
