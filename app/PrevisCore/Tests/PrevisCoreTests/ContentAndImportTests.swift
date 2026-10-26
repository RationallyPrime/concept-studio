import Foundation
@testable import PrevisCore
import Testing

struct ContentAndImportTests {
    private func sampleProject() throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: ShotsSamples.blockoutProjectJSON())
        return try #require(object as? [String: Any])
    }

    private func data(_ project: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: project)
    }

    /// A1 integration test: the catalog resolves its starter set, the sample imports, and every imported shot
    /// evaluates.
    @Test func catalogLoadsAndTheSampleImportsAndEvaluates() throws {
        let catalog = try ContentCatalog.bundled()
        #expect(catalog.starter.assets.allSatisfy { catalog.asset($0) != nil })
        #expect(catalog.starter.motions.allSatisfy { catalog.motion($0) != nil })
        #expect(catalog.starter.cameraMoves.allSatisfy { id in catalog.cameraMoves.contains { $0.id == id } })
        #expect(catalog.starter.actionPaths.allSatisfy { id in catalog.actionPaths.contains { $0.id == id } })
        #expect(catalog.asset("person.man")?.rig == .person)
        #expect(catalog.asset("animal.horse")?.rig == .quadruped)
        #expect(catalog.asset("prim.wall")?.rig == AssetRig.none)
        #expect(catalog.motion("wave")?.upperBodyOnly == true)
        #expect(catalog.motion("front-kick")?.upperBodyOnly == false)

        let (document, notes) = try BlockoutImport.document(
            fromProjectJSON: ShotsSamples.blockoutProjectJSON(),
            catalog: catalog
        )
        #expect(notes.isEmpty)
        for scene in document.scenes {
            for shot in scene.shots {
                let evaluator = try ShotEvaluator(scene: scene, shotID: shot.id, catalog: catalog)
                #expect(evaluator.frame(0).entities.count == scene.entities.count)
                #expect(evaluator.frame(shot.frameCount - 1).index == shot.frameCount - 1)
            }
        }
        #expect(ShotsValidation.problems(in: document, catalog: catalog).filter { $0.severity == .error }.isEmpty)
    }

    @Test func importMapsBlockoutFieldsOntoShots() throws {
        let catalog = try ContentCatalog.bundled()
        let (document, _) = try BlockoutImport.document(
            fromProjectJSON: ShotsSamples.blockoutProjectJSON(),
            catalog: catalog,
            keepIDs: true
        )
        let scene = try #require(document.scenes.first)
        let shot = try #require(scene.shots.first)
        #expect(shot.frameCount == 73 && shot.canvas == .portrait)
        #expect(shot.blockingTakeID == "take-1" && shot.notes.description == "Two people meet.")

        let man = try #require(scene.entities.first { $0.id == "e-man" })
        #expect(abs(man.placement.heading + .pi / 2) < 1e-12)
        #expect(abs(man.placement.scale - 1.1) < 1e-12) // params.height folded into scale
        let woman = try #require(scene.entities.first { $0.id == "e-woman" })
        #expect(woman.label == EntityLabel(text: "W", color: RGB(hex: "#e5484d")))

        let marks = try #require(scene.blocking.first?.tracks.first { $0.entityID == "e-man" }?.marks)
        #expect(marks.map(\.id) == ["m1", "m2"] && marks[1].arriveHeading == .pi)
        #expect(shot.camera.marks.map(\.focalLength) == [20, 20])
    }

    @Test func freshIDsKeepEveryReferenceConsistent() throws {
        let catalog = try ContentCatalog.bundled()
        var project = try sampleProject()
        var scenes = try #require(project["scenes"] as? [[String: Any]])
        var entities = try #require(scenes[0]["entities"] as? [[String: Any]])
        entities[1]["attachedTo"] = "e-man"
        entities[1]["attachedLocal"] = ["x": 0.1, "y": 0.2, "z": 0.3, "rotY": 0.5]
        scenes[0]["entities"] = entities
        var shots = try #require(scenes[0]["shots"] as? [[String: Any]])
        var camera = try #require(shots[0]["camera"] as? [String: Any])
        camera["trackEntityId"] = "e-woman"
        shots[0]["camera"] = camera
        scenes[0]["shots"] = shots
        project["scenes"] = scenes

        let (document, _) = try BlockoutImport.document(fromProjectJSON: data(project), catalog: catalog)
        let scene = try #require(document.scenes.first)
        let ids = Set(scene.entities.map(\.id))
        #expect(ids.count == 2 && ids.isDisjoint(with: ["e-man", "e-woman"]))
        let child = try #require(scene.entities.first { $0.name == "Woman" })
        let parent = try #require(scene.entities.first { $0.name == "Man" })
        #expect(child.attachment?.parentID == parent.id)
        #expect(child.attachment?.offset == Vec3(0.1, 0.2, 0.3))
        let shot = try #require(scene.shots.first)
        #expect(shot.camera.trackIDs == [child.id])
        #expect(scene.blocking.first?.tracks.allSatisfy { ids.contains($0.entityID) } == true)
        #expect(shot.blockingTakeID == scene.blocking.first?.id)
    }

    @Test func everyDroppedFeatureGetsANote() throws {
        let catalog = try ContentCatalog.bundled()
        var project = try sampleProject()
        project["settings"] = ["defaultProfileId": "cinematic"]
        var scenes = try #require(project["scenes"] as? [[String: Any]])
        scenes[0]["environment"] = ["lighting": "club", "sunAzimuth": 1.0, "fog": 0.2]
        scenes[0]["scans"] = [["id": "scan"]]
        scenes[0]["drafts"] = [["id": "draft"]]
        var entities = try #require(scenes[0]["entities"] as? [[String: Any]])
        entities[0]["excludeFromExport"] = true
        let transform: [String: Any] = ["position": ["x": 0, "y": 0, "z": 0], "rotationY": 0, "scale": 1]
        entities.append(["id": "e-x", "assetId": "custom.thing", "name": "Thing", "transform": transform])
        scenes[0]["entities"] = entities
        var shots = try #require(scenes[0]["shots"] as? [[String: Any]])
        shots[0]["cameraBank"] = [["name": "B"]]
        shots[0]["referenceVideo"] = ["path": "ref.mp4"]
        shots[0]["fps"] = 30
        scenes[0]["shots"] = shots
        project["scenes"] = scenes

        let (document, notes) = try BlockoutImport.document(fromProjectJSON: data(project), catalog: catalog)
        let joined = notes.joined(separator: "\n")
        for phrase in [
            "draft shot versions", "alternate cameras", "location scans", "reference videos",
            "sun direction and fog", "generator profile", "export exclusions",
            "\"club\"", "custom.thing", "30.0 fps",
        ] {
            #expect(joined.contains(phrase), "no note mentions \(phrase)")
        }
        #expect(document.scenes.first?.lighting == .interiorCool)
        #expect(document.scenes.first?.entities.count == 2)
    }

    @Test func aFileThatIsNotBlockoutFailsWithASentence() {
        #expect(throws: ShotsError.self) {
            try BlockoutImport.document(fromProjectJSON: Data("[]".utf8), catalog: ContentCatalog.bundled())
        }
    }

    @Test func rootMovesDefaultAbsentFieldsToZero() throws {
        let move = try JSONDecoder().decode(RootMove.self, from: Data(#"{"up": 0.2}"#.utf8))
        #expect(move == RootMove(forward: 0, up: 0.2))
    }
}
