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
