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
        let staging = try destination.stagingDirectory()
        do {
            if renderer == nil, passes.contains(where: { $0 == .clean || $0 == .matte }) {
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
                progress: progress
            )
            let manifest = try await writer.write(passes: passes)
            progress(ExportProgress(step: "Validating", fractionCompleted: 1))
            let problems = await PackageValidator.problems(at: staging)
            guard problems.isEmpty else {
                throw ShotsMediaError("The exported package isn't valid: \(problems.joined(separator: " "))")
            }
            try Task.checkCancellation()
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
        progress: @escaping @MainActor (ExportProgress) -> Void
    ) {
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
                    guides: .clean
                ) {
                    try await self.render($0, matte: nil, into: $1)
                }
            case .pose:
                try await video(
                    PackageFile(role: .control, path: "control/pose.mp4", variant: .pose, frameCount: count),
                    guides: .pose
                ) { try PassDrawing.pose($0, into: $1) }
            case .layout:
                try await video(
                    PackageFile(role: .control, path: "control/layout.mp4", variant: .layout, frameCount: count),
                    guides: .layout
                ) { try PassDrawing.layout($0, into: $1) }
            case .matte:
                for (actor, slug) in zip(actors, PackageNames.entitySlugs(actors.map(\.name))) {
                    try await matte(actor, slug: slug)
                }
            }
        }
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
            files: files
        )
        try writeJSON(manifest, to: "manifest.json")
        return manifest
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
        try await video(movie, stills: stills) { try await self.render($0, matte: actor.id, into: $1) }
    }

    private func video(
        _ file: PackageFile,
        guides variant: PackageFile.Variant,
        draw: @escaping @MainActor (SceneFrame, CVPixelBuffer) async throws -> Void
    ) async throws {
        let stills = guides.map { guide in
            PackageFile(
                role: .guide,
                path: "guides/\(guide.position.rawValue)-f\(Self.frameTag(guide.frame))-\(variant.rawValue).png",
                position: guide.position, variant: variant, frame: guide.frame
            )
        }
        try await video(file, stills: stills, draw: draw)
    }

    /// Writes one video, and each still from the very pixels of its frame.
    private func video(
        _ file: PackageFile,
        stills: [PackageFile],
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
                    step: "Writing \(file.path)",
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
                              let box = PassDrawing.projectedBounds(posed.bounds, camera: frame.camera, size: size)
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

    /// `prompt.txt` holds the prompt exactly as it goes into the graph; `prompt.json` adds its sections and facts.
    private func writePrompt(_ prompt: ShotPrompt, facts: PromptFacts) throws {
        try Data(prompt.text.utf8).write(to: prepare("prompt.txt"), options: .atomic)
        try writeJSON(PromptFile(sections: prompt.sections, text: prompt.text, facts: facts), to: "prompt.json")
        files += [
            PackageFile(role: .prompt, path: "prompt.txt"),
            PackageFile(role: .promptSections, path: "prompt.json"),
        ]
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

/// `prompt.json`.
struct PromptFile: Encodable {
    var sections: [PromptSection]
    var text: String
    var facts: PromptFacts
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
