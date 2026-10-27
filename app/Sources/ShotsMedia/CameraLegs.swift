import Foundation
import PrevisCore

/// How the camera moves over one stretch of a shot, in MiniMax H3's motion vocabulary. Orbits keep Blockout's names:
/// `orbitLeft` circles counter-clockwise seen from above, as Blockout's "Orbit 90° Left" does
/// (`src/engine/camera-moves.ts`). `track` follows a moving subject. A positive roll turns the camera body
/// counter-clockwise as its operator, standing behind it, sees it.
/// In a leg's `also`, `track` means the move is made while following a travelling subject.
public enum CameraMove: String, Codable, Sendable, CaseIterable {
    case push, pull, truckLeft, truckRight, orbitLeft, orbitRight, craneUp, craneDown, track
    case panLeft, panRight, tiltUp, tiltDown, zoomIn, zoomOut, rollClockwise, rollCounterclockwise
    case `static`
}

public enum MoveSpeed: String, Codable, Sendable { case slow, medium, fast }

public enum MoveAmplitude: String, Codable, Sendable { case small, medium, large }

/// The rig's shake on top of the moves, as H3's "Shake Slightly" and "Shake Strongly".
public enum CameraShake: String, Codable, Sendable { case slight, strong }

/// Camera legs read from the evaluated camera, the one the clean video shows, rather than from the raw marks: the
/// evaluator has already shortened holds that run past the next mark, aimed an aim-locked camera and carried a
/// mounted one. Rig noise is left out of the moves and reported as shake. Around a travelling subject, which way the
/// camera goes relative to it is judged between the camera's own marks (see `direction`).
enum CameraLegs {
    struct Reading: Equatable {
        var legs: [PromptFacts.CameraLeg]
        var shake: CameraShake?
        var subjects: [EntityID] // what the camera aims at or rides with; empty for a free camera
    }

    /// What a merged stretch must reach to count as a move rather than a held frame.
    static let minimumTravel = 0.15 // metres
    /// A subject that goes less than this over a stretch is standing still there, as he does at a hold.
    static let standing = 0.0001 // metres
    static let minimumTurn = 5.0 * .pi / 180
    static let minimumZoom = log(1.1)
    /// A hold, or a small move, shorter than this between or around other moves is not worth naming.
    static let minimumHoldFrames = 6
    /// The longest stretch judged as one piece, so a path that bends or reverses between marks still shows.
    static let pieceFrames = 12

    static func read(scene: PrevisScene, shotID: ShotID, catalog: ContentCatalog) throws -> Reading {
        guard let index = scene.shots.firstIndex(where: { $0.id == shotID }) else {
            throw ShotsMediaError("Scene \"\(scene.name)\" has no shot \(shotID).")
        }
        let shot = scene.shots[index]
        var quiet = scene
        quiet.shots[index].camera.rigIntensity = 0
        let evaluator = try ShotEvaluator(scene: quiet, shotID: shotID, catalog: catalog)
        let subjects = referenceSubjects(of: shot.camera, in: scene)
        let frames = (0 ..< evaluator.frameCount).map { evaluator.frame($0) }
        let mounted = shot.camera.rig == .carMount && subjects.count == 1 && subjects.first == shot.camera.mountID
        let headings = facings(of: subjects, in: frames)
        let cuts = Self.cuts(of: shot, in: scene, subjects: subjects, last: frames.count - 1)
        let samples = zip(frames, headings).enumerated().map { index, sample in
            Sample(
                camera: sample.0.camera, subject: centre(of: subjects, in: sample.0), heading: sample.1,
                mounted: mounted, jumped: cuts.jumps.contains(index)
            )
        }
        var spans: [Span] = []
        let references = Self.references(cuts, samples: samples)
        let runs = movingRuns(cuts.stretches, samples: samples)
        for (stretch, reference) in zip(cuts.stretches, references) {
            let run = runs.first { $0.from <= stretch.from && stretch.to <= $0.to } ?? stretch
            let travels = travelling(stretch, in: run, samples: samples, free: subjects.isEmpty)
            // A jump to a mark at the same time is a cut in the picture, not a move.
            if stretch.to == stretch.from + 1, samples[stretch.to].jumped {
                append(Span(from: stretch.from, to: stretch.to), to: &spans)
                continue
            }
            for (from, to) in pieces(of: stretch) {
                let span = reference ?? Span(from: from, to: to)
                let move = direction(
                    samples[from ... to], within: samples[span.from ... span.to], keyed: reference != nil,
                    travels: travels
                )
                append(Span(from: from, to: to, move: move), to: &spans)
            }
        }
        spans = settled(spans, legs: cuts.legs, samples: samples)
        return try Reading(
            legs: spans.map { leg($0, samples: samples) },
            shake: shake(scene: scene, shotID: shotID, catalog: catalog, quiet: samples),
            subjects: subjects
        )
    }

    // MARK: Pieces

    struct Sample {
        var camera: CameraFrame
        var subject: Vec3? // the subject the camera is built around, on the ground; nil without one
        var heading: Double? // that subject's facing, when it is a single one
        var mounted: Bool // riding the subject, which turns the camera with it
        var jumped = false // reached across a jump from the frame before

        /// The camera's place relative to the subject, as the world sees it.
        var offset: Vec3? {
            subject.map { Vec3(camera.position.x - $0.x, camera.position.y - $0.y, camera.position.z - $0.z) }
        }

        /// The same in the subject's own frame, when it has a facing.
        var localOffset: Vec3? {
            guard let offset, let heading else { return nil }
            // Undo the subject's yaw: heading 0 faces −Z, and positive headings turn toward −X.
            let c = cos(heading), s = sin(heading)
            return Vec3(offset.x * c - offset.z * s, offset.y, offset.x * s + offset.z * c)
        }
    }

    /// The camera's offsets from the subject at two samples, in the frame where they change less: the subject's own
    /// for a camera kept behind a turning walker, and always for a car mount; the world's for a camera that keeps its
    /// world bearing as the subject turns, as Blockout's push and orbit presets do.
    /// Given `local`, in that frame instead.
    private static func offsets(_ a: Sample, _ b: Sample, local: Bool? = nil) -> (before: Vec3, after: Vec3)? {
        guard let before = a.offset, let after = b.offset else { return nil }
        guard let localBefore = a.localOffset, let localAfter = b.localOffset else { return (before, after) }
        return (local ?? ownFrame(a, b)) ? (localBefore, localAfter) : (before, after)
    }

    /// Whether the offsets at two samples are read in the subject's own frame (see `offsets`).
    private static func ownFrame(_ a: Sample, _ b: Sample) -> Bool {
        guard let before = a.offset, let after = b.offset, let localBefore = a.localOffset,
              let localAfter = b.localOffset
        else { return false }
        return a.mounted || length(difference(localAfter, localBefore)) < length(difference(after, before))
    }

    struct Span {
        var from: Int, to: Int, move: CameraMove = .static
    }

    /// The aim-locked subjects, or else the vehicle a car-mounted camera rides; none for a free camera.
    private static func referenceSubjects(of camera: ShotCamera, in scene: PrevisScene) -> [EntityID] {
        let present = Set(scene.entities.map(\.id))
        let aimed = camera.trackIDs.filter(present.contains)
        if !aimed.isEmpty { return aimed }
        if camera.rig == .carMount, let mount = camera.mountID, present.contains(mount) { return [mount] }
        return []
    }

    /// A single subject lends its facing, so the camera's place can be judged in the subject's own frame. When the
    /// evaluator snaps an aimed subject to a new facing, the frame jumps with it, and `offsets` keeps to the world's.
    private static func facings(of subjects: [EntityID], in frames: [SceneFrame]) -> [Double?] {
        guard subjects.count == 1 else { return frames.map { _ in nil } }
        return frames.map { frame in frame.entities.first { $0.id == subjects[0] }?.heading }
    }

    private static func centre(of subjects: [EntityID], in frame: SceneFrame) -> Vec3? {
        let positions = frame.entities.filter { subjects.contains($0.id) }.map(\.position)
        guard !positions.isEmpty else { return nil }
        let count = Double(positions.count)
        return Vec3(
            positions.map(\.x).reduce(0, +) / count,
            positions.map(\.y).reduce(0, +) / count,
            positions.map(\.z).reduce(0, +) / count
        )
    }

    /// Neighbouring stretches in which the camera keeps moving at a like pace, joined: within a quarter of each
    /// other's speed, so a 3 cm drift beside a 1 m push stays apart. A stretch where it stands still is a run of its
    /// own.
    private static func movingRuns(_ stretches: [Span], samples: [Sample]) -> [Span] {
        var runs: [Span] = [], last: Double?
        for stretch in stretches {
            let speed = pathLength(stretch, samples: samples) / Double(max(stretch.to - stretch.from, 1))
            let moves = pathLength(stretch, samples: samples) >= 0.005
            if moves, let pace = last, min(pace, speed) >= max(pace, speed) / 4, let index = runs.indices.last {
                runs[index].to = stretch.to
            } else {
                runs.append(stretch)
            }
            last = moves ? speed : nil
        }
        return runs
    }

    /// Whether the camera travels over a stretch, or is planted there and pans, tilts, zooms or rolls however it
    /// drifts. It travels when its path over the run of moving stretches is enough to name, so a push keyed with
    /// close marks still counts; when its path over the stretch itself is a real share, a quarter, of its subject's
    /// travel; and, for a free camera, when over the stretch that path outweighs its pan and tilt, each in units of
    /// the least that names a move, or it circles something at least half a metre away. Zoom and roll ride on a
    /// move, so they don't count against it. An aimed camera's pan and tilt come from where it goes, so they don't
    /// count either.
    private static func travelling(_ stretch: Span, in run: Span, samples: [Sample], free: Bool) -> Bool {
        let path = pathLength(stretch, samples: samples)
        guard pathLength(run, samples: samples) >= minimumTravel,
              path >= subjectTravel(stretch, samples: samples) / 4
        else { return false }
        guard free else { return true }
        // Between two marks a free camera turns one way, so the net turn is the whole of it.
        let first = samples[stretch.from].camera, last = samples[stretch.to].camera
        let panned = zip(samples[stretch.from ..< stretch.to], samples[stretch.from + 1 ... stretch.to]).reduce(0) {
            $0 + Self.panned($1.0.camera, $1.1.camera)
        }
        let move = difference(last.position, first.position), tilted = abs(last.tilt - first.tilt) / minimumTurn
        let along = -move.x * sin(first.pan) * cos(first.tilt) + move.y * sin(first.tilt)
            - move.z * cos(first.pan) * cos(first.tilt)
        let lateral = move.x * cos(first.pan) - move.z * sin(first.pan)
        // Circling something: a mostly sideways move whose pan turns back toward a point at least half a metre off.
        // Its pan comes from the circling, so only its tilt is weighed against its travel.
        if panned != 0, abs(lateral) > max(abs(along), abs(move.y)), (lateral > 0) == (panned > 0),
           abs(lateral) / abs(panned) >= 0.5 {
            return path / minimumTravel >= tilted
        }
        return path / minimumTravel >= max(abs(panned) / minimumTurn, tilted)
    }

    /// A stretch in pieces at most `pieceFrames` long.
    private static func pieces(of stretch: Span) -> [(Int, Int)] {
        let count = max(Int((Double(stretch.to - stretch.from) / Double(pieceFrames)).rounded(.up)), 1)
        let cuts = (0 ... count).map { stretch.from + ($0 * (stretch.to - stretch.from)) / count }
        return Array(zip(cuts, cuts.dropFirst()))
    }

    private static func append(_ span: Span, to spans: inout [Span]) {
        if let index = spans.indices.last, spans[index].move == span.move {
            spans[index].to = span.to
        } else {
            spans.append(span)
        }
    }

    // MARK: Direction of one piece

    /// The way the camera goes over one piece, however little: by its travel when its stretch `travels`, relative to
    /// the reference subject when there is one; otherwise by its turn, zoom or roll. The relative move is the one
    /// from the start of `span` to its end. Around a subject standing still that is the piece itself. Around one on
    /// the move it is `keyed`: it runs between two of the camera's marks, where camera and subject are both where
    /// they were put, and names a move only if the change between them is enough to name. In between, the camera's
    /// easing and his, his stops and starts, his snap onto a new heading at his marks and the curve of either path
    /// make the camera lag and catch up, and that isn't a move.
    private static func direction(
        _ piece: ArraySlice<Sample>, within span: ArraySlice<Sample>, keyed: Bool, travels: Bool
    ) -> CameraMove {
        guard let a = piece.first, let b = piece.last, let start = span.first, let end = span.last else {
            return .static
        }
        let move = difference(b.camera.position, a.camera.position)
        guard travels, length(move) >= 0.005 else { return turning(a, b) }
        guard let (before, after) = offsets(start, end) else { return free(move, from: a.camera, to: b.camera) }
        // Passing over or under the subject anywhere in the span makes its azimuth meaningless. Otherwise the way
        // round is summed step by step, in the frame the ends are read in, so half a turn or more keeps its way round.
        let local = ownFrame(start, end)
        let swept = span.contains { $0.offset.map(overhead) ?? false } ? 0
            : zip(span.dropLast(), span.dropFirst()).reduce(0) { total, step in
                offsets(step.0, step.1, local: local)
                    .map { total + turn(azimuth($0.before), azimuth($0.after)) } ?? total
            }
        let least = keyed ? minimumTravel : 0.005
        if let named = relative(
            before, after, swept: swept, rise: cameraRise(span), least: least
        ) { return named }
        // Passing straight across the subject can end at the same radius without being a follow.
        return hypot(after.x - before.x, after.z - before.z) >= least
            ? free(move, from: a.camera, to: b.camera) : .track
    }

    /// The planted camera's largest change, in units of the least that names a move, so a turn and a zoom compare;
    /// static when every change is a fiftieth of that or less.
    private static func turning(_ start: Sample, _ end: Sample) -> CameraMove {
        let a = start.camera, b = end.camera
        let changes: [(CameraMove, CameraMove, Double)] = [
            (.panLeft, .panRight, panned(a, b) / minimumTurn),
            (.tiltUp, .tiltDown, (b.tilt - a.tilt) / minimumTurn),
            (.zoomIn, .zoomOut, log(b.focalLength / a.focalLength) / minimumZoom),
            (.rollCounterclockwise, .rollClockwise, rolled(start, end) / minimumTurn),
        ]
        guard let largest = changes.max(by: { abs($0.2) < abs($1.2) }), abs(largest.2) >= 0.02 else { return .static }
        return largest.2 > 0 ? largest.0 : largest.1
    }

    /// Without a subject: travel along the view is a push or pull, upward or downward is a crane, and sideways is a
    /// truck, or an orbit when the camera turns back toward where it came from by as much as circling something
    /// within 30 m would. Moving right while turning left circles counter-clockwise seen from above, Blockout's orbit
    /// left.
    private static func free(_ move: Vec3, from camera: CameraFrame, to end: CameraFrame) -> CameraMove {
        // Positive pan turns left and positive tilt looks up; the camera looks down its local −Z.
        let along = -move.x * sin(camera.pan) * cos(camera.tilt) + move.y * sin(camera.tilt)
            - move.z * cos(camera.pan) * cos(camera.tilt)
        let lateral = move.x * cos(camera.pan) - move.z * sin(camera.pan)
        if abs(move.y) >= abs(along), abs(move.y) >= abs(lateral) { return move.y > 0 ? .craneUp : .craneDown }
        guard abs(lateral) > abs(along) else { return along > 0 ? .push : .pull }
        let pan = turn(camera.pan, end.pan)
        if abs(pan) >= max(0.02 * minimumTurn, abs(lateral) / 30), (lateral > 0) == (pan > 0) {
            return lateral > 0 ? .orbitLeft : .orbitRight
        }
        return lateral > 0 ? .truckRight : .truckLeft
    }

    /// Horizontal camera motion relative to the subject distinguishes orbit and push/pull. A crane uses the
    /// camera's actual world-height change: a rising subject cannot pedestal a level camera, and a camera
    /// rising alongside its subject still cranes even when their relative height is constant.
    private static func relative(
        _ before: Vec3,
        _ after: Vec3,
        swept: Double,
        rise: Double,
        least: Double
    ) -> CameraMove? {
        let radius = (hypot(before.x, before.z) + hypot(after.x, after.z)) / 2
        // A pedestal is camera motion in world height, not the subject rising under a level camera.
        // Horizontal separation names push/pull independently of either height.
        let arc = abs(swept) * radius, radial = hypot(after.x, after.z) - hypot(before.x, before.z)
        guard max(abs(radial), abs(rise), arc) >= least else { return nil }
        if arc >= abs(radial), arc >= abs(rise) { return swept > 0 ? .orbitLeft : .orbitRight }
        if abs(rise) >= 0.8 * abs(radial) { return rise > 0 ? .craneUp : .craneDown }
        return radial < 0 ? .push : .pull
    }

    // MARK: Spans

    /// Moves too small to name fall back to what the camera still does (see `fallback`); then brief spans not worth
    /// naming join the span before them (or after, at the start), and neighbours with the same move join.
    private static func settled(_ spans: [Span], legs: Set<ClosedRange<Int>>, samples: [Sample]) -> [Span] {
        var quieted: [Span] = []
        for var span in spans {
            if span.move != .static, amount(of: span, samples: samples) < threshold(span.move) {
                span.move = fallback(span, path: pathLength(span, samples: samples), samples: samples)
            }
            append(span, to: &quieted)
        }
        var result: [Span] = []
        var index = 0
        while index < quieted.count {
            let span = quieted[index]
            // A brief hold or a brief small move isn't worth naming; a brief large one is a snap and stays. A move
            // of the camera's place is a snap only if the camera itself travels far, not just a subject outrunning
            // it. A move filling one of the camera's own legs, with no travelling subject to account for it, was put
            // there, and stays however brief. Only a span with a neighbour to join is dropped, so the shot always
            // keeps at least one leg.
            let small = amount(of: span, samples: samples) < 3 * threshold(span.move)
            let slight = switch span.move {
            case .static: true
            case _ where legs.contains(span.from ... span.to) && subjectTravel(span, samples: samples) < standing:
                false
            case .panLeft, .panRight, .tiltUp, .tiltDown, .zoomIn, .zoomOut, .rollClockwise, .rollCounterclockwise:
                small
            default: small || pathLength(span, samples: samples) < 3 * minimumTravel
            }
            if span.to - span.from < minimumHoldFrames, slight, let previous = result.indices.last {
                result[previous].to = span.to
            } else if span.to - span.from < minimumHoldFrames, slight, index + 1 < quieted.count {
                quieted[index + 1].from = span.from
            } else {
                append(span, to: &result)
            }
            index += 1
        }
        return result
    }

    /// A move too small to name becomes a track when the camera travels with a travelling subject, as much as a
    /// quarter of its way, and a hold when it doesn't; with a subject standing still, or none, a truck, push, pull or
    /// crane when the camera's own travel is enough to name, read without the subject; or else a hold.
    private static func fallback(_ span: Span, path: Double, samples: [Sample]) -> CameraMove {
        guard path >= minimumTravel, span.move != .track else { return .static }
        // Beside a travelling subject the camera either keeps up with it, a track, or barely moves, a hold: its own
        // creep isn't a push or pull, which would be measured by how far the subject came or went.
        let followed = subjectTravel(span, samples: samples)
        if samples[span.from].subject != nil, followed >= minimumTravel {
            return path >= followed / 4 ? .track : .static
        }
        let first = samples[span.from].camera, last = samples[span.to].camera
        switch free(difference(last.position, first.position), from: first, to: last) {
        // Its turn was already too small to name, so this is a truck.
        case .orbitLeft: return .truckRight
        case .orbitRight: return .truckLeft
        case let move: return move
        }
    }

    private enum Measure { case travel, angle, zoom }

    private static func measure(_ move: CameraMove) -> Measure {
        switch move {
        case .push, .pull, .truckLeft, .truckRight, .craneUp, .craneDown, .track, .static: .travel
        case .orbitLeft, .orbitRight, .panLeft, .panRight, .tiltUp, .tiltDown, .rollClockwise,
             .rollCounterclockwise: .angle
        case .zoomIn, .zoomOut: .zoom
        }
    }

    private static func threshold(_ move: CameraMove) -> Double {
        switch measure(move) {
        case .travel: minimumTravel
        case .angle: minimumTurn
        case .zoom: minimumZoom
        }
    }

    /// How far a span goes in its own measure: camera path, horizontal subject separation, or actual camera
    /// height; radians swept or turned; or the log of the lens ratio. Jumps do not add crane distance.
    private static func amount(of span: Span, samples: [Sample]) -> Double {
        let steps = zip(samples[span.from ..< span.to], samples[span.from + 1 ... span.to])
        let first = samples[span.from].camera, last = samples[span.to].camera
        switch span.move {
        case .craneUp, .craneDown:
            return abs(cameraRise(samples[span.from ... span.to]))
        case .push, .pull:
            guard let (before, after) = offsets(samples[span.from], samples[span.to]) else {
                return pathLength(span, samples: samples)
            }
            return abs(hypot(after.x, after.z) - hypot(before.x, before.z))
        case .truckLeft, .truckRight, .track:
            return pathLength(span, samples: samples)
        case .orbitLeft, .orbitRight:
            return abs(steps.reduce(0) { total, step in
                guard let (before, after) = offsets(step.0, step.1) else {
                    return total + turn(step.0.camera.pan, step.1.camera.pan)
                }
                return overhead(before) || overhead(after) || step.1.jumped
                    ? total : total + turn(azimuth(before), azimuth(after))
            })
        case .panLeft, .panRight: return abs(steps.reduce(0) { $0 + panned($1.0.camera, $1.1.camera) })
        case .tiltUp, .tiltDown: return abs(last.tilt - first.tilt)
        case .rollClockwise, .rollCounterclockwise:
            return abs(steps.reduce(0) { $0 + rolled($1.0, $1.1) })
        case .zoomIn, .zoomOut: return abs(log(last.focalLength / first.focalLength))
        case .static: return 0
        }
    }

    private static func leg(_ span: Span, samples: [Sample]) -> PromptFacts.CameraLeg {
        let first = samples[span.from].camera, last = samples[span.to].camera
        var also: [CameraMove] = []
        // A move relative to a subject that is itself travelling also follows it.
        let followed = subjectTravel(span, samples: samples)
        if [.orbitLeft, .orbitRight, .push, .pull, .craneUp, .craneDown].contains(span.move),
           followed >= minimumTravel, pathLength(span, samples: samples) >= followed / 2 {
            also.append(.track)
        }
        // The roll, with a free camera's spin from panning when it looks straight down or up, as `amount` measures it.
        let zoom = log(last.focalLength / first.focalLength)
        let roll = zip(samples[span.from ..< span.to], samples[span.from + 1 ... span.to]).reduce(0) {
            $0 + rolled($1.0, $1.1)
        }
        if measure(span.move) != .zoom, span.move != .static, abs(zoom) >= minimumZoom {
            also.append(zoom > 0 ? .zoomIn : .zoomOut)
        }
        if ![.rollClockwise, .rollCounterclockwise, .static].contains(span.move), abs(roll) >= minimumTurn {
            also.append(roll > 0 ? .rollCounterclockwise : .rollClockwise)
        }
        let (speed, amplitude): (MoveSpeed, MoveAmplitude)
        if span.move == .static {
            (speed, amplitude) = (.medium, .medium)
        } else {
            let done = amount(of: span, samples: samples), seconds = moving(span, samples: samples)
            switch measure(span.move) {
            case .travel: (speed, amplitude) = (grade(done / seconds, 0.4, 1.2), size(done, 0.75, 3))
            case .angle: (speed, amplitude) = (grade(done / seconds, 0.25, 0.8), size(done, .pi / 12, .pi / 3))
            case .zoom: (speed, amplitude) = (grade(done / seconds, 0.15, 0.5), size(done, log(1.3), log(2)))
            }
        }
        return PromptFacts.CameraLeg(
            fromFrame: span.from, toFrame: span.to, move: span.move, speed: speed, amplitude: amplitude, also: also,
            focalLength: [first.focalLength, last.focalLength]
        )
    }

    /// The span's seconds without the frames at either end where the camera hasn't started or has already stopped,
    /// so a move squeezed into the end of a long hold reads as fast.
    private static func moving(_ span: Span, samples: [Sample]) -> Double {
        var start = span.from, end = span.to
        while start < end, same(samples[start + 1].camera, samples[span.from].camera) {
            start += 1
        }
        while end > start, same(samples[end - 1].camera, samples[span.to].camera) {
            end -= 1
        }
        return Double(max(end - start, 1)) / Double(FrameGrid.fps)
    }

    private static func same(_ a: CameraFrame, _ b: CameraFrame) -> Bool {
        length(difference(a.position, b.position)) < 1e-4 && abs(turn(a.pan, b.pan)) < 1e-5
            && abs(a.tilt - b.tilt) < 1e-5 && abs(turn(a.roll, b.roll)) < 1e-5
            && abs(log(a.focalLength / b.focalLength)) < 1e-5
    }

    private static func grade(_ rate: Double, _ slow: Double, _ fast: Double) -> MoveSpeed {
        rate < slow ? .slow : rate >= fast ? .fast : .medium
    }

    private static func size(_ amount: Double, _ small: Double, _ large: Double) -> MoveAmplitude {
        amount < small ? .small : amount >= large ? .large : .medium
    }

    // MARK: Shake

    /// The rig noise's largest turn away from the quiet camera: strong from about half a degree, which handheld
    /// reaches at half intensity, and slight from a sixth of a degree.
    private static func shake(
        scene: PrevisScene,
        shotID: ShotID,
        catalog: ContentCatalog,
        quiet: [Sample]
    ) throws -> CameraShake? {
        guard let shot = scene.shots.first(where: { $0.id == shotID }), shot.camera.rigIntensity > 0 else {
            return nil
        }
        let noisy = try ShotEvaluator(scene: scene, shotID: shotID, catalog: catalog)
        let largest = stride(from: 0, to: quiet.count, by: 2).reduce(0.0) { largest, index in
            let shaken = noisy.frame(index).camera, still = quiet[index].camera
            return max(
                largest,
                abs(turn(still.pan, shaken.pan)),
                abs(shaken.tilt - still.tilt),
                abs(turn(still.roll, shaken.roll))
            )
        }
        return largest >= 0.009 ? .strong : largest >= 0.003 ? .slight : nil
    }

    // MARK: Geometry

    static func difference(_ a: Vec3, _ b: Vec3) -> Vec3 {
        Vec3(a.x - b.x, a.y - b.y, a.z - b.z)
    }

    static func length(_ v: Vec3) -> Double {
        (v.x * v.x + v.y * v.y + v.z * v.z).squareRoot()
    }

    /// The heading from the subject to the camera: 0 when the camera is on the subject's −Z side, growing
    /// counter-clockwise seen from above, as Blockout's orbit azimuth does.
    private static func azimuth(_ offset: Vec3) -> Double {
        atan2(-offset.x, -offset.z)
    }

    /// Nearly above or below the subject, where its azimuth swings wildly with no visible orbit.
    private static func overhead(_ offset: Vec3) -> Bool {
        hypot(offset.x, offset.z) < 0.1 * length(offset)
    }

    /// A pan turns the camera about the world's vertical. Tilted, part of that swings the view (this, the pan times
    /// the cosine of the tilt) and the rest spins the picture about the lens like a roll (`rolled`): looking straight
    /// down, a pan is all spin.
    private static func panned(_ a: CameraFrame, _ b: CameraFrame) -> Double {
        turn(a.pan, b.pan) * cos((a.tilt + b.tilt) / 2)
    }

    /// The roll about the lens, with the spin a tilted pan adds when the picture really turns about a point in it:
    /// a free camera whose view holds the point straight below or above it. The camera's local +Z, about which a
    /// positive roll turns, points up the world's vertical by minus the sine of the tilt. An aimed camera's pan, which
    /// swings wildly over a subject below it, adds nothing.
    private static func rolled(_ start: Sample, _ end: Sample) -> Double {
        let a = start.camera, b = end.camera, tilt = (a.tilt + b.tilt) / 2
        let spins = start.subject == nil && .pi / 2 - abs(tilt) < (a.verticalFOV + b.verticalFOV) / 4
        return turn(a.roll, b.roll) - (spins ? turn(a.pan, b.pan) * sin(tilt) : 0)
    }

    /// The signed change from `a` to `b` the short way round.
    private static func turn(_ a: Double, _ b: Double) -> Double {
        remainder(b - a, 2 * .pi)
    }
}
