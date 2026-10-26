import Foundation
@testable import PrevisCore
import Testing

/// Regressions for the independent A5 review (round 1, head a64db38): simultaneous nested boardings and non-finite
/// attachment rotations.
struct A5ReviewTests {
    private func cube(_ id: String, heading: Double = 0) -> PrevisEntity {
        PrevisEntity(
            id: id, assetID: "prim.cube", name: id,
            placement: Placement(position: .zero, heading: heading, scale: 1)
        )
    }

    private func board(_ id: String, at position: Vec3, onto target: String) -> ActorMark {
        ActorMark(
            id: id, time: 1, hold: 0, easeIn: 0, easeOut: 0,
            position: position, gait: .stand, boardID: target
        )
    }

    /// rider boards cart at (1,0,0) while cart boards bus (heading π/2) at the origin, both at t = 1.
    private func nestedScene(entityOrder: [Int], trackOrder: [Int]) throws -> PrevisScene {
        var scene = try #require(ShotsSamples.twoPersonWalk().scenes.first)
        let entities = [cube("rider"), cube("cart"), cube("bus", heading: .pi / 2)]
        scene.entities = entityOrder.map { entities[$0] }
        let tracks = [
            Track(entityID: "cart", marks: [board("cart_board", at: .zero, onto: "bus")]),
            Track(entityID: "rider", marks: [board("rider_board", at: Vec3(1, 0, 0), onto: "cart")]),
        ]
        scene.blocking[0].tracks = trackOrder.map { tracks[$0] }
        return scene
    }

    private func riderPosition(_ scene: PrevisScene, catalog: ContentCatalog) throws -> Vec3 {
        let evaluator = try ShotEvaluator(scene: scene, shotID: #require(scene.shots.first).id, catalog: catalog)
        return try #require(evaluator.frame(at: 1).entities.first { $0.id == "rider" }).position
    }

    private func permutations(_ items: [Int]) -> [[Int]] {
        guard items.count > 1 else { return [items] }
        return items.flatMap { head in
            permutations(items.filter { $0 != head }).map { [head] + $0 }
        }
    }

    @Test func simultaneousNestedBoardingsKeepTheAuthoredWorldPositionInEveryEntityAndTrackOrder() throws {
        let catalog = try ContentCatalog.bundled()
        for entityOrder in permutations([0, 1, 2]) {
            for trackOrder in permutations([0, 1]) {
                let scene = try nestedScene(entityOrder: entityOrder, trackOrder: trackOrder)
                for _ in 0 ..< 25 {
                    let position = try riderPosition(scene, catalog: catalog)
                    #expect(
                        abs(position.x - 1) < 1e-9 && abs(position.y) < 1e-9 && abs(position.z) < 1e-9,
                        "entities \(entityOrder), tracks \(trackOrder): \(position)"
                    )
                }
            }
        }
    }

    @Test func repeatedConstructionIsDeterministic() throws {
        let catalog = try ContentCatalog.bundled()
        let scene = try nestedScene(entityOrder: [0, 1, 2], trackOrder: [0, 1])
        var outcomes = Set<String>()
        for _ in 0 ..< 100 {
            let position = try riderPosition(scene, catalog: catalog)
            outcomes.insert(String(format: "%.6f,%.6f,%.6f", position.x, position.y, position.z))
        }
        #expect(outcomes == ["1.000000,0.000000,0.000000"])
    }

    // MARK: Non-finite attachment rotation

    private func problems(rotation: Quat) throws -> [ShotsProblem] {
        let catalog = try ContentCatalog.bundled()
        var document = ShotsSamples.twoPersonWalk()
        let parent = document.scenes[0].entities[1].id
        document.scenes[0].entities[0].attachment = EntityAttachment(
            parentID: parent,
            offset: .zero,
            rotation: rotation
        )
        return ShotsValidation.problems(in: document, catalog: catalog).filter { $0.severity == .error }
    }

    @Test func aNonFiniteAttachmentRotationComponentIsAnErrorThatNamesTheEntity() throws {
        let bad: [Quat] = [
            Quat(x: .nan, y: 0, z: 0, w: 1), Quat(x: 0, y: .infinity, z: 0, w: 1),
            Quat(x: 0, y: 0, z: -.infinity, w: 1), Quat(x: 0, y: 0, z: 0, w: .nan),
        ]
        for rotation in bad {
            let errors = try problems(rotation: rotation)
            #expect(errors.contains { $0.message.contains("rotation") }, "\(rotation)")
        }
        let clean = try problems(rotation: Quat(x: 0, y: 0, z: 0, w: 1))
        #expect(!clean.contains { $0.message.contains("rotation") })
    }
}
