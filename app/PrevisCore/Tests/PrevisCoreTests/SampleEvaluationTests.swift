import Foundation
import Testing

@testable import PrevisCore

@Suite struct SampleEvaluationTests {
    /// IT0: both samples at their first, guide and last frames project every entity inside the canvas, and
    /// `ray` inverts `project`.
    @Test(arguments: [false, true])
    func samplesProjectInsideTheCanvas(small: Bool) throws {
        let catalog = try ContentCatalog.bundled()
        let document = ShotsSamples.twoPersonWalk(small: small)
        let scene = try #require(document.scenes.first)
        let shot = try #require(scene.shots.first)
        #expect(shot.canvas.isValid)
        #expect(FrameGrid.isValid(shot.frameCount))
        #expect(shot.frameCount == (small ? 22 : 124))

        let evaluator = try ShotEvaluator(scene: scene, shotID: shot.id, catalog: catalog)
        let frames = [0] + shot.guideFrames + [shot.frameCount - 1]
        for index in frames {
            let frame = evaluator.frame(index)
            #expect(frame.index == index)
            #expect(frame.entities.count == scene.entities.count)
            let size = frame.canvas.pixelSize
            for entity in frame.entities {
                let centre = Vec3(
                    (entity.bounds.min.x + entity.bounds.max.x) / 2,
                    (entity.bounds.min.y + entity.bounds.max.y) / 2,
                    (entity.bounds.min.z + entity.bounds.max.z) / 2
                )
                let pixel = try #require(frame.camera.project(centre, size: size), "\(entity.name) is behind the camera")
                #expect((0..<Double(size.width)).contains(pixel.x), "\(entity.name) x=\(pixel.x) at frame \(index)")
                #expect((0..<Double(size.height)).contains(pixel.y), "\(entity.name) y=\(pixel.y) at frame \(index)")

                let ray = frame.camera.ray(through: pixel, size: size)
                #expect(abs(ray.direction.length - 1) < 1e-12)
                let toCentre = centre - ray.origin
                let along = toCentre.dot(ray.direction)
                let miss = (toCentre - ray.direction * along).length
                #expect(along > 0)
                #expect(miss < 1e-9, "\(entity.name) misses its own ray by \(miss) m")
            }
        }
    }

    @Test func frameGridSnapsToSeventeenPlusFive() {
        #expect([5, 22, 39, 124, 362].allSatisfy(FrameGrid.isValid))
        #expect(!FrameGrid.isValid(23))
        #expect(FrameGrid.snapUp(1) == 5)
        #expect(FrameGrid.snapUp(23) == 39)
        #expect(FrameGrid.snapUp(22) == 22)
        #expect(FrameGrid.snap(30) == 22)
        #expect(FrameGrid.snap(31) == 39)
    }

    @Test func cameraMathFollowsTheConventions() {
        // Heading 0 faces −Z; positive headings turn toward −X.
        let forward = Quat.yaw(.pi / 2).rotate(Vec3(0, 0, -1))
        #expect(abs(forward.x + 1) < 1e-12 && abs(forward.z) < 1e-12)

        // A super35 gate at 35 mm in portrait is limited by the height: 2·atan(18.66 / 70).
        let camera = CameraFrame.make(
            position: Vec3(1, 2, 3), pan: 0.4, tilt: -0.2, roll: 0.1, focalLength: 35, sensor: .super35, aspect: 0.5
        )
        #expect(abs(camera.verticalFOV - 2 * atan(18.66 / 70)) < 1e-12)

        // The view matrix puts the camera at the origin looking down −Z, and inverts cleanly.
        let atOrigin = camera.viewMatrix().transform(camera.position)
        #expect(atOrigin.length < 1e-12)
        let product = camera.viewMatrix() * camera.viewMatrix().inverse
        #expect(zip(product.m, Mat4.identity.m).allSatisfy { abs($0 - $1) < 1e-12 })

        // Positive tilt looks up; a point straight ahead of an untilted camera lands at the canvas centre.
        let up = CameraFrame.make(
            position: .zero, pan: 0, tilt: 0.3, roll: 0, focalLength: 35, sensor: .super35, aspect: 1
        )
        let size = PixelSize(width: 200, height: 100)
        let aimed = up.project(up.orientation.rotate(Vec3(0, 0, -5)), size: size)
        #expect(aimed.map { abs($0.x - 100) < 1e-9 && abs($0.y - 50) < 1e-9 } == true)
        #expect(up.project(Vec3(0, 0, 5), size: size) == nil)
    }

    @Test func attributionIsBundled() {
        #expect(PrevisCoreAttribution.notice().contains("Wasserman"))
        #expect(PrevisCoreAttribution.license().contains("Apache License"))
    }
}
