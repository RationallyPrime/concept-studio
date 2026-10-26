import Foundation
@testable import PrevisCore
import Testing

/// A5's attachment graph (defects 3 and 4): one dependency-ordered resolution with full transforms, boarding last.
struct AttachmentGraphTests {
    private let catalog: ContentCatalog
    private let base: PrevisScene
    private let shotID: ShotID

    init() throws {
        catalog = try ContentCatalog.bundled()
        var scene = try #require(ShotsSamples.twoPersonWalk().scenes.first)
        scene.entities = []
        scene.blocking[0].tracks = []
        base = scene
        shotID = try #require(scene.shots.first).id
    }

    private func entity(_ id: String, _ asset: String, at position: Vec3 = .zero, heading: Double = 0) -> PrevisEntity {
        PrevisEntity(
            id: id, assetID: asset, name: id,
            placement: Placement(position: position, heading: heading, scale: 1)
        )
    }

    private func marks(_ points: [(Double, Vec3)], boarding: [Int: EntityID] = [:]) -> [ActorMark] {
        points.enumerated().map { index, point in
            ActorMark(
                id: "m\(index)", time: point.0, hold: 0, easeIn: 0, easeOut: 0,
                position: point.1, gait: .walk, boardID: boarding[index]
            )
        }
    }

    private func evaluator(_ scene: PrevisScene, _ corrections: Corrections = .all) throws -> ShotEvaluator {
        try ShotEvaluator(scene: scene, shotID: shotID, catalog: catalog, aspect: nil, corrections: corrections)
    }

    private func pose(_ id: String, _ frame: SceneFrame) throws -> EntityFrame {
        try #require(frame.entities.first { $0.id == id })
    }

    // MARK: Dependency order

    @Test func aDeepChainInReverseDocumentOrderLandsEveryChild() throws {
        var scene = base
        let depth = 9
        let step = 0.1
        // e0 is the root and walks; e(k) rides e(k-1) at 1 m to its right and turned by `step`; stored deepest first.
        var chain = [entity("e0", "prim.cube")]
        for k in 1 ..< depth {
            var child = entity("e\(k)", "prim.cube")
            child.attachment = EntityAttachment(
                parentID: "e\(k - 1)", offset: Vec3(1, 0, 0), rotation: .yaw(step)
            )
            chain.append(child)
        }
        scene.entities = Array(chain.reversed())
        scene.blocking[0].tracks = [
            Track(entityID: "e0", marks: marks([(0, Vec3(0, 0, 0)), (2, Vec3(4, 0, -3)), (4, Vec3(4, 0, -8))])),
        ]
        let evaluator = try evaluator(scene)
        for time in [0.0, 1.3, 2.9, 4.0] {
            let frame = evaluator.frame(at: time)
            var position = try pose("e0", frame).position
            var heading = try pose("e0", frame).heading
            for k in 1 ..< depth {
                // 1 m along the parent's right-hand axis: x' = x cos h, z' = -x sin h
                position += Vec3(cos(heading), 0, -sin(heading))
                heading += step
                let child = try pose("e\(k)", frame)
                #expect((child.position - position).length < 1e-9, "t=\(time) e\(k): \(child.position) vs \(position)")
                #expect(abs(child.heading - heading) < 1e-9, "t=\(time) e\(k) heading")
            }
        }
    }

    @Test func aRotatedAttachmentComposesTheParentsOrientation() throws {
        var scene = base
        var child = entity("child", "prim.cube")
        child.attachment = EntityAttachment(parentID: "parent", offset: Vec3(0, 1, -2), rotation: .yaw(0.5))
        scene.entities = [child, entity("parent", "prim.cube", at: Vec3(3, 0, 1), heading: .pi / 2)]
        let frame = try evaluator(scene).frame(0)
        let got = try pose("child", frame)
        // parent faces +π/2, so its frame turns the offset (0, 1, -2) to (-2·sin... ) = (−2, 1, 0) from (3, 0, 1)
        #expect((got.position - Vec3(1, 1, 1)).length < 1e-9, "\(got.position)")
        #expect(abs(got.heading - (.pi / 2 + 0.5)) < 1e-9)
    }

    @Test func anAttachmentCycleIsAnErrorThatNamesBothEntities() throws {
        var scene = base
        var a = entity("a", "prim.cube"), b = entity("b", "prim.cube")
        a.name = "Alpha"
        b.name = "Beta"
        a.attachment = EntityAttachment(parentID: "b", offset: .zero, rotation: .identity)
        b.attachment = EntityAttachment(parentID: "a", offset: .zero, rotation: .identity)
        scene.entities = [a, b]
        #expect {
            try evaluator(scene)
        } throws: { error in
            guard case let ShotsError.invalid(problems) = error else { return false }
            let text = problems.map(\.message).joined()
            return text.contains("\"Alpha\"") && text.contains("\"Beta\"") && text.contains("cycle")
        }
    }

    @Test func anUnknownAssetIsAnErrorThatNamesIt() throws {
        var scene = base
        scene.entities = [entity("x", "prim.hypercube")]
        #expect {
            try evaluator(scene)
        } throws: { error in
            "\(error.localizedDescription)".contains("prim.hypercube")
        }
    }

    // MARK: Boarding

    /// A bus travelling along +x with a cart attached 3 m behind it, and a man who walks to the cart's place and boards
    /// it.
    private func cartOnABus() -> PrevisScene {
        var scene = base
        var cart = entity("cart", "prim.cube", at: Vec3(0, 0, 3))
        cart.attachment = EntityAttachment(parentID: "bus", offset: Vec3(0, 0, 3), rotation: .identity)
        scene.entities = [
            entity("man", "person.man", at: Vec3(0, 0, 3)), cart, entity("bus", "vehicle.bus", heading: -.pi / 2),
        ]
        scene.blocking[0].tracks = [
            Track(entityID: "bus", marks: marks([(0, Vec3(0, 0, 0)), (4, Vec3(20, 0, 0))])),
            Track(
                entityID: "man",
                marks: marks([(0, Vec3(0, 0, 3)), (1, Vec3(1.2, 0, 3.2))], boarding: [1: "cart"])
            ),
        ]
        return scene
    }

    @Test func aRiderOnACartAttachedToAMovingBusFollowsTheBus() throws {
        let evaluator = try evaluator(cartOnABus())
        let boarded = evaluator.frame(at: 1.0)
        let offset = try pose("man", boarded).position - pose("cart", boarded).position
        for time in [1.5, 2.5, 3.9] {
            let frame = evaluator.frame(at: time)
            let man = try pose("man", frame), cart = try pose("cart", frame), bus = try pose("bus", frame)
            #expect(
                (man.position - cart.position - offset).length < 1e-9,
                "t=\(time): the rider keeps his place on the cart"
            )
            #expect(
                (cart.position - bus.position - Quat.yaw(bus.heading).rotate(Vec3(0, 0, 3))).length < 1e-9,
                "t=\(time): the cart keeps its place on the bus"
            )
        }
        let travelled = try pose("man", evaluator.frame(at: 3.9)).position.x - pose("man", boarded).position.x
        #expect(travelled > 10, "the rider has been carried \(travelled) m")
    }

    @Test func blockoutsFixedOrderLeavesTheRiderBehindTheMovingCart() throws {
        let legacy = try evaluator(cartOnABus(), [])
        let boarded = legacy.frame(at: 1.0)
        let offset = try pose("man", boarded).position - pose("cart", boarded).position
        let later = legacy.frame(at: 3.0)
        let drift = try (pose("man", later).position - pose("cart", later).position - offset).length
        #expect(drift > 0.5, "with Blockout's passes the rider lags the cart by \(drift) m")
    }

    @Test func boardingAnEntityThatIsItselfAttachedUsesItsResolvedPose() throws {
        // At the moment of boarding the rider stands on his mark, and from then on he moves exactly as the cart does.
        // The cart's pose at that moment comes from the resolved graph, with the bus's motion in it.
        let evaluator = try evaluator(cartOnABus())
        let boarding = evaluator.frame(at: 1.0)
        let man = try pose("man", boarding)
        #expect((man.position - Vec3(1.2, 0, 3.2)).length < 1e-9, "man at \(man.position)")
        #expect(man.gait == .stand)
        let later = evaluator.frame(at: 3.0)
        let carried = try pose("cart", later).position - pose("cart", boarding).position
        let moved = try pose("man", later).position - man.position
        #expect((moved - carried).length < 1e-9)
    }
}
