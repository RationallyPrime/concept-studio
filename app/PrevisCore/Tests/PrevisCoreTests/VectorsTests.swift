import Foundation
@testable import PrevisCore
import Testing

/// Porting scaffolding: compares the generators with Blockout's own output. Runs only when `PREVIS_VECTORS` points at
/// `golden-vectors.v1.json` from `scripts/blockout/extract.ts`.
struct VectorsTests {
    private static let vectorsPath = ProcessInfo.processInfo.environment["PREVIS_VECTORS"]
    private let tolerance = 1e-9

    private func vectors(_ key: String) throws -> [[String: Any]] {
        let path = try #require(Self.vectorsPath)
        let root = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any]
        )
        return try #require(root[key] as? [[String: Any]])
    }

    @Test(.enabled(if: vectorsPath != nil))
    func actionPathsMatchBlockout() throws {
        var checked = Set<String>()
        for vector in try vectors("action") {
            let id = try #require(vector["id"] as? String)
            let start = try #require(vector["start"] as? [String: Double])
            let duration = try #require(vector["duration"] as? Double)
            let begin = try ActionStart(
                position: Vec3(#require(start["x"]), #require(start["y"]), #require(start["z"])),
                heading: #require(start["heading"])
            )
            // Only the starter paths are ported; the rest of Blockout's library has no generator here.
            guard let mine = ActionPresets.generate(id, start: begin, duration: duration) else { continue }
            checked.insert(id)
            let expected = try #require(vector["marks"] as? [[String: Any]])
            #expect(mine.count == expected.count, "\(id) mark count")
            for (mark, ref) in zip(mine, expected) {
                let position = try #require(ref["position"] as? [String: Double])
                let numbers: [(String, Double, Double)] = try [
                    ("time", mark.time, #require(ref["time"] as? Double)),
                    ("x", mark.position.x, #require(position["x"])),
                    ("y", mark.position.y, #require(position["y"])),
                    ("z", mark.position.z, #require(position["z"])),
                    ("easeIn", mark.easeIn, #require(ref["easeIn"] as? Double)),
                    ("easeOut", mark.easeOut, #require(ref["easeOut"] as? Double)),
                    ("hold", mark.hold, #require(ref["hold"] as? Double)),
                ]
                for (label, a, b) in numbers {
                    #expect(abs(a - b) <= tolerance, "\(id) d=\(duration) \(label): \(a) vs \(b)")
                }
                #expect(mark.gait.rawValue == ref["gait"] as? String, "\(id) gait")
            }
        }
        #expect(checked.count == 14, "checked \(checked.sorted())")
    }

    private func subject(_ kind: String) throws -> (at: (Double) -> SubjectSample, height: Double) {
        switch kind {
        case "still": return ({ _ in SubjectSample(x: 0, y: 0, z: 0, heading: 0) }, 1.75)
        case "walk": return ({ SubjectSample(x: 0, y: 0, z: -1.4 * $0, heading: 0) }, 1.75)
        case "fly": return ({ SubjectSample(x: 3 * $0, y: 8 + sin($0), z: -12 * $0, heading: 0.2) }, 5)
        default: throw ShotsError.importFailed("unknown vector subject \(kind)")
        }
    }

    /// The vectors use analytic subject paths that no document can express, so they go through the internal entry
    /// point that takes a subject function.
    @Test(.enabled(if: vectorsPath != nil))
    func cameraMovesMatchBlockout() throws {
        var checked = Set<String>()
        for vector in try vectors("camera") {
            let id = try #require(vector["id"] as? String)
            let kind = try #require(vector["subject"] as? String)
            let duration = try #require(vector["duration"] as? Double)
            let (at, height) = try subject(kind)
            let context = CameraMoveContext(
                subjectAt: at,
                subjectHeight: height,
                camera: CameraStart(position: Vec3(0, 1.6, 6), pan: 0, tilt: 0, focalLength: 35),
                duration: duration
            )
            // Only the starter moves are ported.
            guard let mine = CameraMovePresets.generate(id, context) else { continue }
            checked.insert(id)
            let expected = try #require(vector["marks"] as? [[String: Any]])
            #expect(mine.count == expected.count, "\(id) \(kind) mark count")
            for (mark, ref) in zip(mine, expected) {
                let position = try #require(ref["position"] as? [String: Double])
                let numbers: [(String, Double, Double)] = try [
                    ("time", mark.time, #require(ref["time"] as? Double)),
                    ("x", mark.position.x, #require(position["x"])),
                    ("y", mark.position.y, #require(position["y"])),
                    ("z", mark.position.z, #require(position["z"])),
                    ("pan", mark.pan, #require(ref["pan"] as? Double)),
                    ("tilt", mark.tilt, #require(ref["tilt"] as? Double)),
                    ("roll", mark.roll, #require(ref["roll"] as? Double)),
                    ("focalLength", mark.focalLength, #require(ref["focalLength"] as? Double)),
                    ("easeIn", mark.easeIn, #require(ref["easeIn"] as? Double)),
                    ("easeOut", mark.easeOut, #require(ref["easeOut"] as? Double)),
                    ("hold", mark.hold, #require(ref["hold"] as? Double)),
                ]
                for (label, a, b) in numbers {
                    #expect(abs(a - b) <= tolerance, "\(id) \(kind) d=\(duration) \(label): \(a) vs \(b)")
                }
            }
        }
        #expect(checked.count == 20, "checked \(checked.sorted())")
    }
}
