import Foundation
import PrevisCore
@testable import ShotsMedia
import Testing

/// Blockout's camera-move presets as its own engine generated them (`golden-vectors.v1.json`, the file A4's
/// vector tests read through `PREVIS_VECTORS`), each played around the subject Blockout built it for.
@Suite(
    "camera legs against Blockout's presets",
    .enabled(if: ProcessInfo.processInfo.environment["PREVIS_VECTORS"] != nil)
)
struct CameraLegOracleTests {
    /// The move each preset is named for, read around a standing and a walking subject. Moves Blockout names after
    /// the path rather than the framing (boom-over, flyover, drone-strafe-reveal) are left to the structural check.
    static let named: [String: CameraMove] = [
        "slow-push-in": .push, "crash-in": .push, "creep-in-low": .push, "pull-back-reveal": .pull,
        "drone-rise-pullback": .pull, "orbit-90-left": .orbitLeft, "orbit-90-right": .orbitRight,
        "orbit-180": .orbitLeft, "orbit-360": .orbitLeft, "arc-and-push": .orbitLeft, "orbit-45-low": .orbitLeft,
        "orbit-45-high": .orbitLeft, "spiral-in-descend": .orbitLeft, "spiral-out-ascend": .orbitLeft,
        "drone-orbit-high": .orbitLeft, "dutch-orbit": .orbitLeft, "side-dolly-past": .orbitLeft,
        "crane-up-reveal": .craneUp, "pedestal-up": .craneUp, "pedestal-up-slow": .craneUp,
        "crane-down-intro": .craneDown, "top-down-descend": .craneDown, "static-pan-across": .panLeft,
        "slow-tilt-reveal": .tiltUp, "vertigo-dolly-zoom": .push, "push-in-dutch-roll": .push,
    ]
    /// Blockout's "follow" presets ride with the subject: a track around a walking one, nothing at all around one
    /// that stands still.
    static let following: Set = [
        "follow-behind", "lead-the-subject", "side-track-left", "side-track-right", "lead-follow-front",
        "low-lead-tilt-up", "overhead-track-follow",
    ]

    @Test func everyPresetReadsAsItsName() throws {
        let catalog = try ContentCatalog.bundled()
        for vector in try Self.vectors().camera {
            let facts = try Self.facts(vector, catalog: catalog)
            let legs = facts.cameraLegs, label = "\(vector.id) \(vector.subject) \(vector.duration) s: \(legs)"
            // Every reading covers the shot in order, with no two neighbours alike and no sliver of a hold.
            #expect(legs.first?.fromFrame == 0 && legs.last?.toFrame == facts.frameCount - 1, "\(label)")
            for (before, after) in zip(legs, legs.dropFirst()) {
                #expect(before.toFrame == after.fromFrame && before.move != after.move, "\(label)")
            }
            #expect(legs.count == 1 || legs.allSatisfy { $0.move != .static || $0.toFrame - $0.fromFrame >= 6 })
            // Over the flying subject, aim lock's swings straight above it are no roll.
            if vector.subject == "fly", ["top-down-descend", "overhead-track-follow"].contains(vector.id) {
                #expect(!legs.contains { [.rollClockwise, .rollCounterclockwise].contains($0.move) }, "\(label)")
            }
            // Around the 12 m/s flying subject, the camera's eased start isn't a move of its own.
            if vector.subject == "fly", vector.duration == 3,
               ["crane-up-reveal", "vertigo-dolly-zoom"].contains(vector.id) {
                #expect(legs.map(\.move) == [.track], "\(label)")
            }
            guard vector.subject != "fly" else { continue }
            let dominant = legs.max { $0.toFrame - $0.fromFrame < $1.toFrame - $1.fromFrame }
            if let move = Self.named[vector.id] {
                #expect(dominant?.move == move, "\(label)")
                // Around a walking subject a move relative to it also follows it; around a standing one it doesn't.
                if [.push, .pull, .orbitLeft, .orbitRight, .craneUp, .craneDown].contains(move) {
                    #expect(dominant?.also.contains(.track) == (vector.subject == "walk"), "\(label)")
                }
            }
            // Passing over or past a subject is a push then a pull, never an arc round it.
            if ["flyover", "drone-strafe-reveal", "boom-over"].contains(vector.id) {
                #expect(!legs.contains { [.orbitLeft, .orbitRight].contains($0.move) }, "\(label)")
            }
            if Self.following.contains(vector.id) {
                #expect(legs.map(\.move) == [vector.subject == "walk" ? .track : .static], "\(label)")
            }
        }
    }

    @Test func zoomsRollsAndWhipsReadAsBlockoutDescribesThem() throws {
        let catalog = try ContentCatalog.bundled()
        for vector in try Self.vectors().camera {
            let legs = try Self.facts(vector, catalog: catalog).cameraLegs, label = "\(vector.id): \(legs)"
            if vector.subject == "fly", vector.id != "whip-pan" { continue }
            switch vector.id {
            case "whip-pan":
                // "Hold on the subject, then a violent 90° pan in ~0.4s mid-shot, then settle."
                #expect(legs.map(\.move) == [.static, .panLeft, .static], "\(label)")
                // Level, the pan swings the view 90°; tilted up 60° at the flying subject, about 41°.
                let swing: MoveAmplitude = vector.subject == "fly" ? .medium : .large
                #expect(legs.dropFirst().first.map { $0.speed == .fast && $0.amplitude == swing } == true, "\(label)")
            case "snap-zoom-punch", "crash-zoom-out":
                let zoom: CameraMove = vector.id == "snap-zoom-punch" ? .zoomIn : .zoomOut
                #expect(
                    legs.map(\.move) == [.static, zoom, .static] && legs.dropFirst().first?.speed == .fast,
                    "\(label)"
                )
            case "vertigo-dolly-zoom":
                // "Push in while the lens widens so the subject stays the same size."
                #expect(legs.count == 1 && legs.first?.also.contains(.zoomOut) == true, "\(label)")
            case "dutch-orbit", "push-in-dutch-roll":
                #expect(legs.count == 1 && legs.first?.also.contains(.rollCounterclockwise) == true, "\(label)")
            case "slow-tilt-reveal":
                #expect(legs.map(\.speed) == [.slow], "\(label)")
            default:
                break
            }
        }
    }

    private static func vectors() throws -> GoldenVectors {
        let path = try #require(ProcessInfo.processInfo.environment["PREVIS_VECTORS"])
        return try JSONDecoder().decode(GoldenVectors.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    }

    private static func facts(_ vector: GoldenVectors.Camera, catalog: ContentCatalog) throws -> PromptFacts {
        let scene = presetScene(vector, track: catalog.cameraMoves.first { $0.id == vector.id }?.track ?? false)
        return try ShotPromptCompiler.facts(scene: scene, shotID: scene.shots[0].id, catalog: catalog)
    }
}

/// The subjects Blockout's extraction built its vectors around: standing at the origin, walking down −Z at
/// 1.4 m/s, or flying 5 m tall along (3t, 8 + sin t, −12t).
func presetScene(_ vector: GoldenVectors.Camera, track: Bool) -> PrevisScene {
    let subjectID = "ent_subject"
    let frameCount = FrameGrid.snapUp(Int((vector.duration * Double(FrameGrid.fps)).rounded()) + 1)
    var scene = PrevisScene.make(
        id: "scene_oracle", name: vector.id, takeID: "take_oracle", shotID: "shot_oracle", cameraMarkID: "cam_0"
    )
    let flying = vector.subject == "fly"
    scene.entities = [PrevisEntity(
        id: subjectID,
        assetID: flying ? "animal.bird" : "person.man",
        name: "Subject",
        placement: Placement(position: .zero, heading: 0, scale: flying ? 5 / 0.25 : 1.75 / 1.78)
    )]
    func at(_ time: Double) -> Vec3 {
        switch vector.subject {
        case "walk": Vec3(0, 0, -1.4 * time)
        case "fly": Vec3(3 * time, 8 + sin(time), -12 * time)
        default: .zero
        }
    }
    let times: [Double] = switch vector.subject {
    case "walk": [0, vector.duration]
    case "fly": (0 ... Int(vector.duration * 24)).map { Double($0) / 24 }
    default: []
    }
    scene.blocking[0].tracks = times.isEmpty ? [] : [Track(entityID: subjectID, marks: times.enumerated().map {
        ActorMark(
            id: "m\($0.offset)", time: $0.element, hold: 0, easeIn: 0, easeOut: 0, position: at($0.element),
            gait: flying ? .stand : .walk
        )
    })]
    scene.shots[0].frameCount = frameCount
    scene.shots[0].camera.trackIDs = track ? [subjectID] : []
    scene.shots[0].camera.marks = vector.marks.enumerated().map { index, mark in
        CameraMark(
            id: "cam_\(index)", time: mark.time, hold: mark.hold, easeIn: mark.easeIn, easeOut: mark.easeOut,
            position: Vec3(mark.position.x, mark.position.y, mark.position.z), pan: mark.pan, tilt: mark.tilt,
            roll: mark.roll, focalLength: mark.focalLength
        )
    }
    return scene
}

/// The camera part of `golden-vectors.v1.json`.
struct GoldenVectors: Decodable {
    struct Camera: Decodable {
        var id: String, subject: String, duration: Double
        var marks: [GoldenMark]
    }

    var camera: [Camera]
}

struct GoldenMark: Decodable {
    struct Point: Decodable { var x: Double, y: Double, z: Double }
    var time: Double, hold: Double, easeIn: Double, easeOut: Double
    var position: Point
    var pan: Double, tilt: Double, roll: Double, focalLength: Double
}
