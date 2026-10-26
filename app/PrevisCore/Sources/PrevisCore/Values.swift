import Foundation

// Values and maths from CONTRACTS section 5.1. Metres, seconds and radians; Y up, right-handed.

public struct Vec3: Codable, Hashable, Sendable {
    public var x: Double, y: Double, z: Double

    public init(_ x: Double, _ y: Double, _ z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    public static let zero = Vec3(0, 0, 0)

    static func + (a: Vec3, b: Vec3) -> Vec3 {
        Vec3(a.x + b.x, a.y + b.y, a.z + b.z)
    }

    static func - (a: Vec3, b: Vec3) -> Vec3 {
        Vec3(a.x - b.x, a.y - b.y, a.z - b.z)
    }

    static func * (a: Vec3, s: Double) -> Vec3 {
        Vec3(a.x * s, a.y * s, a.z * s)
    }

    static func += (a: inout Vec3, b: Vec3) {
        a = a + b
    }

    static func *= (a: inout Vec3, s: Double) {
        a = a * s
    }

    func dot(_ b: Vec3) -> Double {
        x * b.x + y * b.y + z * b.z
    }

    var length: Double {
        dot(self).squareRoot()
    }

    var normalized: Vec3 {
        let l = length
        return l > 0 ? self * (1 / l) : self
    }
}

public struct Point2: Codable, Hashable, Sendable {
    public var x: Double, y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct PixelSize: Codable, Hashable, Sendable {
    public var width: Int, height: Int // any positive size
    public var aspect: Double {
        Double(width) / Double(height)
    }

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

public struct Quat: Codable, Hashable, Sendable {
    public var x: Double, y: Double, z: Double, w: Double

    public init(x: Double, y: Double, z: Double, w: Double) {
        self.x = x
        self.y = y
        self.z = z
        self.w = w
    }

    public static let identity = Quat(x: 0, y: 0, z: 0, w: 1)

    /// Rotation about +Y by `heading`: heading 0 faces −Z and positive headings turn toward −X.
    public static func yaw(_ heading: Double) -> Quat {
        Quat(x: 0, y: sin(heading / 2), z: 0, w: cos(heading / 2))
    }

    static func pitch(_ angle: Double) -> Quat {
        Quat(x: sin(angle / 2), y: 0, z: 0, w: cos(angle / 2))
    }

    static func roll(_ angle: Double) -> Quat {
        Quat(x: 0, y: 0, z: sin(angle / 2), w: cos(angle / 2))
    }

    /// Hamilton product: `a * b` applies `b` first, then `a`.
    static func * (a: Quat, b: Quat) -> Quat {
        Quat(
            x: a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
            y: a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
            z: a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
            w: a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z
        )
    }

    func rotate(_ v: Vec3) -> Vec3 {
        let u = Vec3(x, y, z)
        let t = cross(u, v) * 2
        return v + t * w + cross(u, t)
    }
}

private func cross(_ a: Vec3, _ b: Vec3) -> Vec3 {
    Vec3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
}

public struct Mat4: Hashable, Sendable {
    /// 16 values, column-major; `m[12...14]` is the translation.
    public var m: [Double]

    init(_ m: [Double]) {
        self.m = m
    }

    public static let identity = Mat4([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1])

    public static func * (a: Mat4, b: Mat4) -> Mat4 {
        var out = [Double](repeating: 0, count: 16)
        for col in 0 ..< 4 {
            for row in 0 ..< 4 {
                var sum = 0.0
                for k in 0 ..< 4 {
                    sum += a.m[k * 4 + row] * b.m[col * 4 + k]
                }
                out[col * 4 + row] = sum
            }
        }
        return Mat4(out)
    }

    /// Transforms a point (w = 1) and divides by w when the matrix is a projection.
    public func transform(_ point: Vec3) -> Vec3 {
        let x = m[0] * point.x + m[4] * point.y + m[8] * point.z + m[12]
        let y = m[1] * point.x + m[5] * point.y + m[9] * point.z + m[13]
        let z = m[2] * point.x + m[6] * point.y + m[10] * point.z + m[14]
        let w = m[3] * point.x + m[7] * point.y + m[11] * point.z + m[15]
        if w != 1, w != 0 { return Vec3(x / w, y / w, z / w) }
        return Vec3(x, y, z)
    }

    /// The general 4×4 inverse. A singular matrix has none; it returns the identity rather than crash.
    public var inverse: Mat4 {
        let a = m
        var inv = [Double](repeating: 0, count: 16)
        inv[0] = a[5] * a[10] * a[15] - a[5] * a[11] * a[14] - a[9] * a[6] * a[15]
            + a[9] * a[7] * a[14] + a[13] * a[6] * a[11] - a[13] * a[7] * a[10]
        inv[4] = -a[4] * a[10] * a[15] + a[4] * a[11] * a[14] + a[8] * a[6] * a[15]
            - a[8] * a[7] * a[14] - a[12] * a[6] * a[11] + a[12] * a[7] * a[10]
        inv[8] = a[4] * a[9] * a[15] - a[4] * a[11] * a[13] - a[8] * a[5] * a[15]
            + a[8] * a[7] * a[13] + a[12] * a[5] * a[11] - a[12] * a[7] * a[9]
        inv[12] = -a[4] * a[9] * a[14] + a[4] * a[10] * a[13] + a[8] * a[5] * a[14]
            - a[8] * a[6] * a[13] - a[12] * a[5] * a[10] + a[12] * a[6] * a[9]
        inv[1] = -a[1] * a[10] * a[15] + a[1] * a[11] * a[14] + a[9] * a[2] * a[15]
            - a[9] * a[3] * a[14] - a[13] * a[2] * a[11] + a[13] * a[3] * a[10]
        inv[5] = a[0] * a[10] * a[15] - a[0] * a[11] * a[14] - a[8] * a[2] * a[15]
            + a[8] * a[3] * a[14] + a[12] * a[2] * a[11] - a[12] * a[3] * a[10]
        inv[9] = -a[0] * a[9] * a[15] + a[0] * a[11] * a[13] + a[8] * a[1] * a[15]
            - a[8] * a[3] * a[13] - a[12] * a[1] * a[11] + a[12] * a[3] * a[9]
        inv[13] = a[0] * a[9] * a[14] - a[0] * a[10] * a[13] - a[8] * a[1] * a[14]
            + a[8] * a[2] * a[13] + a[12] * a[1] * a[10] - a[12] * a[2] * a[9]
        inv[2] = a[1] * a[6] * a[15] - a[1] * a[7] * a[14] - a[5] * a[2] * a[15]
            + a[5] * a[3] * a[14] + a[13] * a[2] * a[7] - a[13] * a[3] * a[6]
        inv[6] = -a[0] * a[6] * a[15] + a[0] * a[7] * a[14] + a[4] * a[2] * a[15]
            - a[4] * a[3] * a[14] - a[12] * a[2] * a[7] + a[12] * a[3] * a[6]
        inv[10] = a[0] * a[5] * a[15] - a[0] * a[7] * a[13] - a[4] * a[1] * a[15]
            + a[4] * a[3] * a[13] + a[12] * a[1] * a[7] - a[12] * a[3] * a[5]
        inv[14] = -a[0] * a[5] * a[14] + a[0] * a[6] * a[13] + a[4] * a[1] * a[14]
            - a[4] * a[2] * a[13] - a[12] * a[1] * a[6] + a[12] * a[2] * a[5]
        inv[3] = -a[1] * a[6] * a[11] + a[1] * a[7] * a[10] + a[5] * a[2] * a[11]
            - a[5] * a[3] * a[10] - a[9] * a[2] * a[7] + a[9] * a[3] * a[6]
        inv[7] = a[0] * a[6] * a[11] - a[0] * a[7] * a[10] - a[4] * a[2] * a[11]
            + a[4] * a[3] * a[10] + a[8] * a[2] * a[7] - a[8] * a[3] * a[6]
        inv[11] = -a[0] * a[5] * a[11] + a[0] * a[7] * a[9] + a[4] * a[1] * a[11]
            - a[4] * a[3] * a[9] - a[8] * a[1] * a[7] + a[8] * a[3] * a[5]
        inv[15] = a[0] * a[5] * a[10] - a[0] * a[6] * a[9] - a[4] * a[1] * a[10]
            + a[4] * a[2] * a[9] + a[8] * a[1] * a[6] - a[8] * a[2] * a[5]
        let det = a[0] * inv[0] + a[1] * inv[4] + a[2] * inv[8] + a[3] * inv[12]
        guard det != 0, det.isFinite else { return .identity }
        return Mat4(inv.map { $0 / det })
    }

    static func translation(_ t: Vec3) -> Mat4 {
        Mat4([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, t.x, t.y, t.z, 1])
    }

    static func scale(_ s: Double) -> Mat4 {
        Mat4([s, 0, 0, 0, 0, s, 0, 0, 0, 0, s, 0, 0, 0, 0, 1])
    }

    static func rotation(_ q: Quat) -> Mat4 {
        let (x, y, z, w) = (q.x, q.y, q.z, q.w)
        return Mat4([
            1 - 2 * (y * y + z * z), 2 * (x * y + z * w), 2 * (x * z - y * w), 0,
            2 * (x * y - z * w), 1 - 2 * (x * x + z * z), 2 * (y * z + x * w), 0,
            2 * (x * z + y * w), 2 * (y * z - x * w), 1 - 2 * (x * x + y * y), 0,
            0, 0, 0, 1,
        ])
    }
}

public struct Box3: Hashable, Sendable {
    public var min: Vec3, max: Vec3

    public init(min: Vec3, max: Vec3) {
        self.min = min
        self.max = max
    }
}

public struct RGB: Codable, Hashable, Sendable {
    public var r: Double, g: Double, b: Double // 0...1, quantised to n/255

    public init(r: Double, g: Double, b: Double) {
        self.r = RGB.quantise(r)
        self.g = RGB.quantise(g)
        self.b = RGB.quantise(b)
    }

    /// `"#rrggbb"`, with or without the `#`. Anything else reads as black.
    public init(hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        let value = digits.count == 6 ? UInt32(digits, radix: 16) : nil
        let v = value ?? 0
        self.init(
            r: Double((v >> 16) & 0xFF) / 255,
            g: Double((v >> 8) & 0xFF) / 255,
            b: Double(v & 0xFF) / 255
        )
    }

    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        let digits = text.hasPrefix("#") ? String(text.dropFirst()) : text
        guard digits.count == 6, UInt32(digits, radix: 16) != nil else {
            let message = "A colour is written \"#rrggbb\", not \"\(text)\"."
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: message))
        }
        self.init(hex: text)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }

    var hex: String {
        func byte(_ v: Double) -> String {
            let s = String(Int((v * 255).rounded()), radix: 16)
            return s.count == 1 ? "0" + s : s
        }
        return "#" + byte(r) + byte(g) + byte(b)
    }

    private static func quantise(_ v: Double) -> Double {
        (min(max(v, 0), 1) * 255).rounded() / 255
    }
}

public struct ShotCanvas: Codable, Hashable, Sendable {
    public var width: Int, height: Int
    public var aspect: Double {
        Double(width) / Double(height)
    }

    public var pixelSize: PixelSize {
        PixelSize(width: width, height: height)
    }

    /// Multiples of 32 within 64...2048.
    public var isValid: Bool {
        [width, height].allSatisfy { $0 % 32 == 0 && (64 ... 2048).contains($0) }
    }

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public static let portrait = ShotCanvas(width: 640, height: 1152)
    public static let presets: [ShotCanvas] = [
        ShotCanvas(width: 640, height: 1152),
        ShotCanvas(width: 768, height: 1344),
        ShotCanvas(width: 1152, height: 640),
        ShotCanvas(width: 1344, height: 768),
        ShotCanvas(width: 768, height: 768),
    ]
}

/// H3 runs at 24 fps on frame counts of the form 17k + 5.
public enum FrameGrid {
    public static let fps = 24
    public static let defaultFrameCount = 124
    public static let trainedRange = 124 ... 362

    private static let base = 5
    private static let step = 17

    public static func isValid(_ frameCount: Int) -> Bool {
        frameCount >= base && (frameCount - base) % step == 0
    }

    /// The nearest valid count, ties up, at least 5.
    public static func snap(_ frameCount: Int) -> Int {
        guard frameCount > base else { return base }
        let (k, rem) = (frameCount - base).quotientAndRemainder(dividingBy: step)
        return base + (rem * 2 >= step ? k + 1 : k) * step
    }

    /// The smallest valid count at or above `frameCount`.
    public static func snapUp(_ frameCount: Int) -> Int {
        guard frameCount > base else { return base }
        let (k, rem) = (frameCount - base).quotientAndRemainder(dividingBy: step)
        return base + (rem == 0 ? k : k + 1) * step
    }

    public static func time(ofFrame index: Int) -> Double {
        Double(index) / Double(fps)
    }

    /// The nearest frame, never below 0.
    public static func frame(atTime time: Double) -> Int {
        max(0, Int((time * Double(fps)).rounded()))
    }
}

public enum PrevisIDs {
    /// `<prefix>_<12 lowercase hex>`, random.
    public static func make(_ prefix: String) -> String {
        let hex = String(UInt64.random(in: 0 ..< (1 << 48)), radix: 16)
        return prefix + "_" + String(repeating: "0", count: 12 - hex.count) + hex
    }
}
