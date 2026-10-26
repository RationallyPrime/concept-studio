import Foundation
@testable import PrevisCore
import Testing

struct EvaluatorTests {
    private func evaluator(small: Bool = false) throws -> (ShotEvaluator, PrevisScene) {
        let scene = try #require(ShotsSamples.twoPersonWalk(small: small).scenes.first)
        let shotID = try #require(scene.shots.first?.id)
        return try (ShotEvaluator(scene: scene, shotID: shotID, catalog: .bundled()), scene)
    }

    @Test func thePeopleWalkTowardEachOther() throws {
        let (evaluator, scene) = try evaluator()
        let man = try #require(scene.entities.first { $0.name == "Man" }).id
        let woman = try #require(scene.entities.first { $0.name == "Woman" }).id
        let first = evaluator.frame(0), last = evaluator.frame(evaluator.frameCount - 1)

        let startGap = try #require(first.entities.first { $0.id == woman }).position.x
            - (try #require(first.entities.first { $0.id == man })).position.x
        let endGap = try #require(last.entities.first { $0.id == woman }).position.x
            - (try #require(last.entities.first { $0.id == man })).position.x
        #expect(endGap < startGap && endGap > 0)

        let walking = evaluator.frame(20)
        let walkingMan = try #require(walking.entities.first { $0.id == man })
        #expect(abs(walkingMan.heading + .pi / 2) < 1e-6) // faces +X
        #expect(walkingMan.gait == .walk && walkingMan.speed > 0)
        #expect(last.camera.position.z < first.camera.position.z) // the push-in
    }

    @Test func pathsCoverEachMovingEntityAndTheCamera() throws {
        let (evaluator, scene) = try evaluator()
        let paths = evaluator.paths()
        #expect(paths.count == 3)
        let moving = paths.compactMap { path -> EntityID? in
            if case let .entity(id) = path.subject { id } else { nil }
        }
        #expect(Set(moving) == Set(scene.entities.prefix(2).map(\.id)))
        #expect(paths.contains { $0.subject == .camera && $0.marks.count == 2 })
        #expect(paths.allSatisfy { $0.points.count > 1 })
    }

    @Test func framesAreClampedAndDeterministic() throws {
        let (evaluator, _) = try evaluator(small: true)
        #expect(evaluator.frame(-5) == evaluator.frame(0))
        #expect(evaluator.frame(1000) == evaluator.frame(evaluator.frameCount - 1))
        #expect(evaluator.frame(at: 1000).time == Double(evaluator.frameCount - 1) / 24)
        #expect(evaluator.frame(7) == evaluator.frame(7))
        #expect(evaluator.frame(7).index == 7 && evaluator.frame(at: 0.3).index == nil)
    }
}
