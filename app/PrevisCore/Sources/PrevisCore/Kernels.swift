// Translated from Blockout (https://github.com/wassermanproductions/blockout) src/engine/{easing,path,random,camera,
// rigs}.ts at 3f2d0564, Apache-2.0, by Sam Wasserman (wassermanproductions.com). Changes: pure value types and
// functions (no cached lattices or mutable classes), contract types. See Resources/NOTICE.

import Foundation

// MARK: Numbers

/// JavaScript's ToUint32 on a Double: truncate toward zero, then wrap modulo 2^32.
func jsToUInt32(_ value: Double) -> UInt32 {
    guard value.isFinite else { return 0 }
    let wrapped = value.rounded(.towardZero).truncatingRemainder(dividingBy: 4_294_967_296)
    return UInt32(wrapped < 0 ? wrapped + 4_294_967_296 : wrapped)
}

func smoothstep(_ u: Double) -> Double {
    let c = min(1, max(0, u))
    return c * c * (3 - 2 * c)
}

func lerp(_ a: Double, _ b: Double, _ u: Double) -> Double {
    a + (b - a) * u
}

/// Interpolates along the shorter arc.
func lerpAngle(_ a: Double, _ b: Double, _ u: Double) -> Double {
    var d = (b - a).truncatingRemainder(dividingBy: .pi * 2)
    if d > .pi { d -= .pi * 2 }
    if d < -.pi { d += .pi * 2 }
    return a + d * u
}

/// Heading of a horizontal direction: heading 0 faces −Z.
func headingOf(dx: Double, dz: Double) -> Double {
    atan2(-dx, -dz)
}

func distance(_ a: Vec3, _ b: Vec3) -> Double {
    (b - a).length
}

/// Distance eased in over the first `easeOut` of the leg and out over the last `easeIn`; `u` and the result are 0...1.
func easedProgress(_ rawU: Double, easeOut: Double, easeIn: Double) -> Double {
    var a = easeOut, b = easeIn
    let total = a + b
    if total > 0.98 {
        a = easeOut / total * 0.98
        b = easeIn / total * 0.98
    }
    let u = min(1, max(0, rawU))
    let v = 1 / (1 - a / 2 - b / 2)
    if u < a { return v * u * u / (2 * a) }
    if u > 1 - b {
        let w = 1 - u
        return 1 - v * w * w / (2 * b)
    }
    return v * a / 2 + v * (u - a)
}

// MARK: Paths

/// A centripetal Catmull-Rom curve (alpha 0.5) through the points, sampled 32 times per segment and measured by
/// cumulative chord length.
struct PathCurve: Sendable {
    private(set) var samples: [Vec3] = []
    private var cumulative: [Double] = []
    private(set) var length = 0.0

    init(_ points: [Vec3], samplesPerSegment: Int = 32) {
        guard let first = points.first else { return }
        let pts = points.count >= 2 ? points : [first, first]
        var total = 0.0
        var previous: Vec3?
        for i in 0 ..< (pts.count - 1) {
            let p1 = pts[i], p2 = pts[i + 1]
            let p0 = i > 0 ? pts[i - 1] : p1 + (p1 - p2)
            let p3 = i + 2 < pts.count ? pts[i + 2] : p2 + (p2 - p1)
            for k in (i == 0 ? 0 : 1) ... samplesPerSegment {
                let p = Self.catmullRom(p0, p1, p2, p3, Double(k) / Double(samplesPerSegment))
                if let previous { total += distance(previous, p) }
                samples.append(p)
                cumulative.append(total)
                previous = p
            }
        }
        length = total
    }

    private static func catmullRom(_ p0: Vec3, _ p1: Vec3, _ p2: Vec3, _ p3: Vec3, _ t: Double) -> Vec3 {
        let d01 = pow(max(distance(p0, p1), 1e-6), 0.5)
        let d12 = pow(max(distance(p1, p2), 1e-6), 0.5)
        let d23 = pow(max(distance(p2, p3), 1e-6), 0.5)
        let t0 = 0.0, t1 = d01, t2 = d01 + d12, t3 = d01 + d12 + d23
        let tt = t1 + (t2 - t1) * t
        func mix(_ a: Vec3, _ b: Vec3, _ ta: Double, _ tb: Double) -> Vec3 {
            if abs(tb - ta) < 1e-9 { return a }
            return a + (b - a) * ((tt - ta) / (tb - ta))
        }
        let a1 = mix(p0, p1, t0, t1), a2 = mix(p1, p2, t1, t2), a3 = mix(p2, p3, t2, t3)
        let b1 = mix(a1, a2, t0, t2), b2 = mix(a2, a3, t1, t3)
        return mix(b1, b2, t1, t2)
    }

    func point(at distance: Double) -> Vec3 {
        guard samples.count >= 2 else { return samples.first ?? .zero }
        let d = min(length, max(0, distance))
        var lo = 0, hi = cumulative.count - 1
        while lo < hi {
            let mid = (lo + hi) >> 1
            if cumulative[mid] < d { lo = mid + 1 } else { hi = mid }
        }
        let i = max(1, lo)
        let d0 = cumulative[i - 1], d1 = cumulative[i]
        let u = d1 - d0 < 1e-9 ? 0 : (d - d0) / (d1 - d0)
        return samples[i - 1] + (samples[i] - samples[i - 1]) * u
    }

    /// A central difference; 0 when the path is not moving horizontally there.
    func heading(at distance: Double) -> Double {
        let eps = max(length * 0.001, 0.01)
        let a = point(at: max(0, distance - eps)), b = point(at: min(length, distance + eps))
        let dx = b.x - a.x, dz = b.z - a.z
        if abs(dx) < 1e-9, abs(dz) < 1e-9 { return 0 }
        return headingOf(dx: dx, dz: dz)
    }
}

// MARK: Rig noise

/// mulberry32 with exact UInt32 arithmetic.
struct Mulberry32 {
    private var state: UInt32

    init(seed: Double) {
        state = jsToUInt32(seed)
    }

    mutating func next() -> Double {
        state = state &+ 0x6D2B_79F5
        var t = (state ^ (state >> 15)) &* (1 | state)
        t = (t &+ ((t ^ (t >> 7)) &* (61 | t))) ^ t
        return Double(t ^ (t >> 14)) / 4_294_967_296.0
    }
}

/// Smooth 1-D value noise on a hashed integer lattice. The hash multiplies as Doubles before ToUint32, as
/// JavaScript does, so seeds above about 3.4 million still agree.
private func valueNoise(seed: Double, channel: Double, at t: Double) -> Double {
    func lattice(_ i: Int) -> Double {
        let h = jsToUInt32(seed * 2_654_435_761) ^ jsToUInt32(channel * 40503) ^ jsToUInt32(Double(i) * 2_246_822_519)
        var rng = Mulberry32(seed: Double(h))
        return rng.next() * 2 - 1
    }
    let i = t.rounded(.down), f = t - i
    let u = f * f * (3 - 2 * f)
    return lattice(Int(i)) * (1 - u) + lattice(Int(i) + 1) * u
}

private func fractalNoise(seed: Double, channel: Double, octaves: Int, t: Double, frequency: Double) -> Double {
    var amp = 1.0, freq = frequency, sum = 0.0, norm = 0.0
    for octave in 0 ..< octaves {
        sum += valueNoise(seed: seed, channel: channel * 16 + Double(octave), at: t * freq) * amp
        norm += amp
        amp *= 0.5
        freq *= 2.1
    }
    return sum / norm
}

/// Position amplitude (m), rotation amplitude (rad), frequency (Hz) and octaves.
struct RigSpec {
    var position: Double
    var rotation: Double
    var frequency: Double
    var octaves: Int
}

/// Offsets added to the camera: position, then pan, tilt and roll.
struct RigNoise {
    var position: Vec3
    var pan: Double
    var tilt: Double
    var roll: Double
}

extension Rig {
    /// Position amplitude, rotation amplitude, Hz and octaves.
    var spec: RigSpec {
        switch self {
        case .sticks: RigSpec(position: 0, rotation: 0, frequency: 0, octaves: 1)
        case .dolly: RigSpec(position: 0.005, rotation: 0.0005, frequency: 0.4, octaves: 1)
        case .steadicam: RigSpec(position: 0.03, rotation: 0.004, frequency: 0.5, octaves: 2)
        case .handheld: RigSpec(position: 0.045, rotation: 0.018, frequency: 1.8, octaves: 3)
        case .crane: RigSpec(position: 0.01, rotation: 0.001, frequency: 0.3, octaves: 1)
        case .drone: RigSpec(position: 0.05, rotation: 0.002, frequency: 0.25, octaves: 2)
        case .carMount: RigSpec(position: 0.02, rotation: 0.006, frequency: 2.5, octaves: 3)
        }
    }

    /// Position (x, y, z) and rotation (pan, tilt, roll) offsets at time `t`.
    func noise(
        seed: Double,
        t: Double,
        intensity: Double
    ) -> RigNoise {
        let s = spec
        if s.position == 0, s.rotation == 0 { return RigNoise(position: .zero, pan: 0, tilt: 0, roll: 0) }
        func channel(_ n: Double) -> Double {
            fractalNoise(seed: seed, channel: n, octaves: s.octaves, t: t, frequency: s.frequency)
        }
        let p = s.position * intensity, r = s.rotation * intensity
        return RigNoise(
            position: Vec3(channel(1) * p, channel(2) * p * 0.7, channel(3) * p * 0.5),
            pan: channel(4) * r,
            tilt: channel(5) * r * 0.8,
            roll: channel(6) * r * 0.35
        )
    }
}
