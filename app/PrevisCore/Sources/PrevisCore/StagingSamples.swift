import Foundation

// How the staging analysis looks at a frame, CONTRACTS section 5.8: sample points on each actor, seen or not
// through the camera past the set pieces and props.

/// What stands between a frame's camera and a point: the set pieces and props, which hide the actors behind them.
/// The pose and layout passes use it so a limb behind a table is not drawn in front of it.
public struct SightLines: Sendable {
    private let occluders: [Occluder]
    private let origin: Vec3

    public init(frame: SceneFrame) {
        occluders = frame.entities.filter { !$0.isActor }.flatMap(Occluder.all)
        origin = frame.camera.position
    }

    public var isEmpty: Bool {
        occluders.isEmpty
    }

    /// Whether a set piece or prop is in front of `point`, seen from the camera.
    public func isHidden(_ point: Vec3) -> Bool {
        occluders.contains { $0.hides(point, from: origin) }
    }
}

/// A set piece's or prop's part as something that can stand between the camera and a point.
struct Occluder: Sendable {
    let name: String
    let toLocal: Mat4
    let half: Vec3

    static func all(_ entity: EntityFrame) -> [Occluder] {
        entity.parts.map { part in
            let half: Vec3 = switch part.shape {
            case let .box(size), let .wedge(size): size * 0.5
            case let .cylinder(radius, height), let .cone(radius, height): Vec3(radius, height / 2, radius)
            case let .sphere(radius): Vec3(radius, radius, radius)
            case let .capsule(radius, length): Vec3(radius, length / 2 + radius, radius)
            }
            return Occluder(name: entity.name, toLocal: part.transform.inverse, half: half)
        }
    }

    /// Whether the part crosses the straight line from `origin` to `point`, short of the point itself.
    func hides(_ point: Vec3, from origin: Vec3) -> Bool {
        let from = toLocal.transform(origin), to = toLocal.transform(point)
        var enter = 0.0, leave = 0.995
        for (start, end, extent) in [(from.x, to.x, half.x), (from.y, to.y, half.y), (from.z, to.z, half.z)] {
            let delta = end - start
            if abs(delta) < 1e-12 {
                if abs(start) > extent { return false }
                continue
            }
            let a = (-extent - start) / delta, b = (extent - start) / delta
            enter = max(enter, min(a, b))
            leave = min(leave, max(a, b))
            if enter > leave { return false }
        }
        return true
    }
}

struct Analyst {
    let entity: EntityFrame
    let standIn: String
    let camera: CameraFrame
    let view: Mat4
    let toCamera: Quat
    let size: PixelSize
    let occluders: [Occluder]

    private enum Seen: Equatable {
        case visible(Point2)
        case outside(String)
        case hidden(String)
    }

    private func look(at point: Vec3) -> Seen {
        guard let pixel = camera.project(point, size: size) else { return .outside("near") }
        let width = Double(size.width), height = Double(size.height)
        if pixel.y > height { return .outside("bottom") }
        if pixel.y < 0 { return .outside("top") }
        if pixel.x < 0 { return .outside("left") }
        if pixel.x > width { return .outside("right") }
        if let occluder = occluders.first(where: { $0.hides(point, from: camera.position) }) {
            return .hidden(occluder.name)
        }
        return .visible(pixel)
    }

    func character() -> StagedCharacter {
        let points = Dictionary(
            entity.keypoints.map { ($0.name, $0.position) },
            uniquingKeysWith: { first, _ in first }
        )
        if let levels = Self.levels(points) {
            return person(levels: levels, points: points)
        }
        return thing()
    }

    /// Sample points at each height of a person, from the rig's keypoints.
    private static func levels(_ p: [KeypointName: Vec3]) -> [(BodyLevel, [Vec3])]? {
        guard let nose = p[.nose], let neck = p[.neck], let shoulderL = p[.leftShoulder],
              let shoulderR = p[.rightShoulder], let hipL = p[.leftHip], let hipR = p[.rightHip],
              let kneeL = p[.leftKnee], let kneeR = p[.rightKnee], let ankleL = p[.leftAnkle],
              let ankleR = p[.rightAnkle]
        else { return nil }
        func mix(_ a: Vec3, _ b: Vec3, _ t: Double) -> Vec3 {
            a + (b - a) * t
        }
        func row(_ t: Double) -> [Vec3] {
            let left = mix(shoulderL, hipL, t), right = mix(shoulderR, hipR, t)
            return [left, right, mix(left, right, 0.5)]
        }
        // The top of the head: one head-radius above the head's centre, along the neck. The ears sit on either
        // side of the centre; the nose is on the face, in front of it.
        var crown = neck + (nose - neck) * 1.6
        var head = nose
        if let earL = p[.leftEar], let earR = p[.rightEar] {
            head = (earL + earR) * 0.5
            crown = head + (head - neck).normalized * ((earL - earR).length / 2)
        }
        return [
            (.crown, [crown]),
            // The head's centre counts too: a face in profile at the frame's edge still shows its head.
            (.eyes, [p[.leftEye] ?? nose, p[.rightEye] ?? nose, nose, head]),
            (.neck, [neck]),
            (.chest, row(0.3)),
            (.waist, row(0.78)),
            (.hips, [hipL, hipR]),
            (.midThigh, [mix(hipL, kneeL, 0.5), mix(hipR, kneeR, 0.5)]),
            (.knees, [kneeL, kneeR]),
            (.shins, [mix(kneeL, ankleL, 0.5), mix(kneeR, ankleR, 0.5)]),
            (.feet, [ankleL, ankleR]),
        ]
    }

    private func person(levels: [(BodyLevel, [Vec3])], points: [KeypointName: Vec3]) -> StagedCharacter {
        var seen: [BodyLevel: [Seen]] = [:]
        var pixels: [Point2] = []
        var visibleCount = 0, total = 0
        for (level, samples) in levels {
            let results = samples.map(look)
            seen[level] = results
            total += results.count
            for case let .visible(pixel) in results {
                pixels.append(pixel)
                visibleCount += 1
            }
        }
        func shows(_ level: BodyLevel) -> Bool {
            seen[level]?.contains { if case .visible = $0 { true } else { false } } ?? false
        }
        let order = BodyLevel.allCases
        let first = order.first(where: shows)
        var lowest: BodyLevel?
        var cut: StagedCharacter.Cut?
        if let first {
            lowest = first
            for level in order where level > first {
                guard shows(level) else {
                    cut = Self.cut(seen[level] ?? [])
                    break
                }
                lowest = level
            }
        } else {
            cut = Self.cut(order.flatMap { seen[$0] ?? [] })
        }

        let crown = levels[0].1[0], neck = points[.neck] ?? crown
        let hipMid = ((points[.leftHip] ?? neck) + (points[.rightHip] ?? neck)) * 0.5
        let knee = points[.leftKnee] ?? hipMid, ankle = points[.leftAnkle] ?? knee
        // Limb lengths, so the stature doesn't shrink when the character sits or crouches.
        let stature = (crown - neck).length + (neck - hipMid).length
            + ((points[.leftHip] ?? hipMid) - knee).length + (knee - ankle).length + 0.08
        let centre = (crown + ankle) * 0.5
        let depth = max(-view.transform(centre).z, 1e-6)
        let span = 2 * depth * tan(camera.verticalFOV / 2)
        let pad = 0.12 * stature / span * Double(size.height)
        return StagedCharacter(
            entityID: entity.id,
            name: entity.name,
            standIn: standIn,
            isPerson: true,
            isVisible: first != nil,
            horizontal: horizontal(pixels, fallback: centre),
            depth: stature / span >= 1 ? .foreground : stature / span >= 0.45 ? .midground : .background,
            facing: facing(),
            lowest: lowest,
            crownVisible: shows(.crown),
            cut: cut,
            visibleFraction: total == 0 ? 0 : Double(visibleCount) / Double(total),
            headFraction: 0.135 * stature / span,
            bodyFraction: stature / span,
            distance: depth,
            box: box(pixels, pad: pad)
        )
    }

    /// Anything that isn't a person: a dragon, a horse, a labelled prop. Its bounds are sampled instead.
    private func thing() -> StagedCharacter {
        let low = entity.bounds.min, high = entity.bounds.max
        var samples: [Vec3] = []
        for x in [0.0, 0.5, 1.0] {
            for y in [0.0, 0.5, 1.0] {
                for z in [0.0, 0.5, 1.0] {
                    samples.append(Vec3(
                        low.x + (high.x - low.x) * x, low.y + (high.y - low.y) * y, low.z + (high.z - low.z) * z
                    ))
                }
            }
        }
        let results = samples.map(look)
        let pixels = results.compactMap { seen -> Point2? in
            if case let .visible(pixel) = seen { pixel } else { nil }
        }
        let centre = (low + high) * 0.5
        let depth = max(-view.transform(centre).z, 1e-6)
        let span = 2 * depth * tan(camera.verticalFOV / 2)
        let height = high.y - low.y
        return StagedCharacter(
            entityID: entity.id,
            name: entity.name,
            standIn: standIn,
            isPerson: false,
            isVisible: !pixels.isEmpty,
            horizontal: horizontal(pixels, fallback: centre),
            depth: height / span >= 1 ? .foreground : height / span >= 0.45 ? .midground : .background,
            facing: facing(),
            lowest: nil,
            crownVisible: true,
            cut: pixels.count == results.count ? nil : Self.cut(results.filter {
                if case .visible = $0 { false } else { true }
            }),
            visibleFraction: Double(pixels.count) / Double(results.count),
            headFraction: 0,
            bodyFraction: height / span,
            distance: depth,
            box: box(pixels, pad: 0)
        )
    }

    /// What a set of unseen samples has in common: something in front, or else an edge of the frame.
    private static func cut(_ results: [Seen]) -> StagedCharacter.Cut? {
        var names: [String] = []
        var edges: [String: Int] = [:]
        for result in results {
            switch result {
            case let .hidden(name): if !names.contains(name) { names.append(name) }
            case let .outside(edge): edges[edge, default: 0] += 1
            case .visible: break
            }
        }
        if !names.isEmpty { return .hidden(by: names) }
        guard let edge = edges.max(by: { $0.value < $1.value })?.key else { return nil }
        return .frame(edge == "near" ? "bottom" : edge)
    }

    private func horizontal(_ pixels: [Point2], fallback: Vec3) -> StagedCharacter.Horizontal {
        let width = Double(size.width)
        var x = camera.project(fallback, size: size)?.x ?? width / 2
        if let low = pixels.map(\.x).min(), let high = pixels.map(\.x).max() { x = (low + high) / 2 }
        let fraction = x / width
        return fraction < 0.38 ? .left : fraction > 0.62 ? .right : .centre
    }

    private func box(_ pixels: [Point2], pad: Double) -> StagedCharacter.Box? {
        guard let minX = pixels.map(\.x).min(), let maxX = pixels.map(\.x).max(),
              let minY = pixels.map(\.y).min(), let maxY = pixels.map(\.y).max()
        else { return nil }
        let width = Double(size.width), height = Double(size.height)
        let left = max(0, minX - pad), right = min(width, maxX + pad)
        let top = max(0, minY - pad * 0.3), bottom = min(height, maxY + pad * 0.3)
        return StagedCharacter.Box(
            x: left / width, y: top / height, width: (right - left) / width, height: (bottom - top) / height
        )
    }

    /// The facing in frame terms. In camera space +X is frame right and +Z points back at the camera.
    private func facing() -> StagedCharacter.Facing {
        let forward = toCamera.rotate(Vec3(-sin(entity.heading), 0, -cos(entity.heading)))
        let degrees = atan2(forward.x, forward.z) * 180 / .pi
        let right = degrees > 0
        switch abs(degrees) {
        case ..<25: return .camera
        case ..<65: return right ? .threeQuarterRight : .threeQuarterLeft
        case ..<115: return right ? .profileRight : .profileLeft
        case ..<155: return right ? .awayRight : .awayLeft
        default: return .away
        }
    }
}
