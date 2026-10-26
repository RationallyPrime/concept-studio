import Foundation
@testable import PrevisCore
import Testing

struct WarningTests {
    private let catalog: ContentCatalog
    private let scene: PrevisScene
    private let shotID: ShotID
    private let man: EntityID

    init() throws {
        catalog = try ContentCatalog.bundled()
        scene = try #require(ShotsSamples.twoPersonWalk().scenes.first)
        shotID = try #require(scene.shots.first).id
        man = try #require(scene.entities.first { $0.name == "Man" }).id
    }

    private func warnings(_ scene: PrevisScene) throws -> [ShotsProblem] {
        try ShotEvaluator(scene: scene, shotID: shotID, catalog: catalog).warnings()
    }

    private func messages(_ scene: PrevisScene) throws -> String {
        try warnings(scene).map(\.message).joined(separator: "\n")
    }

    private func editingMan(_ scene: PrevisScene, _ edit: (inout [ActorMark]) -> Void) -> PrevisScene {
        var edited = scene
        let index = edited.blocking[0].tracks.firstIndex { $0.entityID == man }!
        edit(&edited.blocking[0].tracks[index].marks)
        return edited
    }

    @Test func theSampleShotsAreCleanExceptForTheShortOnesFrameCount() throws {
        #expect(try warnings(scene).isEmpty)
        let small = try #require(ShotsSamples.twoPersonWalk(small: true).scenes.first)
        let problems = try warnings(small)
        #expect(problems.count == 1 && problems[0].message.contains("22 frames"), "\(problems)")
        #expect(problems.allSatisfy { $0.severity == .warning && $0.shotID == shotID })
    }

    @Test func aLegFasterThanItsGaitNamesTheActorAndTheFix() throws {
        let fast = editingMan(scene) { $0[1].time = 0.2 }
        let text = try messages(fast)
        #expect(text.contains("\"Man\"") && text.contains("faster") && text.contains("jog"), "\(text)")
        let problem = try #require(warnings(fast).first)
        #expect(problem.entityID == man && problem.markID != nil)
    }

    @Test func movingWhileToldToStandIsAWarning() throws {
        let sliding = editingMan(scene) { $0[1].gait = .stand }
        #expect(try messages(sliding).contains("told to stand"))
    }

    @Test func aMarkPastTheEndOfTheShotIsAWarning() throws {
        let late = editingMan(scene) { $0[2].time = 99 }
        #expect(try messages(late).contains("after the shot ends"))
        var cameraLate = scene
        cameraLate.shots[0].camera.marks[1].time = 99
        #expect(try messages(cameraLate).contains("camera mark"))
    }

    @Test func theCameraCrossingTheLineBetweenTwoPeopleIsAWarning() throws {
        var crossing = scene
        crossing.shots[0].camera.marks[1].position = Vec3(0, 1.5, -6)
        let text = try messages(crossing)
        #expect(text.contains("crosses the line") && text.contains("\"Man\"") && text.contains("\"Woman\""), "\(text)")
    }

    @Test func theKeptBlockoutBehavioursAreFlagged() throws {
        let teleporting = editingMan(scene) { $0[2].time = $0[1].time }
        #expect(try messages(teleporting).contains("same time"))
        var spinning = scene
        spinning.shots[0].camera.marks[0].pan = -2
        spinning.shots[0].camera.marks[1].pan = 2
        #expect(try messages(spinning).contains("half a circle"))
    }

    @Test func aFrameCountOutsideTheTrainedRangeIsAWarningInBothDirections() throws {
        var long = scene
        long.shots[0].frameCount = 363 + 17 - 1
        #expect(try messages(long).contains("frames"))
        #expect(try warnings(scene).filter { $0.message.contains("frames") }.isEmpty)
    }
}
