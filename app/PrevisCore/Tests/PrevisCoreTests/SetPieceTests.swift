import Foundation
@testable import PrevisCore
import Testing

struct SetPieceTests {
    @Test(arguments: ["prim.cube", "prim.cylinder", "prim.wall", "prim.stairs"])
    func independentDimensionsAreSharedByTheScenesShots(assetID: String) throws {
        let catalog = try ContentCatalog.bundled()
        let asset = try #require(catalog.asset(assetID))
        var piece = try #require(SetPiece.standard(for: asset))
        piece.width = 8
        piece.height = 2
        piece.depth = 3
        var scene = PrevisScene.make(id: "scene", name: "Stage", takeID: "take", shotID: "one", cameraMarkID: "cam")
        scene.shots.append(.make(id: "two", name: "2A", takeID: "take", cameraMarkID: "second"))
        scene.entities = [PrevisEntity(
            id: "piece", assetID: assetID, name: "Set piece",
            placement: Placement(position: .zero, heading: 0, scale: 1), setPiece: piece
        )]
        let saved = try JSONDecoder().decode(PrevisScene.self, from: JSONEncoder().encode(scene))
        let first = try ShotEvaluator(scene: saved, shotID: "one", catalog: catalog).frame(0)
        let second = try ShotEvaluator(scene: saved, shotID: "two", catalog: catalog).frame(0)
        #expect(first.entities == second.entities)
        let bounds = try #require(first.entities.first?.bounds)
        #expect(abs(bounds.max.x - bounds.min.x - 8) < 1e-9)
        #expect(abs(bounds.max.y - bounds.min.y - 2) < 1e-9)
        #expect(abs(bounds.max.z - bounds.min.z - 3) < 1e-9)
    }

    @Test func curvedBattlementHasABodyAndCrownAtTheAuthoredHeight() throws {
        let catalog = try ContentCatalog.bundled()
        var scene = PrevisScene.make(id: "scene", name: "Stage", takeID: "take", shotID: "shot", cameraMarkID: "cam")
        scene.entities = [PrevisEntity(
            id: "wall", assetID: "prim.wall", name: "Battlement",
            placement: Placement(position: .zero, heading: 0, scale: 1),
            setPiece: SetPiece(width: 18, height: 9, depth: 1.5, wallSweep: .pi / 2, crenellated: true)
        )]
        let frame = try ShotEvaluator(scene: scene, shotID: "shot", catalog: catalog).frame(0)
        let wall = try #require(frame.entities.first)
        #expect(wall.parts.filter { $0.id.hasPrefix("wall-") }.count == 12)
        #expect(wall.parts.filter { $0.id.hasPrefix("crown-") }.count == 12)
        #expect(wall.bounds.max.z - wall.bounds.min.z > 1.5)
        #expect(abs(wall.bounds.max.y - 9) < 1e-9)
        #expect(!wall.isActor)
    }
}
