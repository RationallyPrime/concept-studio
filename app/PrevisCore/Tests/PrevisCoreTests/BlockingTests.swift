import Foundation
@testable import PrevisCore
import Testing

struct BlockingTests {
    private let catalog: ContentCatalog
    private let woman = "ent_000000000111", man = "ent_000000000112", table = "ent_000000000101"

    init() throws {
        catalog = try ContentCatalog.bundled()
    }

    private func staged(_ name: String, _ scene: PrevisScene, _ shotID: ShotID) throws -> StagedCharacter {
        let staging = try ShotEvaluator(scene: scene, shotID: shotID, catalog: catalog).staging()
        return try #require(staging.characters.first { $0.name == name })
    }

    @Test func aBriefStandsPeopleBehindTheTableWhereTheFrameSaysFacingEachOther() throws {
        var scene = ShotsSamples.plateStaging().scenes[0]
        let brief = BlockingBrief(shot: "TS-02", characters: [
            .init(name: "Woman", frameX: 0.3, relation: .behind, piece: "Long table", facing: .toward("Man")),
            .init(name: "Man", frameX: 0.7, relation: .behind, piece: "long table", facing: .toward("Woman")),
        ])
        let result = try BlockingSolver.apply(brief, to: &scene, catalog: catalog)
        let shot = try #require(scene.shots.first { $0.id == result.shotID })
        #expect(shot.name == "TS-02" && shot.plateID == scene.plates[0].id)
        let match = try #require(scene.plates[0].match)
        let evaluator = try ShotEvaluator(scene: scene, shotID: shot.id, catalog: catalog)
        #expect(match.agrees(with: evaluator.frame(0).camera))

        // Behind is the side away from the camera: beyond the table's far edge at z = −4.475.
        // The shot has its own blocking, so the places are its take's, read here from the evaluated frame.
        let frame = evaluator.frame(0)
        for id in [woman, man] {
            let position = try #require(frame.entities.first { $0.id == id }).position
            #expect(abs(position.z - (-4.475 - 0.45)) < 1e-6)
        }
        let left = try staged("Woman", scene, shot.id), right = try staged("Man", scene, shot.id)
        #expect(left.horizontal == .left && right.horizontal == .right)
        // Each stands where their chest is in the column asked for.
        let camera = evaluator.frame(0).camera, size = shot.canvas.pixelSize
        for (id, column) in [(woman, 0.3), (man, 0.7)] {
            let position = try #require(frame.entities.first { $0.id == id }).position
            let pixel = try #require(camera.project(Vec3(position.x, 1.2, position.z), size: size))
            #expect(abs(pixel.x / Double(size.width) - column) < 0.01)
        }
        #expect(left.facing == .profileRight && right.facing == .profileLeft)
        #expect(left.cut == .hidden(by: ["Long table"]))
    }

    @Test func onOpenFloorTheSolverFindsTheDistanceThatShowsWhatIsAsked() throws {
        var scene = ShotsSamples.plateStaging().scenes[0]
        scene.entities.removeAll { $0.id == table }
        let full = BlockingBrief(shot: "Wide", characters: [
            .init(name: "Guard", asset: "person.man", frameX: 0.5, show: .headToBoots),
        ])
        let wide = try BlockingSolver.apply(full, to: &scene, catalog: catalog)
        let guardWide = try staged("Guard", scene, wide.shotID)
        #expect(guardWide.lowest == .feet && guardWide.crownVisible && guardWide.horizontal == .centre)
        #expect(scene.shots.first { $0.id == wide.shotID }?.asks.map(\.extent) == [.headToBoots])

        let close = BlockingBrief(shot: "Close", characters: [.init(name: "Guard", frameX: 0.5, show: .waistUp)])
        let near = try BlockingSolver.apply(close, to: &scene, catalog: catalog)
        let guardNear = try staged("Guard", scene, near.shotID)
        #expect(guardNear.lowest == .waist || guardNear.lowest == .hips)
        #expect(guardNear.distance < guardWide.distance)
        // The same character serves both shots: one entity, not two.
        #expect(scene.entities.filter { $0.name == "Guard" }.count == 1)
    }

    @Test func aPlateWithoutAMatchIsRefusedAndTheSceneIsLeftAlone() throws {
        var scene = ShotsSamples.plateStaging().scenes[0]
        scene.plates[0].match = nil
        let before = scene
        #expect(throws: ShotsError.self) {
            try BlockingSolver.apply(
                BlockingBrief(shot: "X", characters: [.init(name: "Woman")]), to: &scene, catalog: catalog
            )
        }
        #expect(scene == before)
    }

    @Test func theOfflineReaderTakesARowOfAShotTable() {
        let scene = ShotsSamples.plateStaging().scenes[0]
        let brief = BlockingReader.brief(
            from: "TS-07 plate C, medium. Woman frame left behind the Long table, facing Man. "
                + "Man frame right on the Dais, facing the camera.",
            scene: scene
        )
        #expect(brief.shot == "TS-07" && brief.plate == "c")
        #expect(brief.characters == [
            .init(
                name: "Woman",
                frameX: 0.27,
                show: .waistUp,
                relation: .behind,
                piece: "Long table",
                facing: .toward("Man")
            ),
            .init(name: "Man", frameX: 0.73, show: .waistUp, relation: .on, piece: "Dais", facing: .camera),
        ])
    }

    @Test func aBriefSurvivesJSONWithItsFacingAsOneWord() throws {
        let brief = BlockingBrief(shot: "A", plate: "C", characters: [
            .init(name: "One", frameX: 0.2, show: .face, facing: .toward("Two")),
            .init(name: "Two", relation: .on, piece: "Dais", facing: .frameLeft),
        ])
        let data = try JSONEncoder().encode(brief)
        #expect(try JSONDecoder().decode(BlockingBrief.self, from: data) == brief)
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains("\"toward:Two\"") && text.contains("\"frameLeft\""))
    }
}

struct OwnBlockingTests {
    private let woman = "ent_000000000111"

    @Test func aShotWithItsOwnBlockingNoLongerMovesWithTheOthers() throws {
        let catalog = try ContentCatalog.bundled()
        var scene = ShotsSamples.plateStaging().scenes[0]
        var second = scene.shots[0]
        second.id = "shot_000000000102"
        second.name = "TS-02"
        second.camera.marks[0].id = "cam_000000000102"
        scene.shots.append(second)
        #expect(scene.shotsSharingBlocking(with: second.id).map(\.name) == ["TS-01", "TS-02"])
        let before = try ShotEvaluator(scene: scene, shotID: second.id, catalog: catalog).frame(0)

        #expect(scene.giveOwnBlocking(to: second.id, takeID: "take_own") == "take_own")
        #expect(scene.shotsSharingBlocking(with: second.id).map(\.name) == ["TS-02"])
        #expect(scene.blocking.map(\.id) == ["take_000000000101", "take_own"])
        // Nothing has moved: everyone stands where they stood, in both shots.
        let after = try ShotEvaluator(scene: scene, shotID: second.id, catalog: catalog).frame(0)
        #expect(after.entities.map(\.position) == before.entities.map(\.position))
        #expect(after.entities.map(\.heading) == before.entities.map(\.heading))

        // Moving her in the second shot's take leaves the first shot as it was.
        let take = try #require(scene.blocking.firstIndex { $0.id == "take_own" })
        let track = try #require(scene.blocking[take].tracks.firstIndex { $0.entityID == woman })
        scene.blocking[take].tracks[track].marks[0].position = Vec3(1, 0, -6)
        let first = try ShotEvaluator(scene: scene, shotID: scene.shots[0].id, catalog: catalog).frame(0)
        let moved = try ShotEvaluator(scene: scene, shotID: second.id, catalog: catalog).frame(0)
        #expect(first.entities.first { $0.id == woman }?.position == before.entities.first { $0.id == woman }?.position)
        #expect(moved.entities.first { $0.id == woman }?.position.x == 1)

        // A shot that shares with nobody keeps its take, and the same call twice gives the same scene.
        #expect(scene.giveOwnBlocking(to: second.id, takeID: "take_again") == "take_own")
        var once = ShotsSamples.plateStaging().scenes[0], twice = once
        once.shots.append(second)
        twice.shots.append(second)
        once.giveOwnBlocking(to: second.id, takeID: "take_x")
        twice.giveOwnBlocking(to: second.id, takeID: "take_x")
        #expect(once == twice)
    }

    @Test func threeBriefsStageThreeShotsWithoutDisturbingEachOther() throws {
        let catalog = try ContentCatalog.bundled()
        var scene = ShotsSamples.plateStaging().scenes[0]
        scene.entities.removeAll { $0.id == "ent_000000000101" } // an open floor for the wide
        let wide = try BlockingSolver.apply(
            BlockingBrief(shot: "Wide", characters: [.init(name: "Woman", frameX: 0.4, show: .headToBoots)]),
            to: &scene, catalog: catalog
        )
        let wideStaging = try ShotEvaluator(scene: scene, shotID: wide.shotID, catalog: catalog).staging()
        let close = try BlockingSolver.apply(
            BlockingBrief(shot: "Close", characters: [.init(name: "Woman", frameX: 0.7, show: .face)]),
            to: &scene, catalog: catalog
        )
        let closeStaging = try ShotEvaluator(scene: scene, shotID: close.shotID, catalog: catalog).staging()
        let near = try #require(closeStaging.characters.first { $0.name == "Woman" })
        #expect(near.lowest == .neck && near.horizontal == .right)
        // The wide is still the wide it was before the close-up was blocked.
        #expect(try ShotEvaluator(scene: scene, shotID: wide.shotID, catalog: catalog).staging() == wideStaging)
        #expect(Set(scene.shots.map(\.blockingTakeID)).count == scene.shots.count)
    }
}
