import Foundation
import PrevisCore
@testable import ShotsMedia
import Testing

/// The 2D passes, drawn without RealityKit, so they run everywhere.
@Suite("pose and layout passes")
@MainActor
struct PassDrawingTests {
    @Test func poseStillsCarryOpenPoseColoursAtTheKeypoints() throws {
        var frame = try smallSampleFrame()
        let person = Self.standingKeypoints()
        frame.entities = [
            EntityFrame(
                id: "ent_person", assetID: "person.man", name: "Man", isActor: true, position: .zero, heading: 0,
                gait: .stand, speed: 0, distanceTravelled: 0, keypoints: person,
                bounds: Box3(min: Vec3(-0.4, 0, -0.2), max: Vec3(0.4, 1.8, 0.2))
            ),
        ]
        let size = frame.canvas.pixelSize
        let pose = try Pixels(PassDrawing.image(size: size) { PassDrawing.drawPose(frame, in: $0) })
        for keypoint in person {
            let pixel = try #require(frame.camera.project(keypoint.position, size: size))
            let (red, green, blue) = PassDrawing.openPoseColors[keypoint.name.rawValue]
            #expect(pose.rgb(Int(pixel.x), Int(pixel.y)) == (red, green, blue), "\(keypoint.name) has the wrong colour")
        }
        // Limbs are drawn at 60 % of their colour: the right thigh is limb 7.
        let hip = try #require(frame.camera.project(Vec3(-0.12, 0.95, 0), size: size))
        let knee = try #require(frame.camera.project(Vec3(-0.13, 0.52, 0), size: size))
        #expect(pose.rgb(Int((hip.x + knee.x) / 2), Int((hip.y + knee.y) / 2)) == (0, 153, 51))
        #expect(pose.rgb(1, 1) == (0, 0, 0))
    }

    @Test func layoutBoxesCoverEachActorInItsColour() throws {
        var frame = try smallSampleFrame()
        let actors = frame.entities.filter(\.isActor)
        try #require(actors.count == 2)
        let labelled = try #require(frame.entities.firstIndex { $0.id == actors[0].id })
        frame.entities[labelled].label = EntityLabel(text: "Hero", color: RGB(hex: "#3366cc"))
        let size = frame.canvas.pixelSize
        let layout = try Pixels(PassDrawing.image(size: size) { PassDrawing.drawLayout(frame, in: $0) })
        func centre(_ entity: EntityFrame) throws -> (Int, Int) {
            let box = try #require(PassDrawing.projectedBounds(entity.bounds, camera: frame.camera, size: size))
            return (Int(box.midX), Int(box.midY))
        }
        let (heroX, heroY) = try centre(frame.entities[labelled])
        #expect(layout.rgb(heroX, heroY) == (0x33, 0x66, 0xCC), "the labelled actor isn't in its label colour")
        let (otherX, otherY) = try centre(actors[1])
        let (red, green, blue) = PassDrawing.layoutPalette[1]
        #expect(
            layout.rgb(otherX, otherY) == (red, green, blue),
            "the second actor isn't in the palette's second colour"
        )
        for prop in frame.entities.filter({ !$0.isActor }) {
            let (x, y) = try centre(prop)
            let covered = try actors.contains { actor in
                try #require(PassDrawing.projectedBounds(actor.bounds, camera: frame.camera, size: size))
                    .contains(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5))
            }
            if !covered { #expect(layout.rgb(x, y) == (255, 255, 255), "\(prop.name) got a layout box") }
        }
    }

    /// A person standing at the origin and facing the camera, with the head points spread wider than real
    /// proportions so no joint dot covers another.
    private static func standingKeypoints() -> [Keypoint] {
        let points: [KeypointName: Vec3] = [
            .nose: Vec3(0, 1.62, 0.1), .neck: Vec3(0, 1.45, 0),
            .rightShoulder: Vec3(-0.2, 1.42, 0), .rightElbow: Vec3(-0.3, 1.15, 0), .rightWrist: Vec3(-0.35, 0.9, 0),
            .leftShoulder: Vec3(0.2, 1.42, 0), .leftElbow: Vec3(0.3, 1.15, 0), .leftWrist: Vec3(0.35, 0.9, 0),
            .rightHip: Vec3(-0.12, 0.95, 0), .rightKnee: Vec3(-0.13, 0.52, 0), .rightAnkle: Vec3(-0.13, 0.08, 0),
            .leftHip: Vec3(0.12, 0.95, 0), .leftKnee: Vec3(0.13, 0.52, 0), .leftAnkle: Vec3(0.13, 0.08, 0),
            .rightEye: Vec3(-0.05, 1.68, 0.08), .leftEye: Vec3(0.05, 1.68, 0.08),
            .rightEar: Vec3(-0.11, 1.64, 0), .leftEar: Vec3(0.11, 1.64, 0),
        ]
        return KeypointName.allCases.compactMap { name in
            points[name].map { Keypoint(name: name, position: $0) }
        }
    }
}

/// Naming and geometry that a package depends on, checked without rendering.
@Suite("package names and bounds")
struct PackageNamingTests {
    @Test func entitySlugsNeverCollide() {
        #expect(PackageNames.entitySlugs(["Man", "Man", "Woman"]) == ["man", "man-2", "woman"])
        let slugs = PackageNames.entitySlugs(["Hero", "Hero", "Hero-2"])
        #expect(Set(slugs).count == 3, "two actors share a slug in \(slugs)")
        #expect(Array(slugs.prefix(2)) == ["hero", "hero-2"])
    }

    @Test func theValidatorReportsAPathListedTwice() async throws {
        let package = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: package) }
        try Data("{}".utf8).write(to: package.appendingPathComponent("shot.json"))
        let manifest = PackageManifest(
            format: PackageManifest.formatName, formatVersion: PackageManifest.currentFormatVersion,
            createdBy: "test", shot: ShotRef(id: "shot_1", name: "1A", sceneID: "scene_1", sceneRevision: 0),
            frameRate: 24, frameCount: 22, canvas: ShotCanvas(width: 64, height: 64),
            files: [
                PackageFile(role: .description, path: "shot.json"),
                PackageFile(role: .description, path: "shot.json"),
            ]
        )
        try JSONEncoder().encode(manifest).write(to: package.appendingPathComponent("manifest.json"))
        #expect(await PackageValidator.problems(at: package) == ["shot.json is listed more than once."])
    }

    /// Camera at the origin looking down −Z with a 90° vertical field of view: a box from depth 1 to behind the
    /// camera shows its far side at x = 352 and reaches past the canvas's right, top and bottom edges at the near
    /// plane.
    @Test func boundsThatCrossTheCameraPlaneCoverWhatTheyShow() throws {
        let camera = CameraFrame(position: .zero, pan: 0, tilt: 0, roll: 0, focalLength: 12, verticalFOV: .pi / 2)
        let bounds = Box3(min: Vec3(0.1, -0.1, -1), max: Vec3(0.2, 0.1, 1))
        let box = try #require(PassDrawing.projectedBounds(
            bounds,
            camera: camera,
            size: PixelSize(width: 640, height: 640)
        ))
        #expect(abs(box.minX - 352) < 0.5)
        #expect(box.maxX == 640 && box.minY == 0 && box.maxY == 640, "the box was cut to \(box)")
    }
}

@Suite("shot packages", .enabled(if: renderingEnabled))
@MainActor
struct PackageTests {
    @Test func eachMatteIsWhiteOnlyOverItsActor() async throws {
        let frame = try smallSampleFrame()
        let scene = try #require(ShotsSamples.twoPersonWalk(small: true).scenes.first)
        let size = frame.canvas.pixelSize
        let renderer = try ShotFrameRenderer()
        let actors = frame.entities.filter(\.isActor)
        try #require(actors.count == 2)
        for actor in actors {
            let buffer = try renderer.pixelBuffer(size)
            try await renderer.render(frame, look: PrevisLook(scene: scene), matte: actor.id, into: buffer)
            let matte = try Pixels(ShotFrameRenderer.image(from: buffer))
            let box = try #require(PassDrawing.projectedBounds(actor.bounds, camera: frame.camera, size: size))
                .insetBy(dx: -1, dy: -1)
            var inside = 0, outside = 0
            for y in 0 ..< matte.height {
                for x in 0 ..< matte.width {
                    let (red, green, blue) = matte.rgb(x, y)
                    guard red + green + blue > 600 else { continue }
                    if box.contains(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)) {
                        inside += 1
                    } else {
                        outside += 1
                    }
                }
            }
            #expect(outside == 0, "\(actor.name)'s matte is white outside the actor")
            #expect(inside > 100, "\(actor.name)'s matte is nearly empty")
        }
    }

    /// IT1, the suite's one full-length export, through the command line.
    @Test func theFullSampleExportsAValidPackage() async throws {
        let out = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: out) }
        #expect(await ShotsCommandLine.run(arguments: ["--sample", "--out", out.path]) == 0)
        let package = try Self.onlyPackage(in: out)
        #expect(await PackageValidator.problems(at: package) == [])
        let manifest = try JSONDecoder().decode(
            PackageManifest.self, from: Data(contentsOf: package.appendingPathComponent("manifest.json"))
        )
        #expect(manifest.frameCount == 124 && manifest.canvas == ShotCanvas(width: 640, height: 1152))
        #expect(manifest.passes == PassKind.allCases)
        let roles = Dictionary(grouping: manifest.files, by: \.role).mapValues(\.count)
        // 3 guide frames × clean, pose, layout; pose and layout videos; the clean video; two actors' mattes with a
        // still at each guide frame; shot.json.
        #expect(roles == [.guide: 9, .control: 2, .reference: 1, .matte: 8, .description: 1])
    }

    @Test func theValidatorNamesAMissingFile() async throws {
        let parent = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: parent) }
        let package = try await Self.exportSmallSample(to: parent).url
        #expect(await PackageValidator.problems(at: package) == [])
        try FileManager.default.removeItem(at: package.appendingPathComponent("control/layout.mp4"))
        #expect(await PackageValidator.problems(at: package) == ["control/layout.mp4 is listed but missing."])
    }

    @Test func aCancelledExportLeavesNothingBehind() async throws {
        let parent = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: parent) }
        let box = ExportTaskBox()
        box.task = Task {
            try await Self.exportSmallSample(to: parent) { _ in
                if let task = box.task, !task.isCancelled { Task { task.cancel() } }
            }
        }
        let task = try #require(box.task)
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path) == [])
    }

    private static func exportSmallSample(
        to parent: URL,
        progress: @escaping @MainActor (ExportProgress) -> Void = { _ in }
    ) async throws -> ExportedPackage {
        let scene = try #require(ShotsSamples.twoPersonWalk(small: true).scenes.first)
        let shot = try #require(scene.shots.first)
        return try await ShotExporter(catalog: ContentCatalog.bundled()).export(
            scene: scene, shotID: shot.id, options: .standard, to: FolderDestination(parent: parent), progress: progress
        )
    }

    private static func onlyPackage(in out: URL) throws -> URL {
        let manager = FileManager.default
        let shots = try manager.contentsOfDirectory(at: out, includingPropertiesForKeys: nil)
        try #require(shots.count == 1)
        let packages = try manager.contentsOfDirectory(at: shots[0], includingPropertiesForKeys: nil)
        try #require(packages.count == 1)
        return packages[0]
    }
}

@MainActor private final class ExportTaskBox {
    var task: Task<ExportedPackage, any Error>?
}

@MainActor private func smallSampleFrame() throws -> SceneFrame {
    let scene = try #require(ShotsSamples.twoPersonWalk(small: true).scenes.first)
    let shot = try #require(scene.shots.first)
    return try ShotEvaluator(scene: scene, shotID: shot.id, catalog: ContentCatalog.bundled())
        .frame(shot.guideFrames.first ?? 0)
}
