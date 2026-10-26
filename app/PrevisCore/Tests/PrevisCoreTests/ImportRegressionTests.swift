import Foundation
@testable import PrevisCore
import Testing

/// PR 59 round-1 review findings, each reproduced before its repair.
struct ImportRegressionTests {
    private func sampleProject() throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: ShotsSamples.blockoutProjectJSON())
        return try #require(object as? [String: Any])
    }

    private func importing(_ project: [String: Any]) throws -> (document: ShotsDocument, notes: [String]) {
        try BlockoutImport.document(
            fromProjectJSON: JSONSerialization.data(withJSONObject: project),
            catalog: ContentCatalog.bundled(),
            keepIDs: true
        )
    }

    /// Replaces `value` at `path` (dictionary keys and array indices) and returns the edited project.
    private func setting(_ value: Any?, at path: [Any], in root: Any) -> Any {
        guard let head = path.first else { return value as Any }
        let rest = Array(path.dropFirst())
        if let key = head as? String, var dictionary = root as? [String: Any] {
            if rest.isEmpty, value == nil {
                dictionary.removeValue(forKey: key)
            } else {
                dictionary[key] = setting(value, at: rest, in: dictionary[key] as Any)
            }
            return dictionary
        }
        if let index = head as? Int, var array = root as? [Any] {
            array[index] = setting(value, at: rest, in: array[index])
            return array
        }
        return root
    }

    // MARK: r4376421686: params.height is the supplied multiplier

    @Test(arguments: [0.6, 0.8, 1.0, 1.5])
    func personHeightMultiplierIsPreservedWithoutClamping(height: Double) throws {
        var project = try sampleProject()
        project =
            try #require(setting(
                height,
                at: ["scenes", 0, "entities", 0, "params", "height"],
                in: project
            ) as? [String: Any])
        let scene = try #require(importing(project).document.scenes.first)
        let man = try #require(scene.entities.first { $0.id == "e-man" })
        #expect(abs(man.placement.scale - height) < 1e-12)
    }

    @Test func heightMultipliesTheTransformScale() throws {
        var project = try sampleProject()
        project =
            try #require(setting(
                2.0,
                at: ["scenes", 0, "entities", 0, "transform", "scale"],
                in: project
            ) as? [String: Any])
        project =
            try #require(setting(
                0.6,
                at: ["scenes", 0, "entities", 0, "params", "height"],
                in: project
            ) as? [String: Any])
        let man = try #require(importing(project).document.scenes.first?.entities.first { $0.id == "e-man" })
        #expect(abs(man.placement.scale - 1.2) < 1e-12)
    }

    @Test(arguments: [0.0, -1.0])
    func aHeightThatCannotBeAScaleIsIgnoredWithANote(height: Double) throws {
        var project = try sampleProject()
        project =
            try #require(setting(
                height,
                at: ["scenes", 0, "entities", 0, "params", "height"],
                in: project
            ) as? [String: Any])
        let result = try importing(project)
        let man = try #require(result.document.scenes.first?.entities.first { $0.id == "e-man" })
        #expect(man.placement.scale == 1)
        #expect(result.notes.joined().contains("height"))
    }

    // MARK: r4376421700: a duration that cannot be a frame count is an import error, not a trap

    @Test(arguments: [1e308, 1e300, 1e18, -1.0])
    func anUnrepresentableDurationFailsTheImport(duration: Double) throws {
        var project = try sampleProject()
        project =
            try #require(setting(duration, at: ["scenes", 0, "shots", 0, "duration"], in: project) as? [String: Any])
        #expect {
            try importing(project)
        } throws: { error in
            guard case let ShotsError.importFailed(message) = error else { return false }
            return message.contains("1A") && message.contains("duration")
        }
    }

    @Test func aLongButRepresentableDurationStillImportsOnTheGrid() throws {
        var project = try sampleProject()
        project = try #require(setting(1e9, at: ["scenes", 0, "shots", 0, "duration"], in: project) as? [String: Any])
        let shot = try #require(importing(project).document.scenes.first?.shots.first)
        #expect(FrameGrid.isValid(shot.frameCount) && shot.frameCount >= Int(1e9 * 24))
    }

    // MARK: r4376421710: absent fields default; identities stay required

    /// Every key path in the document that is not an identity.
    private func optionalPaths(in value: Any, prefix: [Any] = []) -> [[Any]] {
        let identities: Set = ["id", "assetId", "entityId"]
        var found: [[Any]] = []
        if let dictionary = value as? [String: Any] {
            for (key, child) in dictionary where !identities.contains(key) {
                found.append(prefix + [key])
                found += optionalPaths(in: child, prefix: prefix + [key])
            }
        } else if let array = value as? [Any] {
            for (index, child) in array.enumerated() {
                found += optionalPaths(in: child, prefix: prefix + [index])
            }
        }
        return found
    }

    @Test func removingAnyNonIdentityFieldStillImports() throws {
        let project = try sampleProject()
        let paths = optionalPaths(in: project)
        #expect(paths.count > 40) // the sample exercises scenes, entities, takes, marks, shots and cameras
        for path in paths {
            let reduced = try #require(setting(nil, at: path, in: project) as? [String: Any])
            do {
                _ = try importing(reduced)
            } catch {
                Issue.record("removing \(path) fails the import: \(error)")
            }
        }
    }

    @Test func theReviewersRepro() throws {
        var project = try sampleProject()
        project = try #require(
            setting(
                nil,
                at: ["scenes", 0, "blocking", 0, "tracks", 0, "marks", 0, "hold"],
                in: project
            ) as? [String: Any]
        )
        let marks = try #require(importing(project).document.scenes.first?.blocking.first?.tracks.first?.marks)
        #expect(marks.first?.hold == 0)
    }

    @Test func absentFieldsTakeTheirDefaults() throws {
        let json = """
        {"scenes": [{"id": "s", "entities": [{"id": "e", "assetId": "person.man"}],
          "blocking": [{"id": "t", "tracks": [{"entityId": "e", "marks": [{"id": "m"}]}]}],
          "shots": [{"id": "h", "camera": {"marks": [{"id": "c"}]}}]}]}
        """
        let result = try BlockoutImport.document(
            fromProjectJSON: Data(json.utf8),
            catalog: ContentCatalog.bundled(),
            keepIDs: true
        )
        let scene = try #require(result.document.scenes.first)
        let entity = try #require(scene.entities.first)
        #expect(entity.placement == Placement(position: .zero, heading: 0, scale: 1))
        #expect(entity.name.isEmpty && scene.lighting == .day)
        let shot = try #require(scene.shots.first)
        #expect(shot.frameCount == FrameGrid.defaultFrameCount && shot.canvas == .portrait)
        #expect(shot.camera.marks.first?.focalLength == 35 && shot.camera.sensor == .super35)
        let mark = try #require(scene.blocking.first?.tracks.first?.marks.first)
        #expect(mark.gait == .stand && mark.time == 0 && mark.via.isEmpty)
    }

    @Test(arguments: [
        #"{"scenes": [{"name": "no id"}]}"#,
        #"{"scenes": [{"id": "s", "entities": [{"id": "e"}]}]}"#,
        #"{"scenes": [{"id": "s", "blocking": [{"id": "t", "tracks": [{"marks": []}]}]}]}"#,
        #"{"scenes": [{"id": "s", "shots": [{"name": "no id"}]}]}"#,
    ])
    func aMissingIdentityIsStillAnImportError(json: String) {
        #expect(throws: ShotsError.self) {
            try BlockoutImport.document(fromProjectJSON: Data(json.utf8), catalog: ContentCatalog.bundled())
        }
    }
}
