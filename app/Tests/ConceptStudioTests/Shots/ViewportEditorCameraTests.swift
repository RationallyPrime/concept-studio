@testable import ConceptStudio
import Foundation
import PrevisCore
import SwiftUI
import Testing

@Suite("Viewport editor camera and D0 shells")
struct ViewportEditorCameraTests {
    @Test func fullCircleOrbitReturnsToStartInSingleAndSteppedIncrements() {
        let initial = EditorCamera(
            target: Vec3(1.25, 0.9, -2.4),
            distance: 8.5,
            yaw: 0.42,
            pitch: -0.25,
            focalLength: 35,
            sensor: .super35
        )
        let size = PixelSize(width: 960, height: 540)
        let startFrame = initial.cameraFrame(for: size)

        let singleStep = initial.orbiting(deltaYaw: 2 * .pi, deltaPitch: 0)
        #expect(abs(singleStep.yaw - initial.yaw) < 1e-12)
        #expect(abs(singleStep.pitch - initial.pitch) < 1e-12)
        #expect(distance(singleStep.position, initial.position) < 1e-12)
        #expect(distance(singleStep.cameraFrame(for: size).position, startFrame.position) < 1e-12)

        var stepped = initial
        let steps = 72
        for _ in 0 ..< steps {
            stepped.orbit(deltaYaw: (2 * .pi) / Double(steps), deltaPitch: 0)
        }
        #expect(abs(stepped.yaw - initial.yaw) < 1e-12)
        #expect(abs(stepped.pitch - initial.pitch) < 1e-12)
        #expect(distance(stepped.position, initial.position) < 1e-11)
        #expect(distance(stepped.forward, initial.forward) < 1e-12)
        #expect(distance(stepped.cameraFrame(for: size).position, startFrame.position) < 1e-11)
    }

    @Test func dollyClampsBetweenHalfMetreAndTwoHundredMetres() {
        var camera = EditorCamera(target: .zero, distance: 6.5)

        camera.dolly(delta: -500)
        #expect(camera.distance == 0.5)

        camera.dolly(delta: 500)
        #expect(camera.distance == 200.0)

        camera.dolly(scale: 0.0001)
        #expect(camera.distance == 0.5)

        camera.dolly(scale: 10000)
        #expect(camera.distance == 200.0)

        let belowMin = EditorCamera(target: .zero, distance: 0.01)
        #expect(belowMin.distance == 0.5)

        let aboveMax = EditorCamera(target: .zero, distance: 999.0)
        #expect(aboveMax.distance == 200.0)

        let mid = belowMin.dollying(delta: 4.5)
        #expect(abs(mid.distance - 5.0) < 1e-12)
    }

    @Test(arguments: [
        PixelSize(width: 640, height: 1152),
        PixelSize(width: 320, height: 576),
        PixelSize(width: 1920, height: 1080),
        PixelSize(width: 768, height: 768),
        PixelSize(width: 413, height: 271),
        PixelSize(width: 271, height: 917),
    ])
    func targetProjectsToViewportCentreAcrossArbitraryPixelSizes(size: PixelSize) throws {
        var camera = EditorCamera(
            target: Vec3(-1.8, 1.35, 2.7),
            distance: 11.2,
            yaw: -1.1,
            pitch: -0.37,
            focalLength: 28,
            sensor: .fullFrame
        )
        camera.pan(deltaRight: 0.85, deltaUp: -0.4)

        let projected = try #require(camera.project(camera.target, size: size))
        let centre = Point2(x: Double(size.width) / 2, y: Double(size.height) / 2)
        #expect(abs(projected.x - centre.x) < 1e-9)
        #expect(abs(projected.y - centre.y) < 1e-9)

        let ray = camera.ray(through: centre, size: size)
        let pointAtDistance = Vec3(
            ray.origin.x + ray.direction.x * camera.distance,
            ray.origin.y + ray.direction.y * camera.distance,
            ray.origin.z + ray.direction.z * camera.distance
        )
        #expect(distance(pointAtDistance, camera.target) < 1e-9)
    }

    @Test @MainActor func viewportAndShotCameraShellsInitialiseWithStore() throws {
        let store = try ShotsStore(
            catalog: ContentCatalog.bundled(),
            document: ShotsSamples.twoPersonWalk(small: true),
            saveURL: nil
        )
        let viewport = ShotsViewport(store: store)
        let shotCamera = ShotCameraView(store: store)
        #expect(viewport.store === store)
        #expect(shotCamera.store === store)
    }

    private func distance(_ a: Vec3, _ b: Vec3) -> Double {
        let dx = a.x - b.x
        let dy = a.y - b.y
        let dz = a.z - b.z
        return (dx * dx + dy * dy + dz * dz).squareRoot()
    }
}
