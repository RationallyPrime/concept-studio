import CoreGraphics
import Foundation
import ImageIO
import PrevisCore
@testable import ShotsMedia
import Testing
import UniformTypeIdentifiers

/// A shot blocked over a plate, exported: the composition guide for the image model, the staging in words, and
/// control that agrees with both.
@MainActor @Suite(.enabled(
    if: ShotFrameRenderer.isAvailable && ProcessInfo.processInfo.environment["SHOTS_SKIP_RENDER"] == nil
))
struct PlateExportTests {
    private static let plateSize = PixelSize(width: 360, height: 640)

    /// A project folder holding a plate image whose every pixel says where it is: red rises to the right, green
    /// rises downward, blue is fixed. A copied pixel can then be told from a painted one.
    private func project() throws -> URL {
        let project = FileManager.default.temporaryDirectory
            .appendingPathComponent("shots-plate-\(UUID().uuidString)", isDirectory: true)
        let folder = PlateImages.folder(inProject: project)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let size = Self.plateSize
        var bytes = [UInt8](repeating: 255, count: size.width * size.height * 4)
        for y in 0 ..< size.height {
            for x in 0 ..< size.width {
                let offset = (y * size.width + x) * 4
                bytes[offset] = UInt8(x * 255 / (size.width - 1))
                bytes[offset + 1] = UInt8(y * 255 / (size.height - 1))
                bytes[offset + 2] = 40
            }
        }
        try writePlatePixels(bytes, size: size, to: folder.appendingPathComponent("plate.png"))
        return project
    }

    private func writePlatePixels(_ bytes: [UInt8], size: PixelSize, to url: URL) throws {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        let image = try #require(CGImage(
            width: size.width, height: size.height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: size.width * 4, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
        try StillWriter.writePNG(image, to: url)
    }

    private func scene() -> PrevisScene {
        var scene = ShotsSamples.plateStaging().scenes[0]
        scene.plates[0].size = Self.plateSize
        scene.shots[0].keyCanvas = nil // the plate's own size
        scene.shots[0].canvas = ShotCanvas(width: 288, height: 512)
        return scene
    }

    private func pixels(_ url: URL) throws -> (width: Int, height: Int, rgba: [UInt8]) {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return (image.width, image.height, bytes)
    }

    @Test func aShotOverAPlateExportsTheGuideTheWordsAndControlThatAgree() async throws {
        let project = try project()
        defer { try? FileManager.default.removeItem(at: project) }
        let scene = scene()
        let catalog = try ContentCatalog.bundled()
        let package = try await ShotExporter(catalog: catalog).export(
            scene: scene, shotID: scene.shots[0].id, options: .standard(inProject: project),
            to: FolderDestination(parent: project.appendingPathComponent("Shots")), progress: { _ in }
        )
        #expect(await PackageValidator.problems(at: package.url).isEmpty)
        #expect(package.manifest.keyCanvas == ShotCanvas(width: 360, height: 640))
        #expect(package.manifest.plate?.name == "Hall C")

        // The guide is the key's size, and where nobody stands it is the plate, pixel for pixel.
        let guide = try pixels(package.url.appendingPathComponent("guides/first-f0000-composition.png"))
        #expect(guide.width == 360 && guide.height == 640)
        let staging = try ShotEvaluator(scene: scene, shotID: scene.shots[0].id, catalog: catalog).staging()
        let woman = try #require(staging.characters.first { $0.name == "Woman" })
        let box = try #require(woman.box)
        func at(_ x: Int, _ y: Int, in image: (width: Int, height: Int, rgba: [UInt8])) -> [Int] {
            let offset = (y * image.width + x) * 4
            return [Int(image.rgba[offset]), Int(image.rgba[offset + 1]), Int(image.rgba[offset + 2])]
        }
        var painted = 0, changedOutside = 0
        for y in 0 ..< 640 {
            for x in 0 ..< 360 {
                let pixel = at(x, y, in: guide)
                let plate = [x * 255 / 359, y * 255 / 639, 40]
                let isPlate = zip(pixel, plate).allSatisfy { abs($0 - $1) <= 2 }
                guard !isPlate else { continue }
                painted += 1
                // Every painted pixel belongs to a stand-in: inside one of the characters' boxes, with a margin.
                let inside = staging.characters.contains { character in
                    guard let box = character.box else { return false }
                    return Double(x) >= box.x * 360 - 12 && Double(x) <= (box.x + box.width) * 360 + 12
                        && Double(y) >= box.y * 640 - 12 && Double(y) <= (box.y + box.height) * 640 + 12
                }
                if !inside { changedOutside += 1 }
            }
        }
        #expect(painted > 2000)
        #expect(changedOutside == 0)
        // The woman's stand-in is the blue of the legend, at the middle of her visible part.
        let chest = at(Int((box.x + box.width / 2) * 360), Int((box.y + box.height * 0.45) * 640), in: guide)
        #expect(chest[2] > chest[0] + 40 && chest[2] > chest[1])

        // The words name the plate, the stand-in and what hides her.
        let words = try String(contentsOf: package.url.appendingPathComponent("staging.txt"), encoding: .utf8)
        #expect(words.contains("Woman (blue stand-in)") && words.contains("the Long table hides the rest"))

        // Control at frame 0 agrees with the guide: the layout box of the woman covers the same rows of the
        // frame as her visible part in the guide, and no pose joint is drawn where the table hides her.
        let layout = try pixels(package.url.appendingPathComponent("guides/first-f0000-layout.png"))
        var layoutTop = 512, layoutBottom = 0
        let column = Int((box.x + box.width / 2) * 288)
        for y in 0 ..< 512 where at(column, y, in: layout) != [255, 255, 255] {
            layoutTop = min(layoutTop, y)
            layoutBottom = max(layoutBottom, y + 1)
        }
        #expect(abs(Double(layoutBottom) / 512 - (box.y + box.height)) < 0.03)
        #expect(Double(layoutTop) / 512 < box.y + 0.03)
        let pose = try pixels(package.url.appendingPathComponent("guides/first-f0000-pose.png"))
        let hiddenFrom = Int((box.y + box.height) * 512) + 14
        let tableBottom = Int(0.86 * 512)
        var drawnBehindTable = 0
        for y in hiddenFrom ..< min(hiddenFrom + 30, tableBottom) {
            for x in max(0, column - 20) ..< min(288, column + 20) where at(x, y, in: pose) != [0, 0, 0] {
                drawnBehindTable += 1
            }
        }
        #expect(drawnBehindTable == 0)
    }

    private let green: [UInt8] = [15, 223, 64]
    private let orange: [UInt8] = [242, 117, 26]

    private func pullbackScene(in project: URL) throws -> PrevisScene {
        let folder = PlateImages.folder(inProject: project)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let size = PixelSize(width: 320, height: 320)
        func match(_ position: Vec3, pan: Double = 0, tilt: Double = 0) -> PlateMatch {
            PlateMatch(position: position, pan: pan, tilt: tilt, roll: 0, focalLength: 20, sensor: .super35)
        }
        let front = match(Vec3(0, 1, 5))
        let side = match(Vec3(5, 1, 0), pan: .pi / 2)
        let ending = match(Vec3(4, 3, 7), pan: atan2(4, 7), tilt: -atan2(2, hypot(4, 7)))
        let frontPlate = LocationPlate(
            id: "plate_000000000001", name: "Front", file: "front.png", size: size, match: front, guides: .none
        )
        let sidePlate = LocationPlate(
            id: "plate_000000000002", name: "Side", file: "side.png", size: size, match: side, guides: .none
        )
        // Two surveyed paint marks in dais-local metres: (-0.3, 1.15, 1) on the platform face and
        // (1, 0.85, -1.16) on the side of the first step, beyond the platform body. Pixel coordinates
        // below are independent pinhole projections (320 * 20 / 18.66 pixels focal length, yaw 0.15).
        func writePlate(_ plate: LocationPlate, center: (Int, Int), color: [UInt8], grey: UInt8) throws {
            var bytes = [UInt8](repeating: grey, count: size.width * size.height * 4)
            for y in center.1 - 6 ... center.1 + 6 {
                for x in center.0 - 6 ... center.0 + 6 {
                    let offset = (y * size.width + x) * 4
                    bytes.replaceSubrange(offset ..< offset + 3, with: color)
                }
            }
            try writePlatePixels(bytes, size: size, to: folder.appendingPathComponent(plate.file))
        }
        try writePlate(frontPlate, center: (147, 147), color: green, grey: 142)
        try writePlate(sidePlate, center: (266, 172), color: orange, grey: 186)
        let dais = SetPiece(kind: .dais, size: Vec3(2, 2, 2), steps: 2, inPlate: true)
        let entity = PrevisEntity(
            id: "ent_000000000001", assetID: dais.assetID, name: "Marked dais",
            placement: Placement(position: .zero, heading: 0.15, scale: 1), setPiece: dais
        )
        var shot = Shot.make(
            id: "shot_000000000001", name: "Pullback", takeID: "take_000000000001", cameraMarkID: "cam_000000000001"
        )
        shot.frameCount = 5
        shot.canvas = ShotCanvas(width: size.width, height: size.height)
        shot.plateID = frontPlate.id
        var last = ending.cameraMark(id: "cam_000000000002")
        last.time = FrameGrid.time(ofFrame: 4)
        shot.camera.marks = [front.cameraMark(id: "cam_000000000001"), last]
        return PrevisScene(
            id: "scene_000000000001", name: "Two views of a dais", revision: 0, lighting: .interiorWarm,
            entities: [entity], blocking: [BlockingTake(id: shot.blockingTakeID, name: "Master")],
            shots: [shot], plates: [frontPlate, sidePlate]
        )
    }

    @Test func pullingBackOverTwoPlatesPlacesEachLandmarkAndMarksTheUnseenTop() async throws {
        let project = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: project) }
        let scene = try pullbackScene(in: project)
        let shot = try #require(scene.shots.first)
        let frontPlate = try #require(scene.plates.first)
        let folder = PlateImages.folder(inProject: project)
        let package = try await ShotExporter(catalog: ContentCatalog.bundled()).export(
            scene: scene, shotID: shot.id, options: .standard(inProject: project),
            to: FolderDestination(parent: project.appendingPathComponent("Shots")), progress: { _ in }
        )
        #expect(await PackageValidator.problems(at: package.url).isEmpty)
        let original = try pixels(folder.appendingPathComponent(frontPlate.file))
        for variant in [PackageFile.Variant.composition, .compositionLabelled] {
            let first = try #require(package.manifest.files.first {
                $0.role == .guide && $0.position == .first && $0.frame == 0 && $0.variant == variant
            })
            let firstImage = try pixels(package.url.appendingPathComponent(first.path))
            #expect(firstImage.rgba == original.rgba)
            let last = try #require(package.manifest.files.first {
                $0.role == .guide && $0.position == .last && $0.frame == 4 && $0.variant == variant
            })
            let image = try pixels(package.url.appendingPathComponent(last.path))
            #expect(image.width == frontPlate.size.width && image.height == frontPlate.size.height)
            func rgb(_ x: Int, _ y: Int) -> [UInt8] {
                let offset = (y * image.width + x) * 4
                return Array(image.rgba[offset ..< offset + 3])
            }
            // Check the unique landmark's centroid as well as its presence. A same-view copy, mirrored
            // camera, bounding-box approximation, or missing second photograph cannot satisfy both marks.
            func centroid(of color: [UInt8]) throws -> Point2 {
                var count = 0, sumX = 0.0, sumY = 0.0
                for y in 0 ..< image.height {
                    for x in 0 ..< image.width where rgb(x, y) == color {
                        count += 1
                        sumX += Double(x) + 0.5
                        sumY += Double(y) + 0.5
                    }
                }
                try #require(count >= 3)
                return Point2(x: sumX / Double(count), y: sumY / Double(count))
            }
            let a = try centroid(of: green)
            let b = try centroid(of: orange)
            #expect(hypot(a.x - 130.59, a.y - 162.43) < 2)
            #expect(hypot(b.x - 211.25, b.y - 158.94) < 2)
            // Both source cameras are below the dais top. Its projected centre crosses a checker boundary.
            #expect(rgb(160, 116) == [97, 44, 89])
            #expect(rgb(160, 121) == [36, 33, 41])
        }
    }

    @Test(arguments: [false, true])
    func unavailableAuxiliaryPhotoLeavesTheSameGuideAsOmittingIt(exactEndpoint: Bool) async throws {
        let project = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: project) }
        let folder = PlateImages.folder(inProject: project)
        var scene = try pullbackScene(in: project)
        let auxiliary = scene.plates.removeLast()
        if exactEndpoint {
            let match = try #require(auxiliary.match)
            var endpoint = match.cameraMark(id: "cam_000000000002")
            endpoint.time = FrameGrid.time(ofFrame: 4)
            scene.shots[0].camera.marks[1] = endpoint
        }
        func endingGuide(_ scene: PrevisScene, in directory: String) async throws -> [UInt8] {
            let package = try await ShotExporter(catalog: ContentCatalog.bundled()).export(
                scene: scene, shotID: scene.shots[0].id, options: ExportOptions(passes: [.layout], plateFolder: folder),
                to: FolderDestination(parent: project.appendingPathComponent(directory)), progress: { _ in }
            )
            let guide = try #require(package.manifest.files
                .first { $0.position == .last && $0.variant == .composition })
            return try pixels(package.url.appendingPathComponent(guide.path)).rgba
        }
        let baseline = try await endingGuide(scene, in: "baseline")
        var absent = auxiliary
        absent.file = "unavailable.png"
        scene.plates.append(absent)
        let missing = try await endingGuide(scene, in: "missing")
        #expect(missing == baseline)
        try Data("invalid PNG".utf8).write(to: folder.appendingPathComponent(absent.file))
        let unreadable = try await endingGuide(scene, in: "unreadable")
        #expect(unreadable == baseline)
    }

    @Test(arguments: ["../plate.png", "/etc/hosts", "sub/plate.png", "..", ""])
    func aPlateFileNameThatLeavesThePlatesFolderIsRefused(file: String) async throws {
        let project = try project()
        defer { try? FileManager.default.removeItem(at: project) }
        // The image exists one folder up, where "../plate.png" would find it.
        try FileManager.default.copyItem(
            at: PlateImages.folder(inProject: project).appendingPathComponent("plate.png"),
            to: project.appendingPathComponent("Shots/plate.png")
        )
        var scene = scene()
        scene.plates[0].file = file
        let catalog = try ContentCatalog.bundled()
        #expect(ShotsValidation.problems(in: ShotsDocument(version: 2, scenes: [scene]), catalog: catalog)
            .contains { $0.severity == .error && $0.message.contains("Shots/Plates") })
        #expect(throws: ShotsMediaError.self) {
            try PlateImages.url(of: scene.plates[0], in: PlateImages.folder(inProject: project))
        }
        await #expect(throws: ShotsMediaError.self) {
            try await ShotExporter(catalog: catalog).export(
                scene: scene, shotID: scene.shots[0].id, options: .standard(inProject: project),
                to: FolderDestination(parent: project.appendingPathComponent("Out")), progress: { _ in }
            )
        }
    }

    @Test func aPlateShotWithoutItsImageIsRefusedInWords() async throws {
        let scene = scene()
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("shots-noplate-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        await #expect(throws: ShotsMediaError.self) {
            try await ShotExporter(catalog: ContentCatalog.bundled()).export(
                scene: scene, shotID: scene.shots[0].id, options: .standard(inProject: empty),
                to: FolderDestination(parent: empty.appendingPathComponent("Shots")), progress: { _ in }
            )
        }
        // Nothing is left behind: no package and no staging folder.
        let left = (try? FileManager.default.contentsOfDirectory(atPath: empty.appendingPathComponent("Shots").path))
            ?? []
        #expect(left.isEmpty)
    }

    @Test func aPlateWithAnOrientationTagIsReadTheWayItIsSeen() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("shots-sideways-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // 40 × 20 stored pixels, tagged as shot with the camera on its side: seen, it is 20 × 40.
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let provider = try #require(CGDataProvider(data: Data([UInt8](repeating: 200, count: 40 * 20 * 4)) as CFData))
        let stored = try #require(CGImage(
            width: 40, height: 20, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 40 * 4, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
        let url = folder.appendingPathComponent("sideways.jpg")
        let destination = try #require(
            CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        )
        CGImageDestinationAddImage(destination, stored, [kCGImagePropertyOrientation: 6] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        #expect(PlateImages.pixelSize(of: url) == PixelSize(width: 20, height: 40))
        let read = try PlateImages.read(url, name: "Sideways")
        #expect(read.width == 20 && read.height == 40)
    }
}
