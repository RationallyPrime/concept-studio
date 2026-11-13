import Foundation
@testable import PrevisCore
import Testing

struct StagingTests {
    private let catalog: ContentCatalog
    private let woman = "ent_000000000111", man = "ent_000000000112", table = "ent_000000000101"

    init() throws {
        catalog = try ContentCatalog.bundled()
    }

    private func sample(_ edit: (inout PrevisScene) -> Void = { _ in }) throws -> (PrevisScene, ShotEvaluator) {
        var scene = ShotsSamples.plateStaging().scenes[0]
        edit(&scene)
        return try (scene, ShotEvaluator(scene: scene, shotID: scene.shots[0].id, catalog: catalog))
    }

    private func character(_ id: EntityID, in evaluator: ShotEvaluator) throws -> StagedCharacter {
        try #require(evaluator.staging().characters.first { $0.entityID == id })
    }

    @Test func aTableInFrontHidesTheLegsAndIsNamed() throws {
        let (_, evaluator) = try sample()
        let staged = try character(woman, in: evaluator)
        #expect(staged.isVisible && staged.crownVisible)
        #expect(staged.cut == .hidden(by: ["Long table"]))
        let lowest = try #require(staged.lowest)
        #expect(lowest >= .waist && lowest < .knees)
        #expect(staged.facing == .profileRight)
    }

    @Test func withoutTheTableTheSameFigureShowsToTheBoots() throws {
        let (_, evaluator) = try sample { scene in scene.entities.removeAll { $0.id == table } }
        let staged = try character(woman, in: evaluator)
        #expect(staged.lowest == .feet && staged.cut == nil)
    }

    @Test func askingForHeadToBootsBehindTheTableIsCaughtBeforeAnyModelRuns() throws {
        let (_, evaluator) = try sample { scene in
            scene.shots[0].asks = [FramingAsk(entityID: woman, extent: .headToBoots)]
        }
        let messages = evaluator.warnings().map(\.message)
        #expect(messages.contains { $0.contains("from head to boots") && $0.contains("Long table") })
    }

    @Test func aCloseUpTheFixedCameraCannotReachIsCaught() throws {
        let (_, evaluator) = try sample { scene in
            scene.shots[0].asks = [FramingAsk(entityID: man, extent: .face)]
        }
        let messages = evaluator.warnings().map(\.message)
        #expect(messages.contains { $0.contains("close-up of the face") && $0.contains("closer plate") })
    }

    @Test func aFigureTooCloseIsCutByTheFrameNotByTheSet() throws {
        let (_, evaluator) = try sample { scene in
            let index = scene.entities.firstIndex { $0.id == woman }!
            scene.entities[index].placement.position = Vec3(0, 0, -2.6)
        }
        let staged = try character(woman, in: evaluator)
        #expect(staged.cut == .frame("bottom"))
    }

    @Test func aPersonOverTheDaisStandsOnItsTop() throws {
        let (_, evaluator) = try sample()
        let frame = evaluator.frame(0)
        let posed = try #require(frame.entities.first { $0.id == man })
        #expect(abs(posed.position.y - 0.45) < 1e-9)
        let stepped = try sample { scene in
            let index = scene.entities.firstIndex { $0.id == man }!
            // On the upper of the dais's two steps, in front of its platform.
            scene.entities[index].placement.position = Vec3(0.7, 0, -8 + 1.5 + 0.16)
        }.1.frame(0).entities.first { $0.id == man }
        #expect(abs((stepped?.position.y ?? 0) - 0.3) < 1e-9)
    }

    @Test func standingInsideTheTableIsReported() throws {
        let (_, evaluator) = try sample { scene in
            let index = scene.entities.firstIndex { $0.id == woman }!
            scene.entities[index].placement.position = Vec3(-0.5, 0, -4)
        }
        #expect(evaluator.warnings().contains { $0.message.contains("stands inside the Long table") })
    }

    @Test func aShotThatLeavesItsPlateIsWarned() throws {
        let (_, evaluator) = try sample { scene in scene.shots[0].camera.marks[0].position.y = 2.2 }
        #expect(evaluator.warnings().contains { $0.message.contains("starts away from the camera of the plate") })
        let (_, matched) = try sample()
        #expect(!matched.warnings().contains { $0.message.contains("starts away") })
    }

    @Test func theDescriptionSaysWherePeopleAreInWords() throws {
        let (_, evaluator) = try sample()
        let text = evaluator.staging().description()
        #expect(text.contains("Set: the plate \"Hall C\""))
        #expect(text.contains("Camera: 1.55 m above the floor, tilted 6° down, 28 mm lens on Super 35"))
        #expect(text.contains("Woman (blue stand-in): frame"))
        #expect(text.contains("the Long table hides the rest"))
    }

    @Test func aDragonIsAnActorAtItsTrueSizeBesideAPerson() throws {
        let (_, evaluator) = try sample { scene in
            scene.entities.append(PrevisEntity(
                id: "ent_000000000120", assetID: "creature.dragon", name: "Dragon",
                placement: Placement(position: Vec3(0, 0, -40), heading: 0, scale: 1)
            ))
        }
        let dragon = try #require(evaluator.frame(0).entities.first { $0.id == "ent_000000000120" })
        #expect(dragon.isActor)
        let height = dragon.bounds.max.y - dragon.bounds.min.y
        #expect(height > 9.5 && height < 11.5)
    }

    @Test func aDragonsScaleIsItsStandingHeadHeightOverTenMetres() throws {
        let catalog = try ContentCatalog.bundled()
        for id in ["creature.dragon", "creature.dragon.spread"] {
            let asset = try #require(catalog.asset(id))
            let head = try #require(asset.parts?.first { $0.id == "head" })
            guard case let .box(size) = head.shape else {
                Issue.record("the head is a box")
                continue
            }
            let top = head.position.y + size.y / 2
            #expect(abs(top - 10) < 0.001)
            #expect(abs(asset.height - top) < 0.001)
        }
    }
}

struct FramingTableTests {
    @Test func everyShotOfASceneGetsARowFromItsOwnFirstFrame() throws {
        let catalog = try ContentCatalog.bundled()
        var scene = ShotsSamples.plateStaging().scenes[0]
        var second = scene.shots[0]
        second.id = "shot_000000000102"
        second.name = "TS-02"
        second.plateID = nil
        second.camera.marks = [CameraMark(
            id: "cam_000000000102", time: 0, hold: 0, easeIn: 0, easeOut: 0, position: Vec3(0, 1.6, -2), pan: 0,
            tilt: 0, roll: 0, focalLength: 50
        )]
        scene.shots.append(second)
        let rows = FramingTable.rows(scene: scene, catalog: catalog)
        #expect(rows.map(\.shot) == ["TS-01", "TS-02"])
        #expect(rows[0].plate == "Hall C" && rows[1].plate == "grey stage")
        #expect(rows[0].lens == "28 mm, Super 35" && rows[1].lens == "50 mm, Super 35")
        #expect(rows[0].who.contains("Woman: ") && rows[0].who.contains("behind the Long table"))
        let markdown = FramingTable.markdown(scene: scene, catalog: catalog)
        #expect(markdown.split(separator: "\n").count == 4)
    }
}
