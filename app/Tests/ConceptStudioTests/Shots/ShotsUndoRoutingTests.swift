import AppKit
@testable import ConceptStudio
import PrevisCore
import SwiftUI
import Testing

@Suite("Shots Edit commands")
@MainActor
struct ShotsUndoRoutingTests {
    @Test func commandsUseTheOwningSessionAndRestoreOtherWindowsAndWorkspaces() throws {
        let defaults = IsolatedDefaults()
        defer { defaults.remove() }
        let session = makeTestSession(preferences: defaults.defaults)
        let store = try makeStore()
        session.shots = store
        session.workspace = .shots
        let studio = makeWindow(), help = makeWindow()
        defer { studio.close(); help.close() }
        let owner = WindowCloseGuard.Coordinator(session: session)
        studio.delegate = owner
        var current = studio
        let state = ShotsUndoCommandState(currentWindow: { current })
        #expect(state.activeStore(for: session) === store)
        session.workspace = .training
        #expect(state.activeStore(for: session) == nil)
        session.workspace = .shots
        current = help
        state.refresh()
        #expect(state.activeStore(for: session) == nil)
        current = studio
        state.refresh()
        #expect(state.activeStore(for: session) === store)
        #expect(studio.delegate === owner)
    }

    @Test func committedEditsRouteThroughTheCommandActions() throws {
        let store = try makeStore()
        let scene = try #require(store.currentScene)
        let state = ShotsUndoCommandState(currentWindow: { nil })
        #expect(!state.canUndo(in: store))
        try store.perform(.renameScene(scene.id, name: "Changed"))
        #expect(state.canUndo(in: store))
        state.undo(in: store)
        #expect(store.currentScene?.name == scene.name)
        #expect(state.canRedo(in: store))
        state.redo(in: store)
        #expect(store.currentScene?.name == "Changed")
    }

    @Test func nativeTextHistoryTakesPrecedenceUntilTheEditorLosesFocus() throws {
        let store = try makeStore()
        let scene = try #require(store.currentScene)
        try store.perform(.renameScene(scene.id, name: "Document edit"))
        let window = makeWindow()
        defer { window.close() }
        let state = ShotsUndoCommandState(currentWindow: { window })
        let content = try #require(window.contentView)
        let editor = NSTextView(frame: content.bounds)
        editor.allowsUndo = true
        content.addSubview(editor)
        #expect(window.makeFirstResponder(editor))
        editor.insertText("Text edit", replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.breakUndoCoalescing()
        #expect(state.canUndo(in: store))
        state.undo(in: store)
        #expect(editor.string.isEmpty)
        #expect(store.currentScene?.name == "Document edit")
        #expect(!state.canUndo(in: store))
        #expect(state.canRedo(in: store))
        state.redo(in: store)
        #expect(editor.string == "Text edit")
        #expect(store.currentScene?.name == "Document edit")
        #expect(window.makeFirstResponder(content))
        state.refresh()
        #expect(state.canUndo(in: store))
        state.undo(in: store)
        #expect(store.currentScene?.name == scene.name)
        #expect(editor.string == "Text edit")
    }

    @Test func commandEnablementRefreshesWithNativeNotifications() throws {
        let store = try makeStore()
        let window = makeWindow()
        defer { window.close() }
        let state = ShotsUndoCommandState(currentWindow: { window })
        var refreshes = 0
        let observation = state.objectWillChange.sink { refreshes += 1 }
        defer { observation.cancel() }
        let editor = NSTextView(frame: .zero)
        editor.allowsUndo = true
        window.contentView?.addSubview(editor)
        #expect(window.makeFirstResponder(editor))
        editor.insertText("Typed", replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.breakUndoCoalescing()
        NotificationCenter.default.post(name: NSText.didChangeNotification, object: editor)
        #expect(refreshes > 0)
        #expect(state.canUndo(in: store))
        #expect(!state.canRedo(in: store))
        state.undo(in: store)
        #expect(!state.canUndo(in: store))
        #expect(state.canRedo(in: store))
    }

    private func makeStore() throws -> ShotsStore {
        try ShotsStore(catalog: ContentCatalog.bundled(), document: ShotsSamples.twoPersonWalk(), saveURL: nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
        return window
    }
}
