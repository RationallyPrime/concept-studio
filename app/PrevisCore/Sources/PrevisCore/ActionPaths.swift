// Translated from Blockout (https://github.com/wassermanproductions/blockout) src/engine/action-presets.ts at
// 3f2d0564, Apache-2.0, by Sam Wasserman (wassermanproductions.com). Changes: the 14 starter presets only, as pure
// functions over a start pose; marks get fresh ids and may be retimed to a speed. See Resources/NOTICE.

import Foundation

public enum ActionPaths { // speed nil keeps Blockout's timing; otherwise metres per second
    /// A starter path for `entity`, starting from its placement. Marks begin at `startTime`.
    ///
    /// With `speed` nil the marks keep Blockout's timing over `duration`. Otherwise the path is shaped for `duration`
    /// and then its times are scaled so the average speed along the marks is `speed` metres per second: a `duration`
    /// only matters to the shape of the paths that grow with it, such as walk-forward.
    public static func marks(
        _ pathID: String,
        entity: PrevisEntity,
        startTime: Double,
        duration: Double,
        speed: Double?,
        catalog: ContentCatalog
    ) throws -> [ActorMark] {
        guard catalog.actionPaths.contains(where: { $0.id == pathID }) else {
            throw ShotsError
                .unknownContent("The action path \"\(pathID)\" is not in the catalog; pick one from the list.")
        }
        guard duration.isFinite, duration > 0 else {
            throw ShotsError.invalid([
                ShotsProblem(
                    severity: .error,
                    message: "An action path needs a duration above zero seconds, not \(duration).",
                    entityID: entity.id
                ),
            ])
        }
        let placement = entity.placement
        let start = ActionStart(position: placement.position, heading: placement.heading)
        guard var specs = ActionPresets.generate(pathID, start: start, duration: duration) else {
            throw ShotsError.notImplemented("The action path \"\(pathID)\" is in the catalog but has no generator yet.")
        }
        if let speed {
            guard speed.isFinite, speed > 0 else {
                throw ShotsError.invalid([
                    ShotsProblem(
                        severity: .error,
                        message: "An action path speed must be above zero metres per second, not \(speed).",
                        entityID: entity.id
                    ),
                ])
            }
            let length = zip(specs, specs.dropFirst()).reduce(0) { $0 + distance($1.0.position, $1.1.position) }
            if length > 0 {
                let factor = length / speed / duration
                specs = specs.map { var spec = $0; spec.time *= factor; return spec }
            }
        }
        return specs.map { spec in
            ActorMark(
                id: PrevisIDs.make("mark"),
                time: startTime + spec.time,
                hold: spec.hold,
                easeIn: spec.easeIn,
                easeOut: spec.easeOut,
                position: spec.position,
                gait: spec.gait
            )
        }
    }
}

struct ActionStart {
    var position: Vec3
    var heading: Double
}

struct ActionSpec: Equatable {
    var time: Double
    var position: Vec3
    var gait: Gait
    var easeIn = 0.0
    var easeOut = 0.0
    var hold = 0.0
}

/// Blockout's presets as pure functions of a start pose and a duration. Paths extend along the start heading;
/// y is altitude and never goes below the ground.
enum ActionPresets {
    static func generate(_ id: String, start: ActionStart, duration: Double) -> [ActionSpec]? {
        let ctx = Context(start: start, duration: duration)
        switch id {
        case "plane-takeoff": return ctx.planeTakeoff()
        case "plane-landing": return ctx.planeLanding()
        case "plane-flyby": return ctx.planeFlyby()
        case "plane-banked-circle": return ctx.circle(
                radius: 25,
                altitude: max(start.position.y, 8),
                count: 9,
                centred: true
            )
        case "plane-crash-dive": return ctx.planeCrashDive()
        case "heli-orbit": return ctx.circle(radius: 15, altitude: max(start.position.y, 8), count: 9, centred: false)
        case "bird-circle-soar": return ctx.birdCircleSoar()
        case "bird-swoop": return ctx.birdSwoop()
        case "walk-forward": return ctx.steady(speed: 1.4, gait: .walk)
        case "run-forward": return ctx.steady(speed: 5, gait: .run)
        case "walk-up-stairs": return ctx.walkUpStairs()
        case "jump-forward": return ctx.jumpForward()
        case "door-burst-run": return ctx.doorBurstRun()
        case "horse-gallop-loop": return ctx.circle(radius: 20, altitude: 0, count: 9, centred: false, gait: .run)
        default: return nil
        }
    }

    private struct Context {
        let start: ActionStart
        let duration: Double

        func forward(_ heading: Double) -> Vec3 {
            Vec3(-sin(heading), 0, -cos(heading))
        }

        func right(_ heading: Double) -> Vec3 {
            forward(heading - .pi / 2)
        }

        /// A point `fwd` metres ahead of and `side` metres to the right of the start, at altitude `y`.
        func at(_ fwd: Double, _ side: Double, _ y: Double) -> Vec3 {
            let f = forward(start.heading), r = right(start.heading)
            return Vec3(
                start.position.x + f.x * fwd + r.x * side,
                y,
                start.position.z + f.z * fwd + r.z * side
            )
        }

        /// Even times from 0 to the duration.
        func times(_ count: Int) -> [Double] {
            (0 ..< count).map { duration * Double($0) / Double(count - 1) }
        }

        /// Clamps altitude at the ground and pins the first mark to the exact start pose at t = 0.
        func build(_ marks: [ActionSpec]) -> [ActionSpec] {
            var out = marks.map { mark in
                var mark = mark
                mark.position.y = max(0, mark.position.y)
                return mark
            }
            out[0].time = 0
            out[0].position = Vec3(start.position.x, max(0, start.position.y), start.position.z)
            return out
        }

        // MARK: Aircraft

        func planeTakeoff() -> [ActionSpec] {
            let rollEnd = 30.0, totalForward = 70.0, climbTo = 18.0
            return build(times(7).enumerated().map { index, t in
                let u = t / duration
                let forward = totalForward * u * u
                let airborne = forward <= rollEnd ? 0 : (forward - rollEnd) / (totalForward - rollEnd)
                return ActionSpec(
                    time: t,
                    position: at(forward, 0, climbTo * airborne),
                    gait: .run,
                    easeIn: index == 0 ? 0.25 : 0
                )
            })
        }

        func planeLanding() -> [ActionSpec] {
            let startY = max(start.position.y, 6)
            let approach = 55.0, roll = 25.0
            return build([
                ActionSpec(time: 0, position: at(0, 0, start.position.y), gait: .run, easeIn: 0.25),
                ActionSpec(time: duration * 0.25, position: at(approach * 0.4, 0, startY * 0.55), gait: .run),
                ActionSpec(time: duration * 0.5, position: at(approach * 0.8, 0, startY * 0.18), gait: .run),
                ActionSpec(time: duration * 0.62, position: at(approach, 0, 0), gait: .run),
                ActionSpec(time: duration * 0.82, position: at(approach + roll * 0.7, 0, 0), gait: .walk),
                ActionSpec(time: duration, position: at(approach + roll, 0, 0), gait: .stand, easeIn: 0.25, hold: 1),
            ])
        }

        func planeFlyby() -> [ActionSpec] {
            let altitude = max(start.position.y, 8)
            return build(times(6).map { t in
                ActionSpec(time: t, position: at(90 * (t / duration), 0, altitude), gait: .run)
            })
        }

        func planeCrashDive() -> [ActionSpec] {
            let startY = max(start.position.y, 8)
            let dive = 45.0, skid = 10.0
            return build([
                ActionSpec(time: 0, position: at(0, 0, start.position.y), gait: .run, easeIn: 0.25),
                ActionSpec(time: duration * 0.3, position: at(dive * 0.45, 0, startY * 0.55), gait: .run),
                ActionSpec(time: duration * 0.55, position: at(dive * 0.85, 0, startY * 0.15), gait: .run),
                ActionSpec(time: duration * 0.65, position: at(dive, 0, 0), gait: .run),
                ActionSpec(time: duration * 0.85, position: at(dive + skid * 0.7, 0, 0), gait: .walk),
                ActionSpec(time: duration, position: at(dive + skid, 0, 0), gait: .stand, easeIn: 0.25, hold: 0.5),
            ])
        }

        // MARK: Circles: banked circle, helicopter orbit, horse gallop

        /// A full turn that starts at the left edge of a circle `radius` to the right and returns to the start.
        /// `centred` is the banked circle's arrangement of the same arithmetic, kept for bit-for-bit parity.
        func circle(radius: Double, altitude: Double, count: Int, centred: Bool, gait: Gait = .run) -> [ActionSpec] {
            let f = forward(start.heading), r = right(start.heading)
            let cx = start.position.x + r.x * radius, cz = start.position.z + r.z * radius
            return build(times(count).map { t in
                let u = t / duration
                let angle = Double.pi - 2 * Double.pi * u
                let side = radius + radius * cos(angle)
                let along = radius * sin(angle)
                let position = centred
                    ? Vec3(
                        cx - r.x * radius + r.x * side + f.x * along,
                        altitude,
                        cz - r.z * radius + r.z * side + f.z * along
                    )
                    : Vec3(
                        start.position.x + r.x * side + f.x * along,
                        altitude,
                        start.position.z + r.z * side + f.z * along
                    )
                return ActionSpec(time: t, position: position, gait: gait)
            })
        }

        // MARK: Birds

        func birdCircleSoar() -> [ActionSpec] {
            let baseY = max(start.position.y, 6)
            let radius = 12.0, climb = 5.0
            let f = forward(start.heading), r = right(start.heading)
            return build(times(9).map { t in
                let u = t / duration
                let angle = Double.pi - 2 * Double.pi * u
                let side = radius + radius * cos(angle)
                let along = radius * sin(angle)
                let position = Vec3(
                    start.position.x + r.x * side + f.x * along,
                    baseY + climb * u,
                    start.position.z + r.z * side + f.z * along
                )
                return ActionSpec(time: t, position: position, gait: .walk)
            })
        }

        func birdSwoop() -> [ActionSpec] {
            let startY = max(start.position.y, 8)
            return build([
                ActionSpec(time: 0, position: at(0, 0, start.position.y), gait: .run, easeIn: 0.25),
                ActionSpec(time: duration * 0.3, position: at(14, 0, startY * 0.4), gait: .run),
                ActionSpec(time: duration * 0.5, position: at(24, 0, 0.4), gait: .run),
                ActionSpec(time: duration * 0.7, position: at(34, 0, startY * 0.5), gait: .run),
                ActionSpec(time: duration, position: at(46, 0, startY), gait: .walk),
            ])
        }

        // MARK: People

        func steady(speed: Double, gait: Gait) -> [ActionSpec] {
            let total = speed * duration
            let ts = times(7)
            return build(ts.enumerated().map { index, t in
                ActionSpec(
                    time: t,
                    position: at(total * (t / duration), 0, 0),
                    gait: gait,
                    easeIn: index == 0 ? 0.25 : 0,
                    easeOut: index == ts.count - 1 ? 0.25 : 0
                )
            })
        }

        func walkUpStairs() -> [ActionSpec] {
            let steps = 8, riseEach = 0.17, climbForward = 6.0
            let climbEnd = duration * 0.85
            var marks = [ActionSpec(time: 0, position: at(0, 0, start.position.y), gait: .walk, easeIn: 0.25)]
            for k in 1 ... steps {
                let u = Double(k) / Double(steps)
                marks.append(
                    ActionSpec(
                        time: climbEnd * u,
                        position: at(climbForward * u, 0, start.position.y + riseEach * Double(k)),
                        gait: .walk
                    )
                )
            }
            marks.append(
                ActionSpec(
                    time: duration,
                    position: at(climbForward + 1.2, 0, start.position.y + riseEach * Double(steps)),
                    gait: .stand,
                    easeIn: 0.25,
                    hold: 1
                )
            )
            return build(marks)
        }

        func jumpForward() -> [ActionSpec] {
            let hops = 3, advance = 1.2, peak = 0.5
            let perHop = duration / Double(hops)
            var marks = [ActionSpec(time: 0, position: at(0, 0, start.position.y), gait: .jog, easeIn: 0.25)]
            for hop in 0 ..< hops {
                let base = advance * Double(hop)
                let t0 = perHop * Double(hop)
                let isLast = hop == hops - 1
                marks.append(
                    ActionSpec(
                        time: t0 + perHop * 0.5,
                        position: at(base + advance * 0.5, 0, start.position.y + peak),
                        gait: .jog
                    )
                )
                marks.append(
                    ActionSpec(
                        time: t0 + perHop,
                        position: at(base + advance, 0, start.position.y),
                        gait: isLast ? .stand : .jog,
                        easeOut: isLast ? 0.25 : 0,
                        hold: isLast ? 0.5 : 0
                    )
                )
            }
            return build(marks)
        }

        func doorBurstRun() -> [ActionSpec] {
            let total = 42.0
            return build([
                ActionSpec(time: 0, position: at(0, 0, 0), gait: .stand, easeIn: 0.25, hold: 0.3),
                ActionSpec(time: duration * 0.12, position: at(0.6, 0, 0), gait: .walk),
                ActionSpec(time: duration * 0.35, position: at(total * 0.12, 0, 0), gait: .run),
                ActionSpec(time: duration * 0.6, position: at(total * 0.4, 0, 0), gait: .run),
                ActionSpec(time: duration * 0.8, position: at(total * 0.68, 0, 0), gait: .run),
                ActionSpec(time: duration, position: at(total, 0, 0), gait: .run, easeOut: 0.25),
            ])
        }
    }
}
