import CoreGraphics
import CoreVideo
import Foundation
import PrevisCore

/// Builds a shot package in the destination's staging folder, validates it there, then delivers it.
@MainActor public final class ShotExporter {
    public let catalog: ContentCatalog
    private var renderer: ShotFrameRenderer?

    public init(catalog: ContentCatalog) throws {
        self.catalog = catalog
    }

    /// Validates before delivering. Cancelling the Task leaves no staged or partial package.
    public func export(
        scene: PrevisScene,
        shotID: ShotID,
        options: ExportOptions,
        to destination: any PackageDestination,
        progress: @escaping @MainActor (ExportProgress) -> Void
    ) async throws -> ExportedPackage {
        let evaluator = try ShotEvaluator(scene: scene, shotID: shotID, catalog: catalog)
        guard let shot = scene.shots.first(where: { $0.id == shotID }) else {
            throw ShotsMediaError("Scene \"\(scene.name)\" has no shot \(shotID).")
        }
        let passes = PassKind.allCases.filter(options.passes.contains)
        let plate = shot.plateID.flatMap { id in scene.plates.first { $0.id == id } }
        let plateImage = try plate.map { plate in
            guard let folder = options.plateFolder else {
                throw ShotsMediaError(
                    "Shot \"\(shot.name)\" is blocked over the plate \"\(plate.name)\", and this export wasn't "
                        + "told where the project's plate images are."
                )
            }
            return try PlateImages.read(PlateImages.url(of: plate, in: folder), name: plate.name)
        }
        let staging = try destination.stagingDirectory()
        do {
            if renderer == nil, plateImage != nil || passes.contains(where: { $0 == .clean || $0 == .matte }) {
                renderer = try ShotFrameRenderer()
            }
            let writer = try PackageWriter(
                scene: scene,
                shot: shot,
                frames: (0 ..< evaluator.frameCount).map { evaluator.frame($0) },
                folder: staging,
                renderer: renderer,
                promptFacts: shot.prompt.map { _ in
                    try ShotPromptCompiler.facts(scene: scene, shotID: shotID, catalog: catalog)
                },
                plateImage: plateImage,
                staged: evaluator.staging(),
                warnings: evaluator.warnings().map(\.message),
                progress: progress
            )
            let manifest = try await writer.write(passes: passes)
            progress(ExportProgress(step: "Checking the package…", fractionCompleted: 1))
            let problems = await PackageValidator.problems(at: staging)
            // Cancelled while checking, the validator can't read the videos; that is the cancellation, not a fault.
            try Task.checkCancellation()
            guard problems.isEmpty else {
                throw ShotsMediaError("The exported package isn't valid: \(problems.joined(separator: " "))")
            }
            let url = try await destination.deliver(staged: staging, manifest: manifest)
            return ExportedPackage(url: url, manifest: manifest)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }
}

/// Writes one package's files into a folder and returns its manifest (CONTRACTS section 8.3).
@MainActor final class PackageWriter {
    private let scene: PrevisScene
    private let shot: Shot
    private let frames: [SceneFrame]
    private let folder: URL
    private let renderer: ShotFrameRenderer?
    private let promptFacts: PromptFacts?
    private let plate: LocationPlate?
    private let plateImage: CGImage?
    private let staged: Staging?
    private let warnings: [String]
    private let look: PrevisLook
    private let progress: @MainActor (ExportProgress) -> Void
    private let guides: [(position: PackageFile.Position, frame: Int)]
    private var files: [PackageFile] = []
    private var videosDone = 0
    private var videoCount = 0

    init(
        scene: PrevisScene,
        shot: Shot,
        frames: [SceneFrame],
        folder: URL,
        renderer: ShotFrameRenderer?,
        promptFacts: PromptFacts? = nil,
        plateImage: CGImage? = nil,
        staged: Staging? = nil,
        warnings: [String] = [],
        progress: @escaping @MainActor (ExportProgress) -> Void
    ) {
        plate = shot.plateID.flatMap { id in scene.plates.first { $0.id == id } }
        self.plateImage = plateImage
        self.staged = staged
        self.warnings = warnings
        self.promptFacts = promptFacts
        self.scene = scene
        self.shot = shot
        self.frames = frames
        self.folder = folder
        self.renderer = renderer
        self.progress = progress
        look = PrevisLook(scene: scene)
        let last = frames.count - 1
        guides = [(.first, 0)] + shot.guideFrames.filter { $0 > 0 && $0 < last }.map { (.middle, $0) } + [(.last, last)]
    }

    func write(passes: [PassKind]) async throws -> PackageManifest {
        guard let first = frames.first else { throw ShotsMediaError("Shot \"\(shot.name)\" has no frames to export.") }
        let actors = first.entities.filter(\.isActor)
        videoCount = passes.reduce(0) { $0 + ($1 == .matte ? actors.count : 1) }
        let count = frames.count
        for pass in passes {
            switch pass {
            case .clean:
                try await video(
                    PackageFile(role: .reference, path: "reference/clean.mp4", variant: .clean, frameCount: count),
                    guides: .clean, step: "Rendering the clean pass…"
                ) {
                    try await self.render($0, matte: nil, into: $1)
                }
            case .pose:
                try await video(
                    PackageFile(role: .control, path: "control/pose.mp4", variant: .pose, frameCount: count),
                    guides: .pose, step: "Drawing the pose pass…"
                ) { try PassDrawing.pose($0, into: $1) }
            case .layout:
                try await video(
                    PackageFile(role: .control, path: "control/layout.mp4", variant: .layout, frameCount: count),
                    guides: .layout, step: "Drawing the layout pass…"
                ) { try PassDrawing.layout($0, into: $1) }
            case .matte:
                for (actor, slug) in zip(actors, PackageNames.entitySlugs(actors.map(\.name))) {
                    try await matte(actor, slug: slug)
                }
            }
        }
        try await writeCompositionGuides()
        try writeStaging()
        try writeDescription()
        if let prompt = shot.prompt, let promptFacts {
            try writePrompt(prompt, facts: promptFacts)
        }
        let manifest = PackageManifest(
            format: PackageManifest.formatName,
            formatVersion: PackageManifest.currentFormatVersion,
            createdBy: "ConceptStudio "
                +
                (Bundle.main
                    .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development build"),
            shot: ShotRef(id: shot.id, name: shot.name, sceneID: scene.id, sceneRevision: scene.revision),
            frameRate: FrameGrid.fps,
            frameCount: frames.count,
            canvas: shot.canvas,
            passes: passes,
            files: files,
            keyCanvas: plateImage == nil ? nil : keyCanvas,
            plate: plateImage == nil ? nil : plate.map {
                PlateRef(id: $0.id, name: $0.name, file: $0.file, size: $0.size)
            }
        )
        try writeJSON(manifest, to: "manifest.json")
        return manifest
    }

    /// The size of the key the image model makes: the shot's own, or else the plate's, or else the canvas.
    private var keyCanvas: ShotCanvas {
        shot.keyCanvas ?? plate.map { ShotCanvas(width: $0.size.width, height: $0.size.height) } ?? shot.canvas
    }

    /// The plate with neutral stand-ins at the key's size, for the image model to compose from, and the same with
    /// name tags for people. The first frame always; the last frame too when the camera is still the plate's.
    private func writeCompositionGuides() async throws {
        guard let plateImage, let plate, let renderer else { return }
        progress(ExportProgress(step: "Drawing the composition guide over the plate…", fractionCompleted: 1))
        var wanted: [(position: PackageFile.Position, frame: Int)] = [(.first, 0)]
        let last = frames.count - 1
        if last > 0, let match = plate.match, match.agrees(with: frames[last].camera),
           Self.blockingDiffers(frames[0], frames[last]) {
            wanted.append((.last, last))
        }
        for guide in wanted {
            for (variant, options) in [
                (PackageFile.Variant.composition, StandInOptions.guide),
                (.compositionLabelled, .labelledGuide),
            ] {
                let image = try await renderer.image(
                    of: frames[guide.frame], over: plateImage, look: look, options: options,
                    sensor: shot.camera.sensor, size: keyCanvas.pixelSize
                )
                let file = PackageFile(
                    role: .guide,
                    path: "guides/\(guide.position.rawValue)-f\(Self.frameTag(guide.frame))-\(variant.rawValue).png",
                    position: guide.position, variant: variant, frame: guide.frame
                )
                try StillWriter.writePNG(image, to: prepare(file.path))
                files.append(file)
            }
        }
    }

    /// Whether anyone stands, faces or is posed differently in two frames, beyond a standing figure's idle sway.
    private static func blockingDiffers(_ a: SceneFrame, _ b: SceneFrame) -> Bool {
        zip(a.entities, b.entities).contains { first, second in
            let moved = Vec3(
                first.position.x - second.position.x, first.position.y - second.position.y,
                first.position.z - second.position.z
            )
            let distance = (moved.x * moved.x + moved.y * moved.y + moved.z * moved.z).squareRoot()
            return distance > 0.02 || abs(first.heading - second.heading) > 0.01 || first.gait != second.gait
                || first.joints != second.joints
        }
    }

    /// `staging.txt` is the first frame's staging in words, ready to paste beside the composition guide;
    /// `staging.json` is the same as data.
    private func writeStaging() throws {
        guard let staged else { return }
        var text = staged.description() + "\n\n" + staged.legend() + "\n"
        if !warnings.isEmpty {
            text += "\nTo look at before making the key:\n" + warnings.map { "- \($0)" }.joined(separator: "\n") + "\n"
        }
        try Data(text.utf8).write(to: prepare("staging.txt"), options: .atomic)
        try writeJSON(
            StagingFile(staged, shot: shot, plate: plate, keyCanvas: keyCanvas, warnings: warnings),
            to: "staging.json"
        )
        files += [
            PackageFile(role: .staging, path: "staging.txt"),
            PackageFile(role: .stagingData, path: "staging.json"),
        ]
    }

    private func matte(_ actor: EntityFrame, slug: String) async throws {
        let movie = PackageFile(
            role: .matte, path: "mattes/\(slug).mp4", frameCount: frames.count, entityID: actor.id,
            entityName: actor.name
        )
        let stills = guides.map { guide in
            PackageFile(
                role: .matte, path: "mattes/\(slug)-f\(Self.frameTag(guide.frame)).png", frame: guide.frame,
                entityID: actor.id, entityName: actor.name
            )
        }
        try await video(movie, stills: stills, step: "Rendering the matte of \(actor.name)…") {
            try await self.render($0, matte: actor.id, into: $1)
        }
    }

    private func video(
        _ file: PackageFile,
        guides variant: PackageFile.Variant,
        step: String,
        draw: @escaping @MainActor (SceneFrame, CVPixelBuffer) async throws -> Void
    ) async throws {
        let stills = guides.map { guide in
            PackageFile(
                role: .guide,
                path: "guides/\(guide.position.rawValue)-f\(Self.frameTag(guide.frame))-\(variant.rawValue).png",
                position: guide.position, variant: variant, frame: guide.frame
            )
        }
        try await video(file, stills: stills, step: step, draw: draw)
    }

    /// Writes one video, and each still from the very pixels of its frame. `step` is what Lane C shows meanwhile,
    /// in plain words, as Blockout's "Rendering <pass> pass…" (`src/renderer/export/exporter.ts:295`).
    private func video(
        _ file: PackageFile,
        stills: [PackageFile],
        step: String,
        draw: @escaping @MainActor (SceneFrame, CVPixelBuffer) async throws -> Void
    ) async throws {
        let url = try prepare(file.path)
        let stillsByFrame = Dictionary(grouping: stills) { $0.frame ?? -1 }
        let done = Double(videosDone), total = Double(max(videoCount, 1)), count = Double(frames.count)
        try await VideoWriter.write(
            to: url,
            size: shot.canvas.pixelSize,
            frameCount: frames.count,
            progress: { index in
                self.progress(ExportProgress(
                    step: step,
                    fractionCompleted: (done + Double(index + 1) / count) / total
                ))
            },
            draw: { buffer, index in
                try await draw(self.frames[index], buffer)
                for still in stillsByFrame[index] ?? [] {
                    try StillWriter.writePNG(ShotFrameRenderer.image(from: buffer), to: self.prepare(still.path))
                }
            }
        )
        files.append(file)
        files += stills
        videosDone += 1
    }

    private func render(_ frame: SceneFrame, matte: EntityID?, into buffer: CVPixelBuffer) async throws {
        guard let renderer else { throw ShotsMediaError("Rendering needs a Metal device, and this Mac has none.") }
        try await renderer.render(frame, look: look, matte: matte, into: buffer)
    }

    private func writeDescription() throws {
        let size = shot.canvas.pixelSize
        let take = scene.blocking.first { $0.id == shot.blockingTakeID }
        let description = ShotDescription(
            shot: ShotDescription.ShotInfo(
                id: shot.id, name: shot.name, sceneID: scene.id, sceneRevision: scene.revision,
                frameCount: frames.count, frameRate: FrameGrid.fps, canvas: shot.canvas
            ),
            guides: guides.map { ShotDescription.Guide(position: $0.position, frame: $0.frame) },
            camera: ShotDescription.Camera(
                sensor: shot.camera.sensor,
                rig: shot.camera.rig,
                track: frames.enumerated().map { index, frame in
                    ShotDescription.CameraSample(
                        frame: index, position: frame.camera.position, pan: frame.camera.pan, tilt: frame.camera.tilt,
                        roll: frame.camera.roll, verticalFOV: frame.camera.verticalFOV,
                        focalLength: frame.camera.focalLength
                    )
                }
            ),
            subjects: frames[0].entities.map { entity in
                // Boxes are what the layout pass draws: cut where the set hides the actor.
                ShotDescription.Subject(
                    entityID: entity.id, name: entity.name, assetID: entity.assetID, isActor: entity.isActor,
                    marks: (take?.tracks.first { $0.entityID == entity.id }?.marks ?? []).map {
                        ShotDescription.Mark(
                            id: $0.id, time: $0.time, frame: FrameGrid.frame(atTime: $0.time), position: $0.position,
                            gait: $0.gait
                        )
                    },
                    boxes: guides.compactMap { guide in
                        let frame = frames[guide.frame]
                        guard let posed = frame.entities.first(where: { $0.id == entity.id }),
                              let box = Self.box(of: posed, in: frame, size: size)
                        else { return nil }
                        let width = Double(size.width), height = Double(size.height)
                        return ShotDescription.Box(
                            frame: guide.frame, x: box.minX / width, y: box.minY / height,
                            width: box.width / width, height: box.height / height
                        )
                    }
                )
            },
            scene: scene
        )
        try writeJSON(description, to: "shot.json")
        files.append(PackageFile(role: .description, path: "shot.json"))
    }

    /// `prompt.txt` holds the prompt exactly as it goes into the graph; `prompt.json` adds its sections, the facts as
    /// the scene now stands, the revision the prompt was written from, and anything wrong with it (stale or long).
    private func writePrompt(_ prompt: ShotPrompt, facts: PromptFacts) throws {
        try Data(prompt.text.utf8).write(to: prepare("prompt.txt"), options: .atomic)
        try writeJSON(
            PromptFile(
                sections: prompt.sections, text: prompt.text, facts: facts, sceneRevision: prompt.sceneRevision,
                problems: ShotPromptCompiler.problems(prompt, scene: scene)
            ),
            to: "prompt.json"
        )
        files += [
            PackageFile(role: .prompt, path: "prompt.txt"),
            PackageFile(role: .promptSections, path: "prompt.json"),
        ]
    }

    private static func box(of posed: EntityFrame, in frame: SceneFrame, size: PixelSize) -> CGRect? {
        guard posed.isActor,
              let staged = StagingAnalysis.characters(in: frame).first(where: { $0.entityID == posed.id })
        else { return PassDrawing.projectedBounds(posed.bounds, camera: frame.camera, size: size) }
        return PassDrawing.layoutRect(of: posed, staged: staged, camera: frame.camera, size: size)
    }

    private func writeJSON(_ value: some Encodable, to path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(value).write(to: prepare(path), options: .atomic)
    }

    private func prepare(_ path: String) throws -> URL {
        let url = folder.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return url
    }

    private static func frameTag(_ frame: Int) -> String {
        String(format: "%04d", frame)
    }
}

/// `staging.json`: the first frame's staging as data.
struct StagingFile: Encodable {
    struct Camera: Encodable {
        var position: Vec3, pan: Double, tilt: Double, roll: Double
        var focalLength: Double, verticalFOV: Double, sensor: Sensor
    }

    struct Character: Encodable {
        var entityID: EntityID, name: String
        var standIn: String, standInColor: RGB
        var isVisible: Bool
        var horizontal: String, depth: String, facing: String
        var visible: String
        var hiddenBy: [String]
        var cutByFrameEdge: String?
        var headFraction: Double, bodyFraction: Double, distance: Double
        var box: [String: Double]?
    }

    var formatVersion = 1
    var shot: String
    var plate: PlateRef?
    var canvas: ShotCanvas
    var keyCanvas: ShotCanvas
    var framing: String
    var camera: Camera
    var characters: [Character]
    var description: String
    var legend: String
    var warnings: [String]

    init(_ staged: Staging, shot: Shot, plate: LocationPlate?, keyCanvas: ShotCanvas, warnings: [String]) {
        self.shot = shot.name
        self.plate = plate.map { PlateRef(id: $0.id, name: $0.name, file: $0.file, size: $0.size) }
        canvas = staged.canvas
        self.keyCanvas = keyCanvas
        framing = staged.framing
        camera = Camera(
            position: staged.camera.position, pan: staged.camera.pan, tilt: staged.camera.tilt,
            roll: staged.camera.roll, focalLength: staged.camera.focalLength,
            verticalFOV: staged.camera.verticalFOV, sensor: staged.sensor
        )
        characters = staged.characters.enumerated().map { index, character in
            var hiddenBy: [String] = []
            var edge: String?
            switch character.cut {
            case let .hidden(names)?: hiddenBy = names
            case let .frame(name)?: edge = name
            case nil: break
            }
            return Character(
                entityID: character.entityID, name: character.name, standIn: character.standIn,
                standInColor: StandInPalette.standIn(index).color, isVisible: character.isVisible,
                horizontal: character.horizontal.rawValue, depth: character.depth.rawValue,
                facing: character.facing.rawValue, visible: character.extentPhrase, hiddenBy: hiddenBy,
                cutByFrameEdge: edge, headFraction: character.headFraction, bodyFraction: character.bodyFraction,
                distance: character.distance,
                box: character.box.map { ["x": $0.x, "y": $0.y, "width": $0.width, "height": $0.height] }
            )
        }
        description = staged.description()
        legend = staged.legend()
        self.warnings = warnings
    }
}

/// `prompt.json`.
struct PromptFile: Encodable {
    var sections: [PromptSection]
    var text: String
    var facts: PromptFacts
    var sceneRevision: Int // the revision the prompt was written from
    var problems: [String]
}

/// `shot.json`: the shot, its guides, the camera per frame and each subject, with the scene as stored.
struct ShotDescription: Encodable {
    struct ShotInfo: Encodable {
        var id: ShotID, name: String, sceneID: SceneID, sceneRevision: Int
        var frameCount: Int, frameRate: Int, canvas: ShotCanvas
    }

    struct Guide: Encodable {
        var position: PackageFile.Position, frame: Int
    }

    struct Camera: Encodable {
        var sensor: Sensor, rig: Rig, track: [CameraSample]
    }

    struct CameraSample: Encodable {
        var frame: Int, position: Vec3, pan: Double, tilt: Double, roll: Double
        var verticalFOV: Double, focalLength: Double
    }

    struct Subject: Encodable {
        var entityID: EntityID, name: String, assetID: String, isActor: Bool
        var marks: [Mark], boxes: [Box]
    }

    struct Mark: Encodable {
        var id: MarkID, time: Double, frame: Int, position: Vec3, gait: Gait
    }

    /// Normalised to the canvas.
    struct Box: Encodable {
        var frame: Int, x: Double, y: Double, width: Double, height: Double
    }

    var formatVersion = 1
    var shot: ShotInfo
    var guides: [Guide]
    var camera: Camera
    var subjects: [Subject]
    var scene: PrevisScene
}
