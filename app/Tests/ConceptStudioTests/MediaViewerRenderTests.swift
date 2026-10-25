import AppKit
@testable import ConceptStudio
import SwiftUI
import Testing

@Suite(
    "full-size viewer layout previews",
    .enabled(if: ProcessInfo.processInfo.environment["CONCEPTSTUDIO_RENDER_PREVIEWS"] == "1")
)
@MainActor
struct MediaViewerRenderTests {
    @Test func renderViewerOverContactSheet() async throws {
        let suite = "ConceptStudio.viewer-previews." + UUID().uuidString
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = StudioSession(preferences: preferences, demoDirectory: folder)
        session.useDemo()
        await session.task?.value
        let image = try #require(session.project?.images.first)
        session.step = .images
        session.project?.mediaState.origins[image.id] = "Apple Photos"
        let item = MediaViewerItem.project(image.id)
        let selection = try #require(MediaViewerSelection(
            item: item, items: MediaViewerItem.projects(session.project?.images ?? [])
        ))
        let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CONCEPTSTUDIO_PREVIEW_OUTPUT"]
            ?? "/tmp/conceptstudio-viewer-previews")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let previews = PreviewRenderTests()
        await previews.prewarmThumbnails(session.project?.images.map(\.url) ?? [])
        var captures: [[String: String]] = []
        try await previews.capture(
            "full-size-viewer", view: StudioRootView(session: session).overlay {
                MediaViewer(session: session, selection: .constant(selection), close: {})
            }, output: output, filter: [], captures: &captures, settleFor: .milliseconds(200)
        )
        let render = MediaViewerItem.render(
            url: image.url, title: "Base model · Seed 42", prompt: "A synthetic demo comparison prompt.",
            source: "Synthetic report layout fixture"
        )
        let rendered = try #require(MediaViewerSelection(item: render, items: [render]))
        try await previews.capture(
            "report-full-size-viewer", view: MediaViewer(
                session: session, selection: .constant(rendered), close: {}
            ), output: output, filter: [], captures: &captures, settleFor: .milliseconds(200)
        )
    }
}
