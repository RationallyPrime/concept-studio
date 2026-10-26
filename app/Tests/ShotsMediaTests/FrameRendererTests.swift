import AppKit
import CoreGraphics
import Foundation
import PrevisCore
import RealityKit
import ShotsMedia
import Testing

/// Render tests run wherever there is a Metal device, unless CI sets SHOTS_SKIP_RENDER (CONTRACTS section 9).
let renderingEnabled = ShotFrameRenderer.isAvailable
    && ProcessInfo.processInfo.environment["SHOTS_SKIP_RENDER"] == nil

@Suite("offscreen frame renderer", .enabled(if: renderingEnabled))
@MainActor
struct FrameRendererTests {
    private func smallSample() throws -> (scene: PrevisScene, frame: SceneFrame) {
        let scene = try #require(ShotsSamples.twoPersonWalk(small: true).scenes.first)
        let shot = try #require(scene.shots.first)
        let evaluator = try ShotEvaluator(scene: scene, shotID: shot.id, catalog: ContentCatalog.bundled())
        return (scene, evaluator.frame(shot.guideFrames.first ?? 0))
    }

    @Test func everyEntityIsDrawnWhereItsBoundsProject() async throws {
        let (scene, frame) = try smallSample()
        var bare = frame
        bare.entities = []
        let renderer = try ShotFrameRenderer()
        let look = PrevisLook(scene: scene)
        let drawn = try await Pixels(renderer.image(of: frame, look: look))
        let empty = try await Pixels(renderer.image(of: bare, look: look))
        #expect(drawn.width == frame.canvas.width && drawn.height == frame.canvas.height)
        #expect(!frame.entities.isEmpty)
        for entity in frame.entities {
            let centre = Vec3(
                (entity.bounds.min.x + entity.bounds.max.x) / 2,
                (entity.bounds.min.y + entity.bounds.max.y) / 2,
                (entity.bounds.min.z + entity.bounds.max.z) / 2
            )
            let pixel = try #require(frame.camera.project(centre, size: frame.canvas.pixelSize))
            #expect(drawn.differs(from: empty, at: pixel), "\(entity.name) isn't drawn at its projected centre")
        }
    }

    @Test func markersLandWithinHalfAPixelOfTheirProjection() async throws {
        let (scene, frame) = try smallSample()
        var bare = frame
        bare.entities = []
        let size = frame.canvas.pixelSize
        let targets = [(0.5, 0.5), (0.2, 0.2), (0.8, 0.2), (0.2, 0.8), (0.8, 0.8)].map {
            Point2(x: $0.0 * Double(size.width), y: $0.1 * Double(size.height))
        }
        let overlay = Entity()
        for target in targets {
            let ray = frame.camera.ray(through: target, size: size)
            let point = Vec3(
                ray.origin.x + ray.direction.x * 5, ray.origin.y + ray.direction.y * 5,
                ray.origin.z + ray.direction.z * 5
            )
            let marker = ModelEntity(mesh: .generateSphere(radius: 0.012), materials: [UnlitMaterial(color: .white)])
            marker.position = SIMD3<Float>(Float(point.x), Float(point.y), Float(point.z))
            overlay.addChild(marker)
        }
        let renderer = try ShotFrameRenderer()
        let pixels = try await Pixels(renderer.image(of: bare, look: PrevisLook(scene: scene), overlay: overlay))
        let blobs = pixels.brightBlobs()
        #expect(blobs.count == targets.count)
        for target in targets {
            let nearest = try #require(blobs.min { distance($0, target) < distance($1, target) })
            #expect(distance(nearest, target) < 0.5, "marker at \(target) drawn at \(nearest)")
        }
    }

    @Test func aFrameRendersTheSameBytesEveryTime() async throws {
        let (scene, frame) = try smallSample()
        let renderer = try ShotFrameRenderer()
        let look = PrevisLook(scene: scene)
        let first = try await Pixels(renderer.image(of: frame, look: look))
        var other = frame
        other.camera = CameraFrame.make(
            position: Vec3(3, 2, 4), pan: 0.6, tilt: -0.2, roll: 0, focalLength: 24, sensor: .super35,
            aspect: frame.canvas.aspect
        )
        _ = try await renderer.image(of: other, look: PrevisLook(lighting: .night))
        let again = try await Pixels(renderer.image(of: frame, look: look))
        #expect(first.bytes == again.bytes)
    }

    @Test func aWedgeShowsItsOutsideFaces() async throws {
        let (scene, frame) = try smallSample()
        let wedge = PosedPart(
            id: "ramp",
            shape: .wedge(size: Vec3(1.2, 0.8, 1.6)),
            transform: Self.translation(Vec3(0, 0.4, 0)),
            color: RGB(hex: "#c8c8d0")
        )
        var ramp = frame
        ramp.entities = [
            EntityFrame(
                id: "ramp", assetID: "prim.ramp", name: "Ramp", isActor: false, position: .zero, heading: 0,
                gait: .stand, speed: 0, distanceTravelled: 0, parts: [wedge],
                bounds: Box3(min: Vec3(-0.6, 0, -0.8), max: Vec3(0.6, 0.8, 0.8))
            ),
        ]
        ramp.camera = CameraFrame.make(
            position: Vec3(0, 2.2, 3.5), pan: 0, tilt: -0.45, roll: 0, focalLength: 35, sensor: .super35,
            aspect: frame.canvas.aspect
        )
        var bare = ramp
        bare.entities = []
        let renderer = try ShotFrameRenderer()
        let look = PrevisLook(scene: scene)
        let drawn = try await Pixels(renderer.image(of: ramp, look: look))
        let empty = try await Pixels(renderer.image(of: bare, look: look))
        let slope = try #require(ramp.camera.project(Vec3(0, 0.45, 0.1), size: ramp.canvas.pixelSize))
        #expect(drawn.differs(from: empty, at: slope), "the ramp's slope faces the camera but isn't drawn")
    }

    /// Writes the full-size sample's guide frame for eyeballing, only when SHOTS_SNAPSHOT_DIR names a folder.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SHOTS_SNAPSHOT_DIR"] != nil))
    func writesTheSampleFrameForReview() async throws {
        let folder = try #require(ProcessInfo.processInfo.environment["SHOTS_SNAPSHOT_DIR"])
        let scene = try #require(ShotsSamples.twoPersonWalk().scenes.first)
        let shot = try #require(scene.shots.first)
        let frame = try ShotEvaluator(scene: scene, shotID: shot.id, catalog: ContentCatalog.bundled())
            .frame(shot.guideFrames.first ?? 0)
        let image = try await ShotFrameRenderer().image(of: frame, look: PrevisLook(scene: scene))
        let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: folder).appendingPathComponent("b1-sample-guide-frame.png"))
    }

    private static func translation(_ offset: Vec3) -> Mat4 {
        var matrix = Mat4.identity
        matrix.m[12] = offset.x
        matrix.m[13] = offset.y
        matrix.m[14] = offset.z
        return matrix
    }
}

private func distance(_ point: Point2, _ other: Point2) -> Double {
    hypot(point.x - other.x, point.y - other.y)
}

/// The BGRA bytes of a rendered image.
struct Pixels {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let bytes: [UInt8]

    init(_ image: CGImage) throws {
        width = image.width
        height = image.height
        bytesPerRow = image.bytesPerRow
        let data = try #require(image.dataProvider?.data) as Data
        bytes = [UInt8](data)
    }

    func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) {
        let offset = y * bytesPerRow + x * 4
        return (Int(bytes[offset + 2]), Int(bytes[offset + 1]), Int(bytes[offset]))
    }

    func differs(from other: Pixels, at point: Point2) -> Bool {
        let x = min(max(Int(point.x), 0), width - 1), y = min(max(Int(point.y), 0), height - 1)
        let (r, g, b) = rgb(x, y), (r2, g2, b2) = other.rgb(x, y)
        return abs(r - r2) + abs(g - g2) + abs(b - b2) > 12
    }

    /// Centroids of connected regions brighter than anything the lit scene produces.
    func brightBlobs() -> [Point2] {
        var seen = Set<Int>()
        var blobs: [Point2] = []
        func bright(_ x: Int, _ y: Int) -> Bool {
            let (r, g, b) = rgb(x, y)
            return r + g + b > 690
        }
        for y in 0 ..< height {
            for x in 0 ..< width where bright(x, y) && !seen.contains(y * width + x) {
                var stack = [(x, y)]
                var sumX = 0.0, sumY = 0.0, count = 0.0
                seen.insert(y * width + x)
                while let (cx, cy) = stack.popLast() {
                    sumX += Double(cx) + 0.5
                    sumY += Double(cy) + 0.5
                    count += 1
                    for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                        let nx = cx + dx, ny = cy + dy
                        guard nx >= 0, ny >= 0, nx < width, ny < height, !seen.contains(ny * width + nx),
                              bright(nx, ny) else { continue }
                        seen.insert(ny * width + nx)
                        stack.append((nx, ny))
                    }
                }
                blobs.append(Point2(x: sumX / count, y: sumY / count))
            }
        }
        return blobs
    }
}
