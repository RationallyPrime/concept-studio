import Foundation
@testable import PrevisCore
import Testing

/// The corrected evaluator is the default one. A5 changes some of Blockout's behaviour on purpose. This runs the
/// corrected evaluator against Blockout's own output
/// and requires it to agree on every channel the corrections do not touch: a heading only where the entity has an
/// authored turn or a vertical leg, the camera's orientation and lens only where its marks differ in them. Where a
/// correction applies it must actually change something, so the exemption is never a way to skip a comparison.
/// Runs only when `PREVIS_GOLDENS` points at the output of `scripts/blockout/goldens.ts`.
struct FeatureParityTests {
    private static let goldensPath = ProcessInfo.processInfo.environment["PREVIS_GOLDENS"]
    private let tolerance = 1e-9

    private static let aspects: [String: Double] = [
        "16:9": 16.0 / 9.0, "9:16": 9.0 / 16.0, "2.39:1": 2.39, "4:3": 4.0 / 3.0, "1:1": 1,
    ]

    private struct Tally {
        var exact = 0
        var corrected = 0
        var changed = Set<String>()
    }

    @Test(.enabled(if: goldensPath != nil))
    func correctedEvaluatorAgreesWithBlockoutWhereTheCorrectionsDoNotApply() throws {
        let path = try #require(Self.goldensPath)
        let cases = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [[String: Any]]
        )
        let catalog = try ContentCatalog.bundled()
        var overall = Tally()
        var inventory: [String: Set<String>] = [:]
        for golden in cases {
            let name = try #require(golden["name"] as? String)
            let tally = try check(golden, named: name, catalog: catalog)
            overall.exact += tally.exact
            overall.corrected += tally.corrected
            inventory[name] = tally.changed
            print(
                "FEATURE-PARITY \(name): \(tally.exact) channels equal Blockout, "
                    + "\(tally.corrected) in corrected features, changed: \(tally.changed.sorted())"
            )
        }
        #expect(overall.exact > 10000)
        // The inventory of intentional deltas. A channel appears here only because a correction applies to it; any
        // other
        // difference fails above, and a delta that disappears or a new one that appears fails here.
        let camera: Set = ["cam.focal", "cam.pan", "cam.roll", "cam.tilt", "cam.vfov"]
        let expected: [String: Set<String>] = [
            "actors-paths-ease-hold": ["ent_001.heading"],
            "camera-16:9-handheld": camera,
            "camera-9:16-steadicam": camera,
            "camera-2.39:1-drone": camera,
            "camera-1:1-crane": camera,
            "track-and-mount": ["cam.focal", "cam.vfov"],
            "mount-no-track": [],
            "marriage-boarding-alighting": [
                "ent_041.heading", "ent_042.heading", "ent_042.x", "ent_042.z", "ent_043.heading", "ent_043.x",
                "ent_043.z", "ent_044.heading", "ent_044.x", "ent_044.z", "ent_045.heading", "ent_045.x", "ent_045.z",
            ],
        ]
        #expect(inventory == expected, "\(inventory)")
    }

    /// Where the corrected heading may differ from Blockout's: the legs that arrive at an authored facing, and vertical
    /// legs, never a hold. An entity that rides or is attached to such an entity differs while its parent does.
    private struct Affected {
        var legs: [String: [ClosedRange<Double>]]
        var parents: [String: Set<String>]

        func turning(_ id: String, at t: Double) -> Bool {
            legs[id, default: []].contains { ($0.lowerBound - 1e-9 ... $0.upperBound + 1e-9).contains(t) }
        }

        func ancestors(of id: String) -> Set<String> {
            var found = Set<String>()
            var frontier = Array(parents[id] ?? [])
            while let next = frontier.popLast() {
                guard found.insert(next).inserted else { continue }
                frontier += Array(parents[next] ?? [])
            }
            return found
        }

        func moved(_ id: String, at t: Double) -> Bool {
            ancestors(of: id).contains { turning($0, at: t) }
        }

        func headingDiffers(_ id: String, at t: Double) -> Bool {
            turning(id, at: t) || moved(id, at: t)
        }
    }

    private static func affected(in scene: PrevisScene, shot: Shot) -> Affected {
        let take = scene.blocking.first { $0.id == shot.blockingTakeID } ?? scene.blocking.first
        var legs: [String: [ClosedRange<Double>]] = [:]
        var parents: [String: Set<String>] = [:]
        for track in take?.tracks ?? [] {
            let marks = track.marks.enumerated()
                .sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }.map(\.element)
            for (from, to) in zip(marks, marks.dropFirst()) {
                let vertical = abs(to.position.x - from.position.x) < 1e-9 && abs(to.position.z - from.position.z) <
                    1e-9
                    && to.position.y != from.position.y
                guard to.arriveHeading != nil || vertical else { continue }
                let depart = min(from.time + from.hold, max(from.time, to.time - 0.1))
                legs[track.entityID, default: []].append(depart ... max(to.time, depart + 0.001))
            }
            for board in track.marks.compactMap(\.boardID) {
                parents[track.entityID, default: []].insert(board)
            }
        }
        for entity in scene.entities {
            if let parent = entity.attachment?.parentID { parents[entity.id, default: []].insert(parent) }
        }
        return Affected(legs: legs, parents: parents)
    }

    /// Whether the camera's orientation or lens differs between any two consecutive marks.
    private static func cameraAnimates(_ shot: Shot) -> Bool {
        let marks = shot.camera.marks.sorted { $0.time < $1.time }
        return zip(marks, marks.dropFirst()).contains {
            $0.pan != $1.pan || $0.tilt != $1.tilt || $0.roll != $1.roll || $0.focalLength != $1.focalLength
                || $0.focusDistance != $1.focusDistance
        }
    }

    /// The golden's scene imported with Blockout's ids, an evaluator with the default corrections, and its duration.
    private struct Loaded {
        var scene: PrevisScene
        var shot: Shot
        var evaluator: ShotEvaluator
        var duration: Double
    }

    private func load(_ golden: [String: Any], named name: String, catalog: ContentCatalog) throws -> Loaded {
        let blockoutScene = try #require(golden["scene"] as? [String: Any])
        let blockoutShot = try #require(golden["shot"] as? [String: Any])
        let project: [String: Any] = [
            "version": 1, "id": "parity", "name": name, "settings": [String: Any](), "scenes": [blockoutScene],
        ]
        let imported = try BlockoutImport.document(
            fromProjectJSON: JSONSerialization.data(withJSONObject: project), catalog: catalog, keepIDs: true
        )
        let scene = try #require(imported.document.scenes.first)
        let shot = try #require(scene.shots.first)
        let aspectName = try #require(blockoutShot["aspect"] as? String)
        let aspect = try #require(Self.aspects[aspectName])
        let duration = try #require(blockoutShot["duration"] as? Double)
        let evaluator = try ShotEvaluator(
            scene: scene, shotID: shot.id, catalog: catalog, aspect: aspect, corrections: .all
        )
        return Loaded(scene: scene, shot: shot, evaluator: evaluator, duration: duration)
    }

    private func check(_ golden: [String: Any], named name: String, catalog: ContentCatalog) throws -> Tally {
        let loaded = try load(golden, named: name, catalog: catalog)
        let (scene, shot, evaluator, duration) = (loaded.scene, loaded.shot, loaded.evaluator, loaded.duration)
        let affected = Self.affected(in: scene, shot: shot)
        let cameraAnimates = Self.cameraAnimates(shot)

        var tally = Tally()
        func compare(
            _ label: String,
            _ mine: Double,
            _ ref: Double,
            _ t: Double,
            corrected: Bool,
            angle: Bool = false
        ) {
            var diff = abs(mine - ref)
            if angle { diff = abs(remainder(mine - ref, 2 * .pi)) }
            if corrected {
                tally.corrected += 1
                if diff > tolerance { tally.changed.insert(label) }
            } else {
                tally.exact += 1
                #expect(diff <= tolerance, "\(name) \(label) at t=\(t): \(mine) vs \(ref)")
            }
        }

        for sample in try #require(golden["samples"] as? [[String: Any]]) {
            let t = try #require(sample["t"] as? Double)
            guard t >= 0, t <= duration else { continue }
            let state = try #require(sample["state"] as? [String: Any])
            let frame = evaluator.frame(at: t)
            let ref = try #require(state["camera"] as? [String: Any])
            let position = try #require(ref["position"] as? [String: Double])
            try compare("cam.x", frame.camera.position.x, #require(position["x"]), t, corrected: false)
            try compare("cam.y", frame.camera.position.y, #require(position["y"]), t, corrected: false)
            try compare("cam.z", frame.camera.position.z, #require(position["z"]), t, corrected: false)
            let tracked = shot.camera.trackIDs.isEmpty == false
            for (label, mine, key) in [
                ("pan", frame.camera.pan, "pan"), ("tilt", frame.camera.tilt, "tilt"), (
                    "roll",
                    frame.camera.roll,
                    "roll"
                ),
                ("focal", frame.camera.focalLength, "focalLength"), ("vfov", frame.camera.verticalFOV, "vfov"),
            ] {
                let aimed = tracked && (label == "pan" || label == "tilt")
                try compare(
                    "cam.\(label)", mine, #require(ref[key] as? Double), t,
                    corrected: cameraAnimates && !aimed, angle: label != "focal" && label != "vfov"
                )
            }
            for entityRef in try #require(state["entities"] as? [[String: Any]]) {
                let id = try #require(entityRef["entityId"] as? String)
                let mine = try #require(frame.entities.first { $0.id == id })
                let pos = try #require(entityRef["position"] as? [String: Double])
                try compare("\(id).x", mine.position.x, #require(pos["x"]), t, corrected: affected.moved(id, at: t))
                try compare("\(id).y", mine.position.y, #require(pos["y"]), t, corrected: false)
                try compare("\(id).z", mine.position.z, #require(pos["z"]), t, corrected: affected.moved(id, at: t))
                try compare(
                    "\(id).distance",
                    mine.distanceTravelled,
                    #require(entityRef["distanceTravelled"] as? Double),
                    t,
                    corrected: false
                )
                try compare("\(id).speed", mine.speed, #require(entityRef["speed"] as? Double), t, corrected: false)
                try compare(
                    "\(id).heading", mine.heading, #require(entityRef["heading"] as? Double), t,
                    corrected: affected.headingDiffers(id, at: t), angle: true
                )
                #expect(mine.gait.rawValue == entityRef["gait"] as? String, "\(name) \(id) gait at t=\(t)")
            }
        }
        return tally
    }
}
