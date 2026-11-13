import AppKit
@testable import ConceptStudio
import PrevisCore
import ShotsMedia
import SwiftUI
import Testing

/// C6's remaining Shots states for `PreviewRenderTests`. Window captures show the workspace as it opens; column
/// captures render a whole inspector or export state at the inspector column's narrowest (200) and usual (230)
/// widths, less padding, because the window's inspector scrolls and an offscreen capture shows only its top.
extension PreviewRenderTests {
    private static let inspectorColumns: [(String, CGSize)] = [
        ("narrowest", CGSize(width: 176, height: 2200)), ("usual", CGSize(width: 206, height: 2200)),
    ]

    func captureShotsStates(
        session: StudioSession, catalog: ContentCatalog, output: URL,
        filter: Set<String>, captures: inout [[String: String]]
    ) async throws {
        let sample = ShotsSamples.twoPersonWalk()
        session.shots = ShotsStore(catalog: catalog, document: sample, saveURL: nil, readOnly: true)
        try await capture(
            "shots-read-only", view: StudioRootView(session: session), output: output, filter: filter,
            captures: &captures
        )
        let store = ShotsStore(catalog: catalog, document: sample, saveURL: nil)
        session.shots = store
        store.chooseAssetForPlacement("person.man")
        try await capture(
            "shots-library-armed", view: StudioRootView(session: session), output: output, filter: filter,
            captures: &captures
        )
        store.tool = .select
        let people = try #require(store.currentScene?.entities.prefix(2).map(\.id))
        store.selection = .entities(Array(people))
        try await capture(
            "shots-inspector-entities", view: StudioRootView(session: session), output: output, filter: filter,
            captures: &captures
        )
        try await captureInspectorColumns(
            session: session, catalog: catalog, output: output, filter: filter, captures: &captures
        )
        try await captureExportStates(output: output, filter: filter, captures: &captures)
        try await capturePlateStates(
            session: session, catalog: catalog, output: output, filter: filter, captures: &captures
        )
    }

    /// Every inspector top to bottom. The shot has a stale template prompt and a length outside the trained range,
    /// so both "needs attention" notices show.
    private func captureInspectorColumns(
        session: StudioSession, catalog: ContentCatalog, output: URL,
        filter: Set<String>, captures: inout [[String: String]]
    ) async throws {
        let store = ShotsStore(catalog: catalog, document: ShotsSamples.twoPersonWalk(), saveURL: nil)
        session.shots = store
        let scene = try #require(store.currentScene)
        let shot = try #require(store.currentShot)
        let facts = try ShotPromptCompiler.facts(scene: scene, shotID: shot.id, catalog: catalog)
        try store.perform(.setPrompt(shot.id, ShotPromptCompiler.template(facts)))
        try store.perform(.setFrameCount(shot.id, 107))
        let track = try #require(scene.blocking.first?.tracks.first)
        let actorMark = try #require(track.marks.first)
        let cameraMark = try #require(shot.camera.marks.first)
        try store.perform(.setTracking(shot.id, [track.entityID]))
        let selections: [(String, ShotsSelection)] = [
            ("shot", .none), ("entity", .entities([track.entityID])), ("camera", .camera),
            ("actor-mark", .actorMark(track.entityID, actorMark.id)), ("camera-mark", .cameraMark(cameraMark.id)),
        ]
        for (name, selection) in selections {
            store.selection = selection
            try await capture(
                "shots-inspector-column-\(name)",
                view: VStack(alignment: .leading, spacing: 12) {
                    ShotsInspectorView(store: store, session: session)
                    Divider()
                    ShotsExportView(store: store, projectDirectory: session.project?.directory)
                }
                // Natural height, as in the window's scrolling inspector, rather than squeezed to the capture.
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 12).frame(maxHeight: .infinity, alignment: .top),
                output: output, filter: filter, captures: &captures, renderSizes: Self.inspectorColumns
            )
        }
    }

    private func captureExportStates(
        output: URL,
        filter: Set<String>,
        captures: inout [[String: String]]
    ) async throws {
        let states: [(String, ShotsExportControls)] = [
            ("running", ShotsExportControls(
                running: true, progress: ExportProgress(step: "Drawing the pose pass…", fractionCompleted: 0.42),
                summary: nil, unavailableReason: nil, export: {}, cancel: {}
            )),
            ("finished", ShotsExportControls(
                running: false, progress: nil, summary: "Shot package exported.", unavailableReason: nil,
                export: {}, cancel: {}
            )),
            ("unavailable", ShotsExportControls(
                running: false, progress: nil, summary: nil, unavailableReason: "Choose a shot to export it.",
                export: {}, cancel: {}
            )),
        ]
        let sizes = Self.inspectorColumns.map { ($0.0, CGSize(width: $0.1.width, height: 160)) }
        for (name, controls) in states {
            try await capture(
                "shots-export-\(name)",
                view: controls.padding(.vertical, 12).frame(maxHeight: .infinity, alignment: .top),
                output: output, filter: filter, captures: &captures, renderSizes: sizes
            )
        }
    }
}

/// Blocking over a plate: the match screen, the shot inspector with a plate, a set piece's fields, the shot camera
/// over the plate, the scene board and blocking from a description. The plate is drawn here: a wall and a floor of
/// one-metre tiles seen through the sample's camera, so a right match shows the screen's grid on the tiles.
extension PreviewRenderTests {
    private static func tiledPlate(size: PixelSize, match: PlateMatch) throws -> CGImage {
        let camera = match.camera(aspect: size.aspect)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        // The context's origin is at the bottom left; projected points have theirs at the top left.
        context.translateBy(x: 0, y: CGFloat(size.height))
        context.scaleBy(x: 1, y: -1)
        context.setFillColor(CGColor(srgbRed: 0.42, green: 0.38, blue: 0.33, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height))
        if let horizon = match.horizon(size: size) {
            context.setFillColor(CGColor(srgbRed: 0.30, green: 0.27, blue: 0.24, alpha: 1))
            context.fill(CGRect(
                x: 0, y: horizon.left.y, width: Double(size.width), height: Double(size.height) - horizon.left.y
            ))
        }
        context.setStrokeColor(CGColor(srgbRed: 0.62, green: 0.56, blue: 0.47, alpha: 1))
        context.setLineWidth(max(1, Double(size.width) / 360))
        func line(_ a: Vec3, _ b: Vec3) {
            guard let start = camera.project(a, size: size), let end = camera.project(b, size: size) else { return }
            context.move(to: CGPoint(x: start.x, y: start.y))
            context.addLine(to: CGPoint(x: end.x, y: end.y))
            context.strokePath()
        }
        for step in -12 ... 12 {
            line(Vec3(Double(step), 0, -0.6), Vec3(Double(step), 0, -30))
        }
        for step in 1 ... 30 {
            line(Vec3(-12, 0, -Double(step)), Vec3(12, 0, -Double(step)))
        }
        return try #require(context.makeImage())
    }

    func capturePlateStates(
        session: StudioSession, catalog: ContentCatalog, output: URL,
        filter: Set<String>, captures: inout [[String: String]]
    ) async throws {
        var document = ShotsSamples.plateStaging()
        let size = PixelSize(width: 720, height: 1280)
        document.scenes[0].plates[0].size = size
        let match = try #require(document.scenes[0].plates[0].match)
        let image = try Self.tiledPlate(size: size, match: match)
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("shots-preview-plates-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let destination = try #require(CGImageDestinationCreateWithURL(
            folder.appendingPathComponent("plate.png") as CFURL, "public.png" as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))

        // The match screen, with both pairs of lines on tile edges and a height reference.
        let camera = match.camera(aspect: size.aspect)
        func fraction(_ point: Vec3) throws -> Point2 {
            let pixel = try #require(camera.project(point, size: size))
            return Point2(x: pixel.x / Double(size.width), y: pixel.y / Double(size.height))
        }
        var plate = document.scenes[0].plates[0]
        plate.guides = try PlateGuides(
            linesA: [
                PlateLine(a: fraction(Vec3(-0.9, 0, -5)), b: fraction(Vec3(0.9, 0, -5))),
                PlateLine(a: fraction(Vec3(-1.6, 0, -9)), b: fraction(Vec3(1.6, 0, -9))),
            ],
            heightReference: PlateHeightReference(
                foot: fraction(Vec3(-0.5, 0, -5)), top: fraction(Vec3(-0.5, 1, -5)), height: 1
            )
        )
        try await capture(
            "shots-plate-match",
            view: ShotsPlateMatchView(plate: plate, image: image, onSave: { _ in }, onCancel: {}),
            output: output, filter: filter, captures: &captures,
            renderSizes: [("sheet", CGSize(width: 900, height: 760))]
        )

        let store = ShotsStore(catalog: catalog, document: document, saveURL: nil)
        store.plateFolder = folder
        session.shots = store
        let shot = try #require(store.currentShot)
        let people = try #require(store.currentScene?.entities.filter { $0.setPiece == nil }.map(\.id))
        try store.perform(.setAsks(shot.id, [FramingAsk(entityID: people[0], extent: .headToBoots)]))
        try store.perform(.duplicateShot(shot.id, newID: "shot_preview_second"))
        for (name, selection) in [
            ("shot", ShotsSelection.none),
            (
                "set-piece",
                .entities(store.currentScene?.entities.filter { $0.setPiece != nil }.prefix(1).map(\.id) ?? [])
            ),
        ] {
            store.selection = selection
            try await capture(
                "shots-plate-inspector-column-\(name)",
                view: ShotsInspectorView(store: store, session: session)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 12).frame(maxHeight: .infinity, alignment: .top),
                output: output, filter: filter, captures: &captures,
                renderSizes: [("usual", CGSize(width: 206, height: 3000))]
            )
        }
        store.selection = .none
        try await capture(
            "shots-plate-camera", view: ShotCameraView(store: store), output: output, filter: filter,
            captures: &captures, renderSizes: [("pane", CGSize(width: 420, height: 720))],
            settleFor: .milliseconds(2500)
        )
        try await capture(
            "shots-scene-board",
            view: ShotsSceneBoard(
                store: store, sceneID: document.scenes[0].id, projectDirectory: nil, onClose: {}
            ),
            output: output, filter: filter, captures: &captures,
            renderSizes: [("sheet", CGSize(width: 980, height: 720))], settleFor: .milliseconds(4000)
        )
        try await capture(
            "shots-blocking-sheet",
            view: ShotsBlockingSheet(store: store, session: session, sceneID: document.scenes[0].id, onClose: {}),
            output: output, filter: filter, captures: &captures,
            renderSizes: [("sheet", CGSize(width: 640, height: 460))]
        )
    }
}
