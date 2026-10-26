import AppKit
import ConceptCore
@testable import ConceptStudio
import Testing

@Suite("Shots close decisions")
@MainActor
struct ShotsCloseTests {
    @Test func saveFailureVetoesImmediateAndKeepRunningQuit() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let delegate = StudioAppDelegate()
        delegate.attach(fixture.session)
        #expect(!fixture.session.needsCloseConfirmation)
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
        #expect(fixture.session.shots === fixture.store)
        #expect(fixture.session.errorMessage != nil)
        fixture.session.quitDecision = .keepRunning
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
        #expect(fixture.session.quitDecision == nil)
        try FileManager.default.removeItem(at: fixture.saveURL)
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateNow)
        #expect(try ShotsDocumentFile.load(from: fixture.saveURL).document == fixture.store.document)
    }

    @Test func saveFailureVetoesWindowCloseThenRetrySaves() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let guardDelegate = WindowCloseGuard.Coordinator(session: fixture.session)
        let window = NSWindow(contentRect: .zero, styleMask: .titled, backing: .buffered, defer: true)
        #expect(!guardDelegate.windowShouldClose(window))
        #expect(fixture.session.shots === fixture.store)
        try FileManager.default.removeItem(at: fixture.saveURL)
        #expect(guardDelegate.windowShouldClose(window))
        #expect(try ShotsDocumentFile.load(from: fixture.saveURL).document == fixture.store.document)
    }

    @Test(arguments: [StudioCloseDecision.stop(discardingPendingResult: false), .keepRunning])
    func saveFailureRefusesConfirmedClose(decision: StudioCloseDecision) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        #expect(await fixture.session.carryOut(decision) == false)
        #expect(fixture.session.project != nil)
        #expect(fixture.session.shots === fixture.store)
        #expect(fixture.store.canUndo)
        try FileManager.default.removeItem(at: fixture.saveURL)
        #expect(await fixture.session.carryOut(decision))
        #expect(try ShotsDocumentFile.load(from: fixture.saveURL).document == fixture.store.document)
        if decision != .keepRunning { #expect(fixture.session.project == nil) }
    }

    @MainActor
    private struct Fixture {
        let defaults = IsolatedDefaults()
        let directory = temporaryTestDirectory("Shots-close")
        let session: StudioSession
        let store: ShotsStore
        var saveURL: URL {
            ShotsDocumentFile.url(in: directory)
        }

        init() throws {
            session = makeTestSession(preferences: defaults.defaults)
            let project = try StudioProject.create(at: directory)
            session.project = project
            session.loadShots(for: project)
            store = try #require(session.shots)
            try store.perform(.addScene(
                id: "scene_close", name: "Practice", takeID: "take_close",
                shotID: "shot_close", cameraMarkID: "camera_close"
            ))
            try FileManager.default.createDirectory(at: saveURL, withIntermediateDirectories: true)
        }

        func remove() {
            defaults.remove()
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
