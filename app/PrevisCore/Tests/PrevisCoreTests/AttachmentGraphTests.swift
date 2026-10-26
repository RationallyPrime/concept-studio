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

    // MARK: Full transforms reach the drawn geometry

    /// A man riding a platform at the origin through an attachment with `rotation`. `EntityFrame.heading` is a yaw
    /// only;
    /// the drawn geometry is the parts' matrices, the world keypoints and the bounds, which carry the whole
    /// orientation.
    private func rider(rotation: Quat) throws -> EntityFrame {
        var scene = base
        var man = entity("man", "person.man")
        man.attachment = EntityAttachment(parentID: "platform", offset: .zero, rotation: rotation)
        scene.entities = [man, entity("platform", "prim.cube")]
        return try pose("man", evaluator(scene).frame(0))
    }

    private func keypoint(_ name: KeypointName, _ frame: EntityFrame) throws -> Vec3 {
        try #require(frame.keypoints.first { $0.name == name }).position
    }

    @Test func aPitchedAttachmentTipsTheDrawnBodyNotJustItsPosition() throws {
        let upright = try rider(rotation: .identity)
        let lying = try rider(rotation: .pitch(.pi / 2))
        // upright: the head is about 1.7 m above the feet and over them
        let uprightHead = try keypoint(.nose, upright)
        #expect(uprightHead.y > 1.5 && abs(uprightHead.z) < 0.3)
        // pitched a quarter turn: the head is level with the feet and 1.7 m away along +z
        let head = try keypoint(.nose, lying), neck = try keypoint(.neck, lying)
        #expect(head.y < 0.4 && head.z > 1.4, "nose at \(head)")
        #expect(neck.z > 1.2 && neck.y < 0.4, "neck at \(neck)")
        #expect(lying.bounds.max.y < 0.8 && lying.bounds.max.z > 1.5, "bounds \(lying.bounds)")
        // the torso part's own up axis (the second matrix column) points along +z instead of +y
        let torso = try #require(lying.parts.first { $0.id == "torso" }).transform.m
        #expect(abs(torso[4]) < 1e-9 && abs(torso[5]) < 1e-9 && torso[6] > 0.9, "torso up axis \(torso[4 ... 6])")
        let torsoUpright = try #require(upright.parts.first { $0.id == "torso" }).transform.m
        #expect(torsoUpright[5] > 0.9)
    }

    @Test func aRolledAttachmentTipsTheBodyToTheSide() throws {
        let rolled = try rider(rotation: .roll(.pi / 2))
        let head = try keypoint(.nose, rolled)
        #expect(head.y < 0.4 && head.x < -1.4, "nose at \(head)")
    }

    @Test func aPitchedStaticAssetTurnsItsParts() throws {
        var scene = base
        var chair = entity("chair", "furniture.chair")
        chair.attachment = EntityAttachment(parentID: "platform", offset: .zero, rotation: .pitch(.pi / 2))
        scene.entities = [chair, entity("platform", "prim.cube", heading: 0.4)]
        let frame = try pose("chair", evaluator(scene).frame(0))
        #expect(frame.heading.isFinite)
        // the chair's tallest part is its back: standing it spans about 0.9 m in y, on its back about 0.9 m in z
        #expect(frame.bounds.max.y < 0.6, "a chair on its back is low: \(frame.bounds)")
        #expect(frame.bounds.max.z - frame.bounds.min.z > 0.7, "and long: \(frame.bounds)")
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
