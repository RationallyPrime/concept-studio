import Foundation
@testable import PrevisCore
import Testing

struct FormationTests {
    @Test func oneTrackMovesTheGridAndTheNamedMemberLeavesAtItsOwnMark() throws {
        let catalog = try ContentCatalog.bundled()
        let scene = sceneWithFormation()
        let copy = try JSONDecoder().decode(PrevisScene.self, from: JSONEncoder().encode(scene))
        #expect(copy == scene)
        #expect(ShotsValidation.problems(in: ShotsDocument(version: 1, scenes: [copy]), catalog: catalog).isEmpty)
        let evaluator = try ShotEvaluator(scene: copy, shotID: "shot", catalog: catalog)
        let before = evaluator.frame(12)
        let group = try #require(before.entities.first)
        let named = try #require(before.entities.last)
        #expect(group.id == "squad")
        #expect(group.position == Vec3(0, 0, -1))
        #expect(group.formationPoses.count == 1)
        #expect(group.formationPoses[0].keypoints.count == 18)
        #expect(Set(group.parts.map(\.id)).count == group.parts.count)
        #expect(named.position == Vec3(1, 0, -1))
        #expect(named.formationID == "squad")
        #expect(named.gait == group.gait)
        #expect(group.bounds.max.x == named.bounds.max.x)

        let onDeparture = evaluator.frame(24)
        #expect(onDeparture.entities.last?.position == Vec3(1, 0, -2))
        #expect(onDeparture.entities.last?.formationID == nil)
        let after = evaluator.frame(36)
        #expect(after.entities.last?.position.x == 2)
        #expect(after.entities.first?.formationPoses.count == 1)
        #expect(try #require(after.entities.first?.bounds.max.x) < 0)
        #expect(evaluator.frame(12) == before)
    }

    @Test func invalidGeometryAndOccupiedSlotsAreRejectedBeforeEvaluation() throws {
        let catalog = try ContentCatalog.bundled()
        var scene = sceneWithFormation()
        scene.entities[0].formation?.rows = Int.max
        #expect(throws: ShotsError.self) { try ShotEvaluator(scene: scene, shotID: "shot", catalog: catalog) }
        scene = sceneWithFormation()
        var other = scene.entities[1]
        other.id = "other"
        scene.entities.append(other)
        #expect(throws: ShotsError.self) { try ShotEvaluator(scene: scene, shotID: "shot", catalog: catalog) }
    }

    private func sceneWithFormation() -> PrevisScene {
        var scene = PrevisScene.make(
            id: "scene",
            name: "Courtyard",
            takeID: "take",
            shotID: "shot",
            cameraMarkID: "cam"
        )
        let placement = Placement(position: .zero, heading: 0, scale: 1)
        scene.entities = [
            PrevisEntity(
                id: "squad", assetID: "person.man", name: "Squad", placement: placement,
                formation: Formation(rows: 1, columns: 2, rowSpacing: 1, columnSpacing: 2)
            ),
            PrevisEntity(
                id: "cadet", assetID: "person.woman", name: "Cadet", placement: placement,
                formationSlot: FormationSlot(formationID: "squad", row: 1, column: 2)
            ),
        ]
        scene.blocking[0].tracks = [
            Track(entityID: "squad", marks: [
                mark("s1", time: 0, position: .zero), mark("s2", time: 1, position: Vec3(0, 0, -2)),
            ]),
            Track(entityID: "cadet", marks: [
                mark("c1", time: 1, position: Vec3(1, 0, -2)), mark("c2", time: 2, position: Vec3(3, 0, -2)),
            ]),
        ]
        return scene
    }

    private func mark(_ id: String, time: Double, position: Vec3) -> ActorMark {
        ActorMark(
            id: id, time: time, hold: 0, easeIn: 0, easeOut: 0, position: position, gait: .walk, arriveHeading: 0
        )
    }
}
