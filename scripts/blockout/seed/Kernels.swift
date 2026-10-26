// Seed for the PrevisCore port: a scratch Swift translation of Blockout's engine that matched the TypeScript
// evaluator on the parity scenes (worst difference 8.9e-16). Not compiled by any target; Lane A moves it into
// Sources/PrevisCore and adapts it to the contract types.
// Translated from Blockout (https://github.com/wassermanproductions/blockout) src/engine at 3f2d0564,
// Apache-2.0, by Sam Wasserman (wassermanproductions.com). See scripts/blockout/NOTICE.

import Foundation

// ---- JS ToInt32/ToUint32 semantics for a Double
func jsToUInt32(_ d: Double) -> UInt32 {
    if !d.isFinite { return 0 }
    let t = d.rounded(.towardZero)
    let m = t.truncatingRemainder(dividingBy: 4294967296.0)
    let pos = m < 0 ? m + 4294967296.0 : m
    return UInt32(pos)
}

struct Mulberry32 {
    var a: UInt32
    init(_ seed: Double) { a = jsToUInt32(seed) }
    mutating func next() -> Double {
        a = a &+ 0x6d2b79f5
        var t = (a ^ (a >> 15)) &* (1 | a)
        t = (t &+ ((t ^ (t >> 7)) &* (61 | t))) ^ t
        return Double(t ^ (t >> 14)) / 4294967296.0
    }
}

final class ValueNoise1D {
    let seed: Double, channel: Double
    var lattice: [Int: Double] = [:]
    init(seed: Double, channel: Double) { self.seed = seed; self.channel = channel }
    func at(_ i: Int) -> Double {
        if let v = lattice[i] { return v }
        let h = jsToUInt32(seed * 2654435761.0) ^ jsToUInt32(channel * 40503.0) ^ jsToUInt32(Double(i) * 2246822519.0)
        var r = Mulberry32(Double(h))
        let v = r.next() * 2 - 1
        lattice[i] = v
        return v
    }
    func sample(_ t: Double) -> Double {
        let i = t.rounded(.down); let f = t - i
        let u = f * f * (3 - 2 * f)
        return at(Int(i)) * (1 - u) + at(Int(i) + 1) * u
    }
}
final class FractalNoise1D {
    let octaves: [ValueNoise1D]
    init(seed: Double, channel: Double, count: Int) {
        octaves = (0..<count).map { ValueNoise1D(seed: seed, channel: channel * 16 + Double($0)) }
    }
    func sample(_ t: Double, _ frequency: Double) -> Double {
        var amp = 1.0, freq = frequency, sum = 0.0, norm = 0.0
        for o in octaves { sum += o.sample(t * freq) * amp; norm += amp; amp *= 0.5; freq *= 2.1 }
        return sum / norm
    }
}
struct RigSpec { let posAmp, rotAmp, frequency: Double; let octaves: Int }
let RIGS: [String: RigSpec] = [
    "handheld": .init(posAmp: 0.045, rotAmp: 0.018, frequency: 1.8, octaves: 3),
    "steadicam": .init(posAmp: 0.03, rotAmp: 0.004, frequency: 0.5, octaves: 2),
    "carMount": .init(posAmp: 0.02, rotAmp: 0.006, frequency: 2.5, octaves: 3),
]
func rigOffset(rig: String, seed: Double, t: Double, intensity: Double) -> [Double] {
    let s = RIGS[rig]!
    let ch = (0..<6).map { FractalNoise1D(seed: seed, channel: Double($0 + 1), count: s.octaves) }
    let p = s.posAmp * intensity, r = s.rotAmp * intensity, f = s.frequency
    return [ch[0].sample(t, f) * p, ch[1].sample(t, f) * p * 0.7, ch[2].sample(t, f) * p * 0.5,
            ch[3].sample(t, f) * r, ch[4].sample(t, f) * r * 0.8, ch[5].sample(t, f) * r * 0.35]
}
func easedProgress(_ uIn: Double, _ easeOut: Double, _ easeIn: Double) -> Double {
    let total = easeOut + easeIn
    var a = easeOut, b = easeIn
    if total > 0.98 { a = easeOut / total * 0.98; b = easeIn / total * 0.98 }
    let u = min(1, max(0, uIn))
    let v = 1 / (1 - a / 2 - b / 2)
    if u < a { return v * u * u / (2 * a) }
    if u > 1 - b { let w = 1 - u; return 1 - v * w * w / (2 * b) }
    return v * a / 2 + v * (u - a)
}
func lerpAngle(_ a: Double, _ b: Double, _ u: Double) -> Double {
    var d = (b - a).truncatingRemainder(dividingBy: Double.pi * 2)
    if d > Double.pi { d -= Double.pi * 2 }
    if d < -Double.pi { d += Double.pi * 2 }
    return a + d * u
}
struct V3: Codable { var x, y, z: Double }
func dist(_ a: V3, _ b: V3) -> Double { let dx = b.x-a.x, dy = b.y-a.y, dz = b.z-a.z; return (dx*dx+dy*dy+dz*dz).squareRoot() }
func headingOf(_ d: V3) -> Double { atan2(-d.x, -d.z) }
func catmullRom(_ p0: V3, _ p1: V3, _ p2: V3, _ p3: V3, _ t: Double) -> V3 {
    let alpha = 0.5
    let d01 = pow(max(dist(p0,p1), 1e-6), alpha), d12 = pow(max(dist(p1,p2), 1e-6), alpha), d23 = pow(max(dist(p2,p3), 1e-6), alpha)
    let t0 = 0.0, t1 = t0 + d01, t2 = t1 + d12, t3 = t2 + d23
    let tt = t1 + (t2 - t1) * t
    func lv(_ a: V3, _ b: V3, _ ta: Double, _ tb: Double, _ tv: Double) -> V3 {
        if abs(tb - ta) < 1e-9 { return a }
        let u = (tv - ta) / (tb - ta)
        return V3(x: a.x + (b.x-a.x)*u, y: a.y + (b.y-a.y)*u, z: a.z + (b.z-a.z)*u)
    }
    let a1 = lv(p0,p1,t0,t1,tt), a2 = lv(p1,p2,t1,t2,tt), a3 = lv(p2,p3,t2,t3,tt)
    let b1 = lv(a1,a2,t0,t2,tt), b2 = lv(a2,a3,t1,t3,tt)
    return lv(b1,b2,t1,t2,tt)
}
final class Path {
    var samples: [V3] = [], cumulative: [Double] = []
    var length = 0.0
    init(_ pts: [V3], samplesPerSegment: Int = 32) {
        let pts = pts.count >= 2 ? pts : [pts[0], pts[0]]
        var acc = 0.0; var prev: V3? = nil
        for i in 0..<(pts.count - 1) {
            let p1 = pts[i], p2 = pts[i+1]
            let p0 = i > 0 ? pts[i-1] : V3(x: p1.x + (p1.x-p2.x), y: p1.y + (p1.y-p2.y), z: p1.z + (p1.z-p2.z))
            let p3 = i + 2 < pts.count ? pts[i+2] : V3(x: p2.x + (p2.x-p1.x), y: p2.y + (p2.y-p1.y), z: p2.z + (p2.z-p1.z))
            for k in (i == 0 ? 0 : 1)...samplesPerSegment {
                let p = catmullRom(p0,p1,p2,p3, Double(k)/Double(samplesPerSegment))
                if let pr = prev { acc += dist(pr, p) }
                samples.append(p); cumulative.append(acc); prev = p
            }
        }
        length = acc
    }
    func pointAt(_ distance: Double) -> V3 {
        let d = min(length, max(0, distance))
        var lo = 0, hi = cumulative.count - 1
        while lo < hi { let mid = (lo + hi) >> 1; if cumulative[mid] < d { lo = mid + 1 } else { hi = mid } }
        let i = max(1, lo)
        let d0 = cumulative[i-1], d1 = cumulative[i], p0 = samples[i-1], p1 = samples[i]
        let u = d1 - d0 < 1e-9 ? 0 : (d - d0) / (d1 - d0)
        return V3(x: p0.x + (p1.x-p0.x)*u, y: p0.y + (p1.y-p0.y)*u, z: p0.z + (p1.z-p0.z)*u)
    }
    func headingAt(_ distance: Double) -> Double {
        let eps = max(length * 0.001, 0.01)
        let a = pointAt(max(0, distance - eps)), b = pointAt(min(length, distance + eps))
        let dx = b.x - a.x, dz = b.z - a.z
        if abs(dx) < 1e-9 && abs(dz) < 1e-9 { return 0 }
        return headingOf(V3(x: dx, y: 0, z: dz))
    }
}
let SENSORS: [String: (w: Double, h: Double)] = ["super16": (12.52, 7.41), "super35": (24.89, 18.66), "fullFrame": (36, 24), "imax65": (52.63, 23.01)]
let ASPECTS: [String: Double] = ["16:9": 16.0/9.0, "9:16": 9.0/16.0, "2.39:1": 2.39, "4:3": 4.0/3.0, "1:1": 1]
func verticalFov(_ s: String, _ f: Double, _ a: String) -> Double {
    let sen = SENSORS[s]!; return 2 * atan(min(sen.h, sen.w / ASPECTS[a]!) / (2 * f))
}

let RIGS_ALL: [String: RigSpec] = RIGS.merging([
  "sticks": .init(posAmp: 0, rotAmp: 0, frequency: 0, octaves: 1), "dolly": .init(posAmp: 0.005, rotAmp: 0.0005, frequency: 0.4, octaves: 1),
  "crane": .init(posAmp: 0.01, rotAmp: 0.001, frequency: 0.3, octaves: 1), "drone": .init(posAmp: 0.05, rotAmp: 0.002, frequency: 0.25, octaves: 2)]) { a, _ in a }
func rigOffsetFull(rig: String, seed: Double, t: Double, intensity: Double) -> [Double] {
    let s = RIGS_ALL[rig]!
    if s.posAmp == 0 && s.rotAmp == 0 { return [0,0,0,0,0,0] }
    let ch = (0..<6).map { FractalNoise1D(seed: seed, channel: Double($0 + 1), count: s.octaves) }
    let p = s.posAmp * intensity, r = s.rotAmp * intensity, f = s.frequency
    return [ch[0].sample(t, f) * p, ch[1].sample(t, f) * p * 0.7, ch[2].sample(t, f) * p * 0.5,
            ch[3].sample(t, f) * r, ch[4].sample(t, f) * r * 0.8, ch[5].sample(t, f) * r * 0.35]
}
