import Foundation
@testable import PrevisCore
import Testing

/// Porting scaffolding: compares the evaluator with Blockout's own `evaluate(t)` output. Runs only when
/// `PREVIS_GOLDENS` points at the output of `scripts/blockout/goldens.ts`.
struct ParityTests {
    private static let goldensPath = ProcessInfo.processInfo.environment["PREVIS_GOLDENS"]
    private let tolerance = 1e-9

    private static let aspects: [String: Double] = [
        "16:9": 16.0 / 9.0, "9:16": 9.0 / 16.0, "2.39:1": 2.39, "4:3": 4.0 / 3.0, "1:1": 1,
    ]

    @Test(.enabled(if: goldensPath != nil))
    func everyScenePasses() throws {
        let path = try #require(Self.goldensPath)
        let cases = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [[String: Any]]
        )
        #expect(!cases.isEmpty)
        let catalog = try ContentCatalog.bundled()
        for golden in cases {
            let name = try #require(golden["name"] as? String)
            try check(golden, named: name, catalog: catalog)
        }
    }

    private func check(_ golden: [String: Any], named name: String, catalog: ContentCatalog) throws {
        let blockoutScene = try #require(golden["scene"] as? [String: Any])
        let blockoutShot = try #require(golden["shot"] as? [String: Any])
        let project: [String: Any] = [
            "version": 1, "id": "parity", "name": name, "settings": [String: Any](), "scenes": [blockoutScene],
        ]
        let imported = try BlockoutImport.document(
            fromProjectJSON: JSONSerialization.data(withJSONObject: project),
            catalog: catalog,
            keepIDs: true
        )
        let scene = try #require(imported.document.scenes.first)
        let shotID = try #require(blockoutShot["id"] as? String)
        let aspectName = try #require(blockoutShot["aspect"] as? String)
        let aspect = try #require(Self.aspects[aspectName])
        let duration = try #require(blockoutShot["duration"] as? Double)
        let evaluator = try ShotEvaluator(scene: scene, shotID: shotID, catalog: catalog, aspect: aspect)

        var worst = 0.0
        var compared = 0
        func same(_ label: String, _ mine: Double, _ ref: Double, _ t: Double) {
            let diff = abs(mine - ref)
            worst = max(worst, diff)
            compared += 1
            #expect(diff <= tolerance, "\(name) \(label) at t=\(t): \(mine) vs \(ref)")
        }

        let samples = try #require(golden["samples"] as? [[String: Any]])
        for sample in samples {
            let t = try #require(sample["t"] as? Double)
            // Import rounds the frame count up, so the shot is at least as long as Blockout's; compare inside.
            guard t >= 0, t <= duration else { continue }
            let state = try #require(sample["state"] as? [String: Any])
            let frame = evaluator.frame(at: t)
            try compareCamera(frame.camera, state, t, same)
            for ref in try #require(state["entities"] as? [[String: Any]]) {
                let id = try #require(ref["entityId"] as? String)
                let mine = try #require(frame.entities.first { $0.id == id }, "\(name): no entity \(id)")
                let position = try #require(ref["position"] as? [String: Double])
                try same("\(id).x", mine.position.x, #require(position["x"]), t)
                try same("\(id).y", mine.position.y, #require(position["y"]), t)
                try same("\(id).z", mine.position.z, #require(position["z"]), t)
                try same("\(id).heading", mine.heading, #require(ref["heading"] as? Double), t)
                try same("\(id).distance", mine.distanceTravelled, #require(ref["distanceTravelled"] as? Double), t)
                try same("\(id).speed", mine.speed, #require(ref["speed"] as? Double), t)
                #expect(mine.gait.rawValue == ref["gait"] as? String, "\(name) \(id) gait at t=\(t)")
                let joints = ref["joints"] as? [String: Double] ?? [:]
                for (key, value) in joints {
                    guard let joint = Joint(rawValue: key) else { continue }
                    same("\(id).\(key)", mine.joints[joint] ?? .nan, value, t)
                }
                #expect(
                    Set(mine.joints.keys.map(\.rawValue)).subtracting(joints.keys).isEmpty,
                    "\(name) \(id) has joints Blockout does not at t=\(t)"
                )
            }
        }
        print("PARITY \(name): compared \(compared) scalars, worst difference \(worst)")
    }

    private func compareCamera(
        _ camera: CameraFrame,
        _ state: [String: Any],
        _ t: Double,
        _ same: (String, Double, Double, Double) -> Void
    ) throws {
        let ref = try #require(state["camera"] as? [String: Any])
        let position = try #require(ref["position"] as? [String: Double])
        try same("cam.x", camera.position.x, #require(position["x"]), t)
        try same("cam.y", camera.position.y, #require(position["y"]), t)
        try same("cam.z", camera.position.z, #require(position["z"]), t)
        try same("cam.pan", camera.pan, #require(ref["pan"] as? Double), t)
        try same("cam.tilt", camera.tilt, #require(ref["tilt"] as? Double), t)
        try same("cam.roll", camera.roll, #require(ref["roll"] as? Double), t)
        try same("cam.focal", camera.focalLength, #require(ref["focalLength"] as? Double), t)
        try same("cam.vfov", camera.verticalFOV, #require(ref["vfov"] as? Double), t)
        let focus = ref["focusDistance"] as? Double
        #expect((camera.focusDistance == nil) == (focus == nil), "focus presence at t=\(t)")
        if let focus, let mine = camera.focusDistance { same("cam.focus", mine, focus, t) }
    }
}
