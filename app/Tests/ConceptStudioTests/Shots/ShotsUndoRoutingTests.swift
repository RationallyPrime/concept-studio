import AppKit
@testable import ConceptStudio
import PrevisCore
import SwiftUI
import Testing

@Suite("Shots native undo routing")
@MainActor
struct ShotsUndoRoutingTests {
    @Test func nativeHistoryActionsEditShotsAndDetachRestoresTheWindowChain() throws {
        let store = try makeStore()
        let scene = try #require(store.currentScene)
        try store.perform(.renameScene(scene.id, name: "Changed"))
        let window = makeWindow()
        defer { window.close() }
        let content = try #require(window.contentView)
        let previous = content.nextResponder
        let bridge = ShotsUndoView(store: store)
        content.addSubview(bridge)
        let history = try #require(content.nextResponder as? ShotsHistoryResponder)
        let undo = NSMenuItem(title: "Undo", action: #selector(history.undo(_:)), keyEquivalent: "z")
        let redo = NSMenuItem(title: "Redo", action: #selector(history.redo(_:)), keyEquivalent: "Z")
        #expect(history.validateMenuItem(undo))
        #expect(content.tryToPerform(#selector(history.undo(_:)), with: nil))
        #expect(store.currentScene?.name == scene.name)
        #expect(history.validateMenuItem(redo))
        #expect(content.tryToPerform(#selector(history.redo(_:)), with: nil))
        #expect(store.currentScene?.name == "Changed")
        bridge.removeFromSuperview()
        #expect(content.nextResponder === previous)
    }

    @Test func textEditingKeepsItsOwnUndoEvenWhenTheDocumentHasHistory() throws {
        let store = try makeStore()
        let scene = try #require(store.currentScene)
        try store.perform(.renameScene(scene.id, name: "Document edit"))
        let window = makeWindow()
        defer { window.close() }
        let content = try #require(window.contentView)
        let bridge = ShotsUndoView(store: store)
        content.addSubview(bridge)
        let editor = NSTextView(frame: content.bounds)
        editor.allowsUndo = true
        content.addSubview(editor)
        #expect(window.makeFirstResponder(editor))
        editor.insertText("Text edit", replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.breakUndoCoalescing()
        #expect(editor.undoManager?.canUndo == true)
        bridge.history.undo(nil)
        #expect(editor.string.isEmpty)
        #expect(store.currentScene?.name == "Document edit")
        let undo = NSMenuItem(title: "Undo", action: #selector(bridge.history.undo(_:)), keyEquivalent: "z")
        #expect(!bridge.history.validateMenuItem(undo))
        bridge.history.redo(nil)
        #expect(editor.string == "Text edit")
        #expect(store.currentScene?.name == "Document edit")
    }

    @Test func replacingBridgeDoesNotResurrectTheRetiredResponder() throws {
        let store = try makeStore()
        let window = makeWindow()
        defer { window.close() }
        let content = try #require(window.contentView)
        let previous = content.nextResponder
        let first = ShotsUndoView(store: store)
        let second = ShotsUndoView(store: store)
        content.addSubview(first)
        content.addSubview(second)
        #expect(content.nextResponder === second.history)
        first.removeFromSuperview()
        #expect(content.nextResponder === second.history)
        second.removeFromSuperview()
        #expect(content.nextResponder === previous)
    }

    @Test func swiftUIBackgroundMountsTheNativeResponderWithoutReplacingEditCommands() async throws {
        let store = try makeStore()
        let scene = try #require(store.currentScene)
        try store.perform(.renameScene(scene.id, name: "Mounted edit"))
        let window = makeWindow()
        defer { window.close() }
        let host = NSHostingView(rootView: Text("Shots").background(ShotsUndoBridge(store: store)))
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        await Task.yield()
        let history = try #require(host.nextResponder as? ShotsHistoryResponder)
        #expect(history.store === store)
        #expect(host.tryToPerform(#selector(history.undo(_:)), with: nil))
        #expect(store.currentScene?.name == scene.name)
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
