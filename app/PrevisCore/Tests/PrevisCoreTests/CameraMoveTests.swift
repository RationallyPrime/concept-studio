import Foundation
@testable import PrevisCore
import Testing

struct CameraMoveTests {
    private struct Sample {
        var scene: PrevisScene
        var shotID: ShotID
        var man: EntityID
        var woman: EntityID
    }

    private func sample() throws -> Sample {
        let scene = try #require(ShotsSamples.twoPersonWalk(small: true).scenes.first)
        let man = try #require(scene.entities.first { $0.name == "Man" }).id
        let woman = try #require(scene.entities.first { $0.name == "Woman" }).id
        return try Sample(scene: scene, shotID: #require(scene.shots.first).id, man: man, woman: woman)
    }

    @Test(arguments: ["slow-push-in", "orbit-90-left", "crane-up-reveal"])
    func theMovesFrameBothPeopleInsideTheCanvas(move: String) throws {
        let catalog = try ContentCatalog.bundled()
        let fixture = try sample()
        var scene = fixture.scene
        let (shotID, man, woman) = (fixture.shotID, fixture.man, fixture.woman)
        let result = try CameraMoves.marks(move, scene: scene, shotID: shotID, subjects: [man, woman], catalog: catalog)
        #expect(result.marks.count >= 6 && Set(result.marks.map(\.id)).count == result.marks.count)
        #expect(result.marks.first?.time == 0)
        #expect(abs((result.marks.last?.time ?? 0) - scene.shots[0].duration) < 1e-9)

        scene.shots[0].camera.marks = result.marks
        scene.shots[0].camera.trackIDs = result.trackIDs
        let evaluator = try ShotEvaluator(scene: scene, shotID: shotID, catalog: catalog)
        for index in [0, evaluator.frameCount / 2, evaluator.frameCount - 1] {
            let frame = evaluator.frame(index)
            let size = frame.canvas.pixelSize
            for id in [man, woman] {
                let bounds = try #require(frame.entities.first { $0.id == id }).bounds
                let centre = Vec3(
                    (bounds.min.x + bounds.max.x) / 2,
                    (bounds.min.y + bounds.max.y) / 2,
                    (bounds.min.z + bounds.max.z) / 2
                )
                let pixel = try #require(frame.camera.project(centre, size: size), "\(move) frame \(index)")
                #expect(
                    (0 ..< Double(size.width)).contains(pixel.x) && (0 ..< Double(size.height)).contains(pixel.y),
                    "\(move) frame \(index): subject at \(pixel)"
                )
            }
        }
    }

    @Test func everyStarterMoveProducesIncreasingFiniteMarksOverTheWholeShot() throws {
        let catalog = try ContentCatalog.bundled()
        let fixture = try sample()
        let (scene, shotID, man, woman) = (fixture.scene, fixture.shotID, fixture.man, fixture.woman)
        for id in catalog.starter.cameraMoves {
            let marks = try CameraMoves
                .marks(id, scene: scene, shotID: shotID, subjects: [man, woman], catalog: catalog).marks
            #expect(marks.count >= 5, "\(id)")
            #expect(zip(marks, marks.dropFirst()).allSatisfy { $0.time < $1.time }, "\(id) times increase")
            #expect(marks.first?.time == 0 && abs((marks.last?.time ?? 0) - scene.shots[0].duration) < 1e-9, "\(id)")
            let numbers = marks
                .flatMap { [$0.position.x, $0.position.y, $0.position.z, $0.pan, $0.tilt, $0.focalLength] }
            let finite = numbers.allSatisfy(\.isFinite)
            #expect(finite, "\(id) finite")
            #expect(marks.allSatisfy { (12 ... 135).contains($0.focalLength) || $0.focalLength == 20 }, "\(id) lens")
        }
    }

    @Test func movesAimLockTheirSubjectsOnlyWhenTheCatalogSaysSo() throws {
        let catalog = try ContentCatalog.bundled()
        let fixture = try sample()
        let (scene, shotID, man, woman) = (fixture.scene, fixture.shotID, fixture.man, fixture.woman)
        let pushed = try CameraMoves.marks(
            "slow-push-in",
            scene: scene,
            shotID: shotID,
            subjects: [man, woman],
            catalog: catalog
        )
        #expect(pushed.trackIDs == [man, woman])
        let whip = try CameraMoves.marks("whip-pan", scene: scene, shotID: shotID, subjects: [man], catalog: catalog)
        #expect(whip.trackIDs.isEmpty)
    }

    @Test func severalSubjectsActAsOneAtTheirMidpoint() throws {
        let catalog = try ContentCatalog.bundled()
        let fixture = try sample()
        let (scene, shotID, man, woman) = (fixture.scene, fixture.shotID, fixture.man, fixture.woman)
        let both = try CameraMoves.marks(
            "orbit-90-left",
            scene: scene,
            shotID: shotID,
            subjects: [man, woman],
            catalog: catalog
        )
        let alone = try CameraMoves.marks(
            "orbit-90-left",
            scene: scene,
            shotID: shotID,
            subjects: [man],
            catalog: catalog
        )
        #expect(both.marks.first?.position != alone.marks.first?.position || both.marks[3].position != alone.marks[3]
            .position)
        // the orbit centre of the pair is the midpoint, between the two people along x
        let mid = try #require(both.marks.first).position
        let single = try #require(alone.marks.first).position
        #expect(abs(mid.x) < abs(single.x) + 6)
    }

    @Test func badRequestsFailWithASentence() throws {
        let catalog = try ContentCatalog.bundled()
        let fixture = try sample()
        let (scene, shotID, man) = (fixture.scene, fixture.shotID, fixture.man)
        #expect(throws: ShotsError.self) {
            try CameraMoves.marks("no-such-move", scene: scene, shotID: shotID, subjects: [man], catalog: catalog)
        }
        #expect(throws: ShotsError.self) {
            try CameraMoves.marks("slow-push-in", scene: scene, shotID: shotID, subjects: [], catalog: catalog)
        }
        #expect(throws: ShotsError.self) {
            try CameraMoves.marks("slow-push-in", scene: scene, shotID: shotID, subjects: ["ghost"], catalog: catalog)
        }
        #expect(throws: ShotsError.self) {
            try CameraMoves.marks("slow-push-in", scene: scene, shotID: "nope", subjects: [man], catalog: catalog)
        }
    }
}
