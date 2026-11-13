import AppKit
import SwiftUI

/// The studio session owns Shots history. Other workspaces and windows keep the standard Edit commands.
struct ShotsUndoCommands: Commands {
    let session: StudioSession
    @StateObject private var native = ShotsUndoCommandState()

    var body: some Commands {
        if let store = native.activeStore(for: session) {
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { native.undo(in: store) }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!native.canUndo(in: store))
                Button("Redo") { native.redo(in: store) }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!native.canRedo(in: store))
            }
        }
    }
}

/// Keeps command enablement current as focus and the native field editor's history change.
@MainActor
final class ShotsUndoCommandState: NSObject, ObservableObject {
    private struct NativeHistory: Equatable {
        var window: ObjectIdentifier?
        var owner: ObjectIdentifier?
        var workspace: StudioWorkspace?
        var store: ObjectIdentifier?
        var documentCanUndo: Bool
        var documentCanRedo: Bool
        var editor: ObjectIdentifier?
        var canUndo: Bool
        var canRedo: Bool
    }

    @Published private var history = NativeHistory(
        window: nil, owner: nil, workspace: nil, store: nil,
        documentCanUndo: false, documentCanRedo: false,
        editor: nil, canUndo: false, canRedo: false
    )
    private let currentWindow: () -> NSWindow?

    init(currentWindow: @escaping () -> NSWindow? = { NSApp?.keyWindow }) {
        self.currentWindow = currentWindow
        super.init()
        for name in [
            NSWindow.didUpdateNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
            NSText.didBeginEditingNotification,
            NSText.didEndEditingNotification,
            NSText.didChangeNotification,
            NSControl.textDidBeginEditingNotification,
            NSControl.textDidEndEditingNotification,
            NSControl.textDidChangeNotification,
            Notification.Name.NSUndoManagerDidCloseUndoGroup,
            Notification.Name.NSUndoManagerDidUndoChange,
            Notification.Name.NSUndoManagerDidRedoChange,
        ] {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(nativeHistoryChanged(_:)),
                name: name,
                object: nil
            )
        }
        refresh()
    }

    private var editor: NSTextView? {
        currentWindow()?.firstResponder as? NSTextView
    }

    func activeStore(for session: StudioSession) -> ShotsStore? {
        guard session.workspace == .shots,
              let owner = currentWindow()?.delegate as? WindowCloseGuard.Coordinator,
              owner.session === session else { return nil }
        return session.shots
    }

    func canUndo(in store: ShotsStore) -> Bool {
        if let editor { return editor.undoManager?.canUndo == true }
        return store.canUndo
    }

    func canRedo(in store: ShotsStore) -> Bool {
        if let editor { return editor.undoManager?.canRedo == true }
        return store.canRedo
    }

    func undo(in store: ShotsStore) {
        if let editor { editor.undoManager?.undo() } else { store.undo() }
        refresh()
    }

    func redo(in store: ShotsStore) {
        if let editor { editor.undoManager?.redo() } else { store.redo() }
        refresh()
    }

    @objc private func nativeHistoryChanged(_ notification: Notification) {
        refresh()
    }

    func refresh() {
        let window = currentWindow()
        let owner = (window?.delegate as? WindowCloseGuard.Coordinator)?.session
        let editor = editor
        let updated = NativeHistory(
            window: window.map(ObjectIdentifier.init),
            owner: owner.map(ObjectIdentifier.init),
            workspace: owner?.workspace,
            store: owner?.shots.map(ObjectIdentifier.init),
            documentCanUndo: owner?.shots?.canUndo == true,
            documentCanRedo: owner?.shots?.canRedo == true,
            editor: editor.map(ObjectIdentifier.init),
            canUndo: editor?.undoManager?.canUndo == true,
            canRedo: editor?.undoManager?.canRedo == true
        )
        if history != updated { history = updated }
    }
}
