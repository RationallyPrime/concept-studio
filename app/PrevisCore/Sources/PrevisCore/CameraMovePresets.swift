// Translated from Blockout (https://github.com/wassermanproductions/blockout) src/engine/camera-moves.ts at
// 3f2d0564, Apache-2.0, by Sam Wasserman (wassermanproductions.com). Changes: the 20 starter moves only, as pure
// functions over a subject sampler. See Resources/NOTICE.

import Foundation

/// The subject's pose at a time.
struct SubjectSample {
    var x: Double
    var y: Double
    var z: Double
    var heading: Double

    var position: Vec3 {
        Vec3(x, y, z)
    }
}

/// What a move is generated from: the subject, and the live camera at t = 0.
struct CameraMoveContext {
    var subjectAt: (Double) -> SubjectSample
    var subjectHeight: Double
    var camera: CameraStart
    var duration: Double
}

struct CameraStart {
    var position: Vec3
    var pan: Double
    var tilt: Double
    var focalLength: Double
}

struct CameraSpec: Equatable {
    var time: Double
    var position: Vec3
    var pan: Double
    var tilt: Double
    var roll: Double
    var focalLength: Double
    var easeIn: Double
    var easeOut: Double
    var hold: Double
}

enum CameraMovePresets {
    static func generate(_ id: String, _ ctx: CameraMoveContext) -> [CameraSpec]? {
        presets[id].map { $0(Moves(ctx: ctx)) }
    }

    private static var presets: [String: (Moves) -> [CameraSpec]] {
        [
            "slow-push-in": { $0.slowPushIn() },
            "crash-in": { $0.crashIn() },
            "creep-in-low": { $0.creepInLow() },
            "orbit-90-left": { $0.orbit(sweep: .pi / 2, count: 6) },
            "orbit-90-right": { $0.orbit(sweep: -.pi / 2, count: 6) },
            "orbit-45-low": { $0.orbitAt(sweep: .pi / 4, count: 6) { _, _ in 0.5 } },
            "arc-and-push": { $0.orbit(sweep: .pi / 2, count: 7, radiusScaleEnd: 0.6) },
            "crane-up-reveal": { $0.craneUpReveal() },
            "pedestal-up-slow": { $0.pedestal(rise: 2) },
            "spiral-in-descend": { moves in
                moves
                    .spiral(sweep: .pi, radiusScaleEnd: 0.55, count: 7) { _, s0 in
                        s0.y + moves.ctx.subjectHeight * 0.8
                    }
            },
            "side-track-left": { $0.sideTrack(sign: 1) },
            "side-track-right": { $0.sideTrack(sign: -1) },
            "lead-the-subject": { $0.lead(height: { _, scale in 1.8 * scale }) },
            "lead-follow-front": { $0.lead(height: { airborne, scale in airborne ? 1.8 * scale : 1.6 }) },
            "follow-behind": { $0.followBehind() },
            "low-lead-tilt-up": { $0.lowLeadTiltUp() },
            "side-dolly-past": { $0.sideDollyPast() },
            "slow-tilt-reveal": { $0.slowTiltReveal() },
            "whip-pan": { $0.whipPan() },
            "vertigo-dolly-zoom": { $0.vertigoDollyZoom() },
        ]
    }

    private struct MarkBuild {
        var t: Double
        var pos: Vec3
        var aimAt: Vec3
        var focalLength: Double
        var roll = 0.0
    }

    private struct Moves {
        let ctx: CameraMoveContext

        var cam: Vec3 {
            ctx.camera.position
        }

        var airborne: Bool {
            ctx.subjectAt(0).y > 3
        }

        func forward(_ heading: Double) -> Vec3 {
            Vec3(-sin(heading), 0, -cos(heading))
        }

        /// Subject position plus 0.8 × its height.
        func aimPoint(_ s: SubjectSample) -> Vec3 {
            Vec3(s.x, s.y + ctx.subjectHeight * 0.8, s.z)
        }

        func aim(from cam: Vec3, to target: Vec3) -> (pan: Double, tilt: Double) {
            let dx = target.x - cam.x, dy = target.y - cam.y, dz = target.z - cam.z
            return (headingOf(dx: dx, dz: dz), atan2(dy, (dx * dx + dz * dz).squareRoot()))
        }

        func planarDistance(_ a: Vec3, _ b: Vec3) -> Double {
            let dx = b.x - a.x, dz = b.z - a.z
            return (dx * dx + dz * dz).squareRoot()
        }

        func floorClamp(_ y: Double) -> Double {
            airborne ? y : max(0.2, y)
        }

        func times(_ count: Int) -> [Double] {
            (0 ..< count).map { ctx.duration * Double($0) / Double(count - 1) }
        }

        /// The bearing from the subject's first aim point to the camera, as a heading.
        func startBearing(_ startAim: Vec3) -> Double {
            headingOf(dx: cam.x - startAim.x, dz: cam.z - startAim.z)
        }

        /// Ease 0.25 on the first and last marks, hold 0, pan and tilt aimed at each mark's aim point.
        func build(_ marks: [MarkBuild]) -> [CameraSpec] {
            let last = marks.count - 1
            return marks.enumerated().map { index, m in
                let position = Vec3(m.pos.x, floorClamp(m.pos.y), m.pos.z)
                let (pan, tilt) = aim(from: position, to: m.aimAt)
                let edge = index == 0 || index == last
                return CameraSpec(
                    time: m.t,
                    position: position,
                    pan: pan,
                    tilt: tilt,
                    roll: m.roll,
                    focalLength: m.focalLength,
                    easeIn: edge ? 0.25 : 0,
                    easeOut: edge ? 0.25 : 0,
                    hold: 0
                )
            }
        }

        /// Marks on a ray from the subject along the camera's original bearing, at `distance(u)` and `height(u, s)`.
        func alongBearing(
            count: Int,
            startDistance: Double,
            distance: (Double, Double) -> Double,
            height: (Double, SubjectSample) -> Double
        ) -> [CameraSpec] {
            let startAim = aimPoint(ctx.subjectAt(0))
            let dir = forward(startBearing(startAim))
            return build(times(count).map { t in
                let u = t / ctx.duration
                let s = ctx.subjectAt(t)
                let target = aimPoint(s)
                let d = distance(u, startDistance)
                return MarkBuild(
                    t: t,
                    pos: Vec3(target.x + dir.x * d, height(u, s), target.z + dir.z * d),
                    aimAt: target,
                    focalLength: ctx.camera.focalLength
                )
            })
        }

        // MARK: Push and pull

        func slowPushIn() -> [CameraSpec] {
            let startAim = aimPoint(ctx.subjectAt(0))
            let startDist = max(planarDistance(cam, startAim), 0.5)
            return alongBearing(
                count: 7,
                startDistance: startDist,
                distance: { u, start in start + (2 - start) * u },
                height: { u, s in cam.y + (aimPoint(s).y - cam.y) * u * 0.4 }
            )
        }

        func crashIn() -> [CameraSpec] {
            let startAim = aimPoint(ctx.subjectAt(0))
            let startDist = max(planarDistance(cam, startAim), 0.6)
            return alongBearing(
                count: 7,
                startDistance: startDist,
                distance: { u, start in start + (1.2 - start) * (u * u * u) },
                height: { _, _ in cam.y }
            )
        }

        func creepInLow() -> [CameraSpec] {
            let startAim = aimPoint(ctx.subjectAt(0))
            let startDist = max(planarDistance(cam, startAim), 4)
            return alongBearing(
                count: 7,
                startDistance: startDist,
                distance: { u, start in start + (2.5 - start) * u },
                height: { _, _ in 0.5 }
            )
        }

        // MARK: Orbit and arc

        /// The camera circles the subject, whose position follows `subjectAt`; radius and height come from the live
        /// camera's offset at t = 0, and the height stays at the live camera's.
        func orbit(sweep: Double, count: Int, radiusScaleEnd: Double = 1) -> [CameraSpec] {
            let s0 = ctx.subjectAt(0)
            let radius0 = max(planarDistance(cam, s0.position), 2)
            let startAzimuth = headingOf(dx: cam.x - s0.x, dz: cam.z - s0.z)
            return build(times(count).map { t in
                let u = t / ctx.duration
                let s = ctx.subjectAt(t)
                let offset = forward(startAzimuth + sweep * u)
                let radius = radius0 * (1 + (radiusScaleEnd - 1) * u)
                return MarkBuild(
                    t: t,
                    pos: Vec3(s.x + offset.x * radius, cam.y, s.z + offset.z * radius),
                    aimAt: aimPoint(s),
                    focalLength: ctx.camera.focalLength
                )
            })
        }

        func orbitAt(sweep: Double, count: Int, height: (Double, SubjectSample) -> Double) -> [CameraSpec] {
            let s0 = ctx.subjectAt(0)
            let radius0 = max(planarDistance(cam, s0.position), 2)
            let startAzimuth = headingOf(dx: cam.x - s0.x, dz: cam.z - s0.z)
            return build(times(count).map { t in
                let u = t / ctx.duration
                let s = ctx.subjectAt(t)
                let offset = forward(startAzimuth + sweep * u)
                return MarkBuild(
                    t: t,
                    pos: Vec3(s.x + offset.x * radius0, height(cam.y, s), s.z + offset.z * radius0),
                    aimAt: aimPoint(s),
                    focalLength: ctx.camera.focalLength
                )
            })
        }

        /// A helix: orbit `sweep` while the radius scales to `radiusScaleEnd` and the height eases to `endY`.
        func spiral(
            sweep: Double,
            radiusScaleEnd: Double,
            count: Int,
            endY: (Double, SubjectSample) -> Double
        ) -> [CameraSpec] {
            let s0 = ctx.subjectAt(0)
            let radius0 = max(planarDistance(cam, s0.position), 2)
            let startAzimuth = headingOf(dx: cam.x - s0.x, dz: cam.z - s0.z)
            let yEnd = endY(cam.y, s0)
            return build(times(count).map { t in
                let u = t / ctx.duration
                let s = ctx.subjectAt(t)
                let offset = forward(startAzimuth + sweep * u)
                let radius = radius0 * (1 + (radiusScaleEnd - 1) * u)
                return MarkBuild(
                    t: t,
                    pos: Vec3(s.x + offset.x * radius, cam.y + (yEnd - cam.y) * u, s.z + offset.z * radius),
                    aimAt: aimPoint(s),
                    focalLength: ctx.camera.focalLength
                )
            })
        }

        // MARK: Crane and boom

        func craneUpReveal() -> [CameraSpec] {
            let startAim = aimPoint(ctx.subjectAt(0))
            let dir = forward(startBearing(startAim))
            let radius = max(planarDistance(cam, startAim), 3)
            return build(times(7).map { t in
                let u = t / ctx.duration
                let s = ctx.subjectAt(t)
                let target = aimPoint(s)
                let y = s.y + ctx.subjectHeight * 0.9 + (8 - ctx.subjectHeight * 0.9) * u
                return MarkBuild(
                    t: t,
                    pos: Vec3(target.x + dir.x * radius, y, target.z + dir.z * radius),
                    aimAt: target,
                    focalLength: ctx.camera.focalLength
                )
            })
        }

        /// A vertical rise of `rise` metres holding aim on the subject.
        func pedestal(rise: Double) -> [CameraSpec] {
            let startAim = aimPoint(ctx.subjectAt(0))
            let dir = forward(startBearing(startAim))
            let radius = max(planarDistance(cam, startAim), 2)
            return build(times(6).map { t in
                let u = t / ctx.duration
                let target = aimPoint(ctx.subjectAt(t))
                return MarkBuild(
                    t: t,
                    pos: Vec3(target.x + dir.x * radius, cam.y + rise * u, target.z + dir.z * radius),
                    aimAt: target,
                    focalLength: ctx.camera.focalLength
                )
            })
        }

        // MARK: Follow

        func followBehind() -> [CameraSpec] {
            let scale = airborne ? 2.5 : 1.0
            let distance = 4 * scale, height = 1.8 * scale
            return build(times(8).map { t in
                let s = ctx.subjectAt(t)
                let back = forward(s.heading)
                return MarkBuild(
                    t: t,
                    pos: Vec3(s.x - back.x * distance, s.y + height, s.z - back.z * distance),
                    aimAt: aimPoint(s),
                    focalLength: ctx.camera.focalLength
                )
            })
        }

        /// In front of the subject, facing back at it.
        func lead(height: (Bool, Double) -> Double) -> [CameraSpec] {
            let scale = airborne ? 2.5 : 1.0
            let distance = 4 * scale
            let y = height(airborne, scale)
            return build(times(8).map { t in
                let s = ctx.subjectAt(t)
                let ahead = forward(s.heading)
                return MarkBuild(
                    t: t,
                    pos: Vec3(s.x + ahead.x * distance, s.y + y, s.z + ahead.z * distance),
                    aimAt: aimPoint(s),
                    focalLength: ctx.camera.focalLength
                )
            })
        }

        func lowLeadTiltUp() -> [CameraSpec] {
            build(times(8).map { t in
                let s = ctx.subjectAt(t)
                let ahead = forward(s.heading)
                return MarkBuild(
                    t: t,
                    pos: Vec3(s.x + ahead.x * 4, 0.4, s.z + ahead.z * 4),
                    aimAt: aimPoint(s),
                    focalLength: ctx.camera.focalLength
                )
            })
        }

        func sideTrack(sign: Double) -> [CameraSpec] {
            let scale = airborne ? 2.5 : 1.0
            let distance = 4 * scale
            let height = airborne ? 1.8 * scale : 1.6
            return build(times(8).map { t in
                let s = ctx.subjectAt(t)
                let side = forward(s.heading - (sign * .pi) / 2)
                return MarkBuild(
                    t: t,
                    pos: Vec3(s.x + side.x * distance, s.y + height, s.z + side.z * distance),
                    aimAt: aimPoint(s),
                    focalLength: ctx.camera.focalLength
                )
            })
        }

        func sideDollyPast() -> [CameraSpec] {
            let flank = 4.0, height = airborne ? 4.0 : 1.6
            let behind = 6.0, ahead = 6.0
            return build(times(8).map { t in
                let u = t / ctx.duration
                let s = ctx.subjectAt(t)
                let fwd = forward(s.heading)
                let side = forward(s.heading - .pi / 2)
                let along = -behind + (behind + ahead) * u
                return MarkBuild(
                    t: t,
                    pos: Vec3(
                        s.x + side.x * flank + fwd.x * along,
                        s.y + height,
                        s.z + side.z * flank + fwd.z * along
                    ),
                    aimAt: aimPoint(s),
                    focalLength: ctx.camera.focalLength
                )
            })
        }

        // MARK: Pan and scan, stylized

        func fixed(_ index: Int, _ count: Int, pan: Double, tilt: Double, time: Double) -> CameraSpec {
            let edge = index == 0 || index == count - 1
            return CameraSpec(
                time: time,
                position: Vec3(cam.x, floorClamp(cam.y), cam.z),
                pan: pan,
                tilt: tilt,
                roll: 0,
                focalLength: ctx.camera.focalLength,
                easeIn: edge ? 0.25 : 0,
                easeOut: edge ? 0.25 : 0,
                hold: 0
            )
        }

        func slowTiltReveal() -> [CameraSpec] {
            let ts = times(7)
            return ts.enumerated().map { index, t in
                let u = t / ctx.duration
                let s = ctx.subjectAt(t)
                let startTilt = aim(from: cam, to: Vec3(s.x, 0, s.z)).tilt
                let (pan, endTilt) = aim(from: cam, to: aimPoint(s))
                return fixed(index, ts.count, pan: pan, tilt: startTilt + (endTilt - startTilt) * u, time: t)
            }
        }

        func whipPan() -> [CameraSpec] {
            let base = aim(from: cam, to: aimPoint(ctx.subjectAt(0)))
            let whip = Double.pi / 2
            let dur = ctx.duration, mid = dur / 2
            let raw: [(t: Double, pan: Double)] = [
                (0, base.pan),
                (max(0.001, mid - 0.25), base.pan),
                (mid - 0.2, base.pan),
                (mid + 0.2, base.pan + whip),
                (mid + 0.25, base.pan + whip),
                (dur, base.pan + whip),
            ]
            var points = raw.map { (t: min(dur, max(0, $0.t)), pan: $0.pan) }
            points = points.enumerated().sorted { ($0.element.t, $0.offset) < ($1.element.t, $1.offset) }.map(\.element)
            var out: [CameraSpec] = []
            for index in points.indices {
                let own = points[index]
                // nudge duplicate times to keep them strictly increasing
                let time = index > 0 && own.t <= points[index - 1].t ? points[index - 1].t + 0.001 : own.t
                points[index].t = time
                out.append(fixed(index, points.count, pan: own.pan, tilt: base.tilt, time: time))
            }
            return out
        }

        func vertigoDollyZoom() -> [CameraSpec] {
            let startAim = aimPoint(ctx.subjectAt(0))
            let startDist = max(planarDistance(cam, startAim), 6)
            let endDist = startDist * 0.55
            let dir = forward(startBearing(startAim))
            let fl0 = max(ctx.camera.focalLength, 24)
            return build(times(7).map { t in
                let u = t / ctx.duration
                let target = aimPoint(ctx.subjectAt(t))
                let d = startDist + (endDist - startDist) * u
                // keep the subject the same apparent size: fl(t) = fl0 · dist(t) / dist0
                let focal = min(135, max(12, fl0 * (d / startDist)))
                return MarkBuild(
                    t: t,
                    pos: Vec3(target.x + dir.x * d, cam.y, target.z + dir.z * d),
                    aimAt: target,
                    focalLength: focal
                )
            })
        }
    }
}
