import Foundation
@testable import PrevisCore
import Testing

struct FightBlockingTests {
    @Test func pairedMotionSharesTheCueAndKeepsHeldPropsOnTheWrists() throws {
        let catalog = try ContentCatalog.bundled()
        var scene = PrevisScene.make(
            id: "scene",
            name: "Exchange",
            takeID: "take",
            shotID: "shot",
            cameraMarkID: "camera"
        )
        var shot = try #require(scene.shots.first)
        shot.frameCount = 39
        scene.shots = [shot]
        scene.entities = [
            person("first", at: Vec3(0, 0, 1.4), heading: 0),
            person("second", at: Vec3(0.52, 0, -0.88), heading: .pi, scale: 0.69),
            prop("first-prop", for: "first"),
            prop("second-prop", for: "second"),
        ]
        scene.blocking[0].tracks = try FightBlocking.swordExchange.tracks(
            scene: scene, shot: shot, actors: ["first", "second"], first: 2, last: 26, catalog: catalog
        )
        let times = [2, 14, 26].map(FrameGrid.time(ofFrame:))
        for track in scene.blocking[0].tracks {
            #expect(track.marks.first?.time == times[0])
            #expect(track.marks.contains { $0.time == times[1] })
            #expect(track.marks.last?.time == times[2])
        }
        let reopened = try JSONDecoder().decode(PrevisScene.self, from: JSONEncoder().encode(scene))
        #expect(reopened == scene)
        let evaluator = try ShotEvaluator(scene: reopened, shotID: shot.id, catalog: catalog)
        let initial = evaluator.frame(2)
        let cue = evaluator.frame(14)
        let first = try #require(cue.entities.first { $0.id == "first" })
        let second = try #require(cue.entities.first { $0.id == "second" })
        let before = try #require(initial.entities.first { $0.id == "first" })
        #expect((first.position - second.position).length < (before.position - second.position).length)
        for frame in [initial, cue, evaluator.frame(26)] {
            for actor in ["first", "second"] {
                let pose = try #require(frame.entities.first { $0.id == actor })
                let hand = try #require(pose.keypoints.first { $0.name == .rightWrist })
                let sword = try #require(frame.entities.first { $0.id == "\(actor)-prop" })
                #expect((sword.position - hand.position).length < 1e-8)
                #expect(sword.parts.contains { $0.id == "blade" })
            }
        }
        let blades = try ["first", "second"].map { actor in
            let sword = try #require(cue.entities.first { $0.id == "\(actor)-prop" })
            return try #require(sword.parts.first { $0.id == "blade" })
        }
        let contact = blades[0].transform.transform(.zero)
        let base = blades[1].transform.transform(Vec3(0, -0.38, 0))
        let tip = blades[1].transform.transform(Vec3(0, 0.38, 0))
        let distance = (contact.y - base.y) / (tip.y - base.y)
        #expect((0 ... 1).contains(distance), "distance \(distance), blade \(base) through \(tip), contact \(contact)")
        #expect((contact - (base + (tip - base) * distance)).length < 0.025)
    }

    private func person(_ id: String, at position: Vec3, heading: Double, scale: Double = 1) -> PrevisEntity {
        PrevisEntity(
            id: id, assetID: "person.man", name: id,
            placement: Placement(position: position, heading: heading, scale: scale)
        )
    }

    private func prop(_ id: String, for owner: EntityID) -> PrevisEntity {
        PrevisEntity(
            id: id, assetID: "prop.sword", name: "Sword",
            placement: Placement(position: .zero, heading: 0, scale: 1),
            attachment: EntityAttachment(parentID: owner, offset: .zero, rotation: .identity, hand: .right)
        )
    }
}
