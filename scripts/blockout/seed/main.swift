// Seed for the PrevisCore port: a scratch Swift translation of Blockout's engine that matched the TypeScript
// evaluator on the parity scenes (worst difference 8.9e-16). Not compiled by any target; Lane A moves it into
// Sources/PrevisCore and adapts it to the contract types.
// Translated from Blockout (https://github.com/wassermanproductions/blockout) src/engine at 3f2d0564,
// Apache-2.0, by Sam Wasserman (wassermanproductions.com). See scripts/blockout/NOTICE.

// Lines up to "compare to TS goldens" are the evaluator; the rest is the scratch parity comparator.
import Foundation

// ---------- document model (subset needed by the evaluator) ----------
struct Mark: Codable {
    var id: String; var time, hold, easeIn, easeOut: Double; var position: V3; var via: [V3]?
    var gait: String?; var arriveHeading: Double?; var joints: [String: Double]?; var attachTo: String?
    var pan, tilt, roll, focalLength, focusDistance: Double?
}
struct Transform: Codable { var position: V3; var rotationY: Double; var scale: Double }
struct AttachedLocal: Codable { var x, y, z, rotY: Double }
struct Entity: Codable {
    var id: String; var assetId: String; var transform: Transform
    var params: [String: Double]?   // golden scenes use numeric params only
    var attachedTo: String?; var attachedLocal: AttachedLocal?
}
struct Track: Codable { var entityId: String; var marks: [Mark] }
struct Take: Codable { var id: String; var tracks: [Track] }
struct ShotCamera: Codable { var sensorId: String; var rig: String; var rigIntensity: Double; var seed: Double
    var mountEntityId: String?; var trackEntityId: String?; var marks: [Mark] }
struct Shot: Codable { var duration: Double; var fps: Double; var aspect: String; var blockingTakeId: String; var camera: ShotCamera }
struct Scene: Codable { var entities: [Entity]; var blocking: [Take] }

struct EntityState: Codable { var entityId: String; var position: V3; var heading: Double; var gait: String
    var distanceTravelled: Double; var speed: Double; var joints: [String: Double]? }
struct CameraState: Codable { var position: V3; var pan, tilt, roll, focalLength: Double; var focusDistance: Double?; var vfov: Double }
struct ShotState: Codable { var time: Double; var camera: CameraState; var entities: [EntityState] }

let TRAVELS: [String: Bool] = ["stand": false, "walk": true, "jog": true, "run": true, "sit": false, "lie": false, "crouch": true, "gesture": false, "fall": false]
let HEIGHTS: [String: Double] = ["person.man": 1.78, "person.woman": 1.65, "vehicle.suv": 1.8, "vehicle.bus": 3.2, "prim.cube": 1.0]
func entityHeight(_ e: Entity) -> Double { HEIGHTS[e.assetId, default: 1.7] * e.transform.scale * (e.params?["height"] ?? 1) }
func smoothstep(_ u: Double) -> Double { let u = min(1, max(0, u)); return u * u * (3 - 2 * u) }
func lerp(_ a: Double, _ b: Double, _ u: Double) -> Double { a + (b - a) * u }

struct Leg { var from: Mark, to: Mark; var depart, arrive: Double; var path: Path; var distanceBefore: Double }
func sortedStable(_ m: [Mark]) -> [Mark] { m.enumerated().sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }.map { $0.element } }
func buildLegs(_ marks: [Mark]) -> [Leg] {
    let s = sortedStable(marks); var legs: [Leg] = []; var before = 0.0
    if s.count < 2 { return [] }
    for i in 0..<(s.count - 1) {
        let from = s[i], to = s[i+1]
        let depart = min(from.time + from.hold, max(from.time, to.time - 0.1))
        let arrive = max(to.time, depart + 0.001)
        let path = Path([from.position] + (to.via ?? []) + [to.position])
        legs.append(Leg(from: from, to: to, depart: depart, arrive: arrive, path: path, distanceBefore: before))
        before += path.length
    }
    return legs
}
struct TrackResult { var position: V3; var travelHeading: Double?; var distance, speed: Double; var leg: Leg?; var atMark: Mark?; var legProgress: Double }
func evaluateTrack(_ marks: [Mark], _ legs: [Leg], _ t: Double) -> TrackResult {
    let first = sortedStable(marks)[0]
    if legs.isEmpty || t <= first.time { return .init(position: first.position, travelHeading: nil, distance: 0, speed: 0, leg: nil, atMark: first, legProgress: 0) }
    for leg in legs {
        if t < leg.depart { return .init(position: leg.from.position, travelHeading: nil, distance: leg.distanceBefore, speed: 0, leg: nil, atMark: leg.from, legProgress: 0) }
        if t <= leg.arrive {
            let u = (t - leg.depart) / (leg.arrive - leg.depart)
            let progress = easedProgress(u, leg.from.easeOut, leg.to.easeIn)
            let d = progress * leg.path.length
            let du = 0.001
            let p2 = easedProgress(min(1, u + du), leg.from.easeOut, leg.to.easeIn)
            let speed = ((p2 - progress) * leg.path.length) / (du * (leg.arrive - leg.depart))
            return .init(position: leg.path.pointAt(d), travelHeading: leg.path.length > 0.001 ? leg.path.headingAt(d) : nil,
                         distance: leg.distanceBefore + d, speed: speed, leg: leg, atMark: nil, legProgress: u)
        }
    }
    let last = legs.last!
    return .init(position: last.to.position, travelHeading: nil, distance: last.distanceBefore + last.path.length, speed: 0, leg: nil, atMark: last.to, legProgress: 1)
}
func lerpJoints(_ from: [String: Double]?, _ to: [String: Double]?, _ u: Double) -> [String: Double]? {
    if from == nil && to == nil { return nil }
    var out: [String: Double] = [:]
    for k in Set(from?.keys.map { $0 } ?? []).union(to?.keys.map { $0 } ?? []) {
        let a = from?[k] ?? 0, b = to?[k] ?? 0
        out[k] = a + (b - a) * u
    }
    return out
}
final class ShotEvaluator {
    let scene: Scene, shot: Shot
    var cameraLegs: [Leg] = []
    var tracks: [(entity: Entity, marks: [Mark], legs: [Leg])] = []
    var staticEntities: [Entity] = []
    var trackFirstTime: [String: Double] = [:]
    var boardMarks: [(String, [Mark])] = []     // insertion-ordered like a JS Map
    var boardOffsets: [String: AttachedLocal] = [:]
    init(_ scene: Scene, _ shot: Shot) {
        self.scene = scene; self.shot = shot
        cameraLegs = shot.camera.marks.count >= 2 ? buildLegs(shot.camera.marks) : []
        let take = scene.blocking.first { $0.id == shot.blockingTakeId } ?? scene.blocking.first
        var tracked = Set<String>()
        for track in take?.tracks ?? [] {
            guard let entity = scene.entities.first(where: { $0.id == track.entityId }), !track.marks.isEmpty else { continue }
            tracked.insert(entity.id)
            let item = (entity: entity, marks: track.marks, legs: track.marks.count >= 2 ? buildLegs(track.marks) : [])
            if let i = tracks.firstIndex(where: { $0.entity.id == entity.id }) { tracks[i] = item } else { tracks.append(item) }
            let s = sortedStable(track.marks)
            trackFirstTime[entity.id] = s[0].time
            for m in s where m.attachTo != nil {
                if let i = boardMarks.firstIndex(where: { $0.0 == entity.id }) { boardMarks[i].1.append(m) } else { boardMarks.append((entity.id, [m])) }
            }
        }
        staticEntities = scene.entities.filter { !tracked.contains($0.id) }
    }
    func lastTravelHeading(_ legs: [Leg], _ t: Double) -> Double? {
        var latest: Leg? = nil
        for leg in legs where t >= leg.arrive && leg.path.length > 0.001 { latest = leg }
        return latest.map { $0.path.headingAt($0.path.length) }
    }
    func poseOf(_ id: String, _ t: Double) -> (V3, Double) {
        if let ti = tracks.first(where: { $0.entity.id == id }) {
            let r = evaluateTrack(ti.marks, ti.legs, t)
            return (r.position, r.travelHeading ?? r.atMark?.arriveHeading ?? lastTravelHeading(ti.legs, t) ?? ti.entity.transform.rotationY)
        }
        if let e = scene.entities.first(where: { $0.id == id }) { return (e.transform.position, e.transform.rotationY) }
        return (V3(x: 0, y: 0, z: 0), 0)
    }
    func evaluate(_ tIn: Double) -> ShotState {
        let time = min(max(0, tIn), shot.duration)
        var ents: [EntityState] = []
        for (entity, marks, legs) in tracks {
            let r = evaluateTrack(marks, legs, time)
            let heading = r.travelHeading ?? r.atMark?.arriveHeading ?? lastTravelHeading(legs, time) ?? entity.transform.rotationY
            let gait = r.leg != nil ? (r.leg!.to.gait ?? "stand") : (r.atMark?.gait ?? "stand")
            let travels = TRAVELS[gait]!
            let joints: [String: Double]? = r.leg.map { lerpJoints($0.from.joints, $0.to.joints, easedProgress(r.legProgress, $0.from.easeOut, $0.to.easeIn)) } ?? r.atMark?.joints
            ents.append(.init(entityId: entity.id, position: r.position, heading: heading,
                              gait: r.leg != nil && travels ? gait : (r.leg != nil ? "walk" : gait),
                              distanceTravelled: r.distance, speed: r.speed, joints: joints))
        }
        for e in staticEntities { ents.append(.init(entityId: e.id, position: e.transform.position, heading: e.transform.rotationY, gait: "stand", distanceTravelled: 0, speed: 0, joints: nil)) }
        resolveBoardings(&ents, time); resolveMarriages(&ents, time)
        return ShotState(time: time, camera: evaluateCamera(time, ents), entities: ents)
    }
    func resolveBoardings(_ ents: inout [EntityState], _ time: Double) {
        for (entityId, marks) in boardMarks {
            var active: Mark? = nil
            for m in marks where time >= m.time { active = m }
            guard let a = active, let target = a.attachTo else { continue }
            guard let ri = ents.firstIndex(where: { $0.entityId == entityId }), let vi = ents.firstIndex(where: { $0.entityId == target }) else { continue }
            var off = boardOffsets[a.id]
            if off == nil {
                let (vp, vh) = poseOf(target, a.time)
                let dx = a.position.x - vp.x, dz = a.position.z - vp.z
                let c = cos(vh), s = sin(vh)
                off = AttachedLocal(x: dx * c - dz * s, y: a.position.y - vp.y, z: dx * s + dz * c, rotY: a.arriveHeading.map { $0 - vh } ?? 0)
                boardOffsets[a.id] = off
            }
            let v = ents[vi]; let o = off!
            let c = cos(v.heading), s = sin(v.heading)
            ents[ri].position = V3(x: v.position.x + o.x * c + o.z * s, y: v.position.y + o.y, z: v.position.z - o.x * s + o.z * c)
            ents[ri].heading = v.heading + o.rotY
            ents[ri].gait = "stand"; ents[ri].speed = v.speed; ents[ri].distanceTravelled = v.distanceTravelled
            if let j = a.joints { ents[ri].joints = j }
        }
    }
    func resolveMarriages(_ ents: inout [EntityState], _ time: Double) {
        for _ in 0..<4 {
            var changed = false
            for e in scene.entities {
                guard let at = e.attachedTo, let l = e.attachedLocal else { continue }
                if let f = trackFirstTime[e.id], time >= f { continue }
                guard let ci = ents.firstIndex(where: { $0.entityId == e.id }), let pi = ents.firstIndex(where: { $0.entityId == at }) else { continue }
                let p = ents[pi]; let c = cos(p.heading), s = sin(p.heading)
                let nx = p.position.x + l.x * c + l.z * s, ny = p.position.y + l.y, nz = p.position.z - l.x * s + l.z * c, nh = p.heading + l.rotY
                let ch = ents[ci]
                if abs(ch.position.x - nx) > 1e-9 || abs(ch.position.y - ny) > 1e-9 || abs(ch.position.z - nz) > 1e-9 || abs(ch.heading - nh) > 1e-9 { changed = true }
                ents[ci].position = V3(x: nx, y: ny, z: nz); ents[ci].heading = nh; ents[ci].speed = p.speed; ents[ci].distanceTravelled = p.distanceTravelled
            }
            if !changed { break }
        }
    }
    func evaluateCamera(_ time: Double, _ ents: [EntityState]) -> CameraState {
        let cam = shot.camera, marks = cam.marks
        var pos: V3, pan: Double, tilt: Double, roll: Double, focal: Double, focus: Double?
        if marks.isEmpty { pos = V3(x: 5, y: 1.6, z: 5); pan = headingOf(V3(x: -5, y: 0, z: -5)); tilt = 0; roll = 0; focal = 35; focus = nil }
        else if marks.count == 1 { let m = marks[0]; pos = m.position; pan = m.pan!; tilt = m.tilt!; roll = m.roll!; focal = m.focalLength!; focus = m.focusDistance }
        else {
            let r = evaluateTrack(marks, cameraLegs, time); pos = r.position
            if let leg = r.leg {
                let u = smoothstep(easedProgress(r.legProgress, leg.from.easeOut, leg.to.easeIn))
                pan = lerpAngle(leg.from.pan!, leg.to.pan!, u); tilt = lerpAngle(leg.from.tilt!, leg.to.tilt!, u); roll = lerpAngle(leg.from.roll!, leg.to.roll!, u)
                focal = lerp(leg.from.focalLength!, leg.to.focalLength!, u)
                let f0 = leg.from.focusDistance, f1 = leg.to.focusDistance
                focus = (f0 != nil && f1 != nil) ? lerp(f0!, f1!, u) : (f1 ?? f0)
            } else { let m = r.atMark!; pan = m.pan!; tilt = m.tilt!; roll = m.roll!; focal = m.focalLength!; focus = m.focusDistance }
        }
        if cam.rig == "carMount", let mid = cam.mountEntityId, let mount = ents.first(where: { $0.entityId == mid }) {
            let c = cos(mount.heading), s = sin(mount.heading)
            pos = V3(x: mount.position.x + pos.x * c + pos.z * s, y: mount.position.y + pos.y, z: mount.position.z - pos.x * s + pos.z * c)
            pan += mount.heading
        }
        if let tid = cam.trackEntityId, let subj = ents.first(where: { $0.entityId == tid }), let doc = scene.entities.first(where: { $0.id == tid }) {
            let aimUp = entityHeight(doc) * 0.8
            let dx = subj.position.x - pos.x, dy = subj.position.y + aimUp - pos.y, dz = subj.position.z - pos.z
            let flat = hypot(dx, dz)
            if flat > 1e-4 || abs(dy) > 1e-4 {
                pan = headingOf(V3(x: dx, y: 0, z: dz)); tilt = atan2(dy, max(flat, 1e-4))
                if focus != nil { focus = max(0.3, sqrt(dx*dx + dy*dy + dz*dz)) }
            }
        }
        let n = rigOffsetFull(rig: cam.rig, seed: cam.seed, t: time, intensity: cam.rigIntensity)
        return CameraState(position: V3(x: pos.x + n[0], y: pos.y + n[1], z: pos.z + n[2]), pan: pan + n[3], tilt: tilt + n[4], roll: roll + n[5],
                           focalLength: focal, focusDistance: focus, vfov: verticalFov(cam.sensorId, focal, shot.aspect))
    }
}

// ---------- compare to TS goldens ----------
struct Case: Codable { var name: String; var scene: Scene; var shot: Shot; var samples: [Sample] }
struct Sample: Codable { var t: Double; var state: ShotState }
let dec = JSONDecoder()
let cases = try! dec.decode([Case].self, from: try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
for c in cases {
    let ev = ShotEvaluator(c.scene, c.shot)
    var maxD = 0.0, worst = "", n = 0, exact = 0
    func cmp(_ label: String, _ a: Double, _ b: Double, _ t: Double) { n += 1; if a == b { exact += 1 }; let d = abs(a - b); if d > maxD { maxD = d; worst = "\(label)@t=\(t)" } }
    var missingKeys = 0
    for s in c.samples {
        let mine = ev.evaluate(s.t), ref = s.state
        let cm = mine.camera, cr = ref.camera
        for (l, a, b) in [("cam.x", cm.position.x, cr.position.x), ("cam.y", cm.position.y, cr.position.y), ("cam.z", cm.position.z, cr.position.z), ("pan", cm.pan, cr.pan), ("tilt", cm.tilt, cr.tilt), ("roll", cm.roll, cr.roll), ("focal", cm.focalLength, cr.focalLength), ("vfov", cm.vfov, cr.vfov)] { cmp(l, a, b, s.t) }
        if (cm.focusDistance == nil) != (cr.focusDistance == nil) { missingKeys += 1 } else if let a = cm.focusDistance, let b = cr.focusDistance { cmp("focus", a, b, s.t) }
        for r in ref.entities {
            guard let m = mine.entities.first(where: { $0.entityId == r.entityId }) else { missingKeys += 1; continue }
            for (l, a, b) in [("x", m.position.x, r.position.x), ("y", m.position.y, r.position.y), ("z", m.position.z, r.position.z), ("heading", m.heading, r.heading), ("dist", m.distanceTravelled, r.distanceTravelled), ("speed", m.speed, r.speed)] { cmp(r.entityId + "." + l, a, b, s.t) }
            if m.gait != r.gait { missingKeys += 1; print("  GAIT MISMATCH \(r.entityId)@\(s.t): \(m.gait) vs \(r.gait)") }
            if (m.joints == nil) != (r.joints == nil) { missingKeys += 1 } else if let mj = m.joints, let rj = r.joints { for k in rj.keys { cmp("joint." + k, mj[k] ?? .nan, rj[k]!, s.t) } }
        }
    }
    print("\(c.name): compared \(n) scalars, bit-exact \(exact), max |diff| \(maxD) (\(worst)), structural mismatches \(missingKeys)")
}
