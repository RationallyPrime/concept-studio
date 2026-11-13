import AppKit
import SwiftUI

/// Adds document history to the window's native Edit-menu responder chain.
struct ShotsUndoBridge: NSViewRepresentable {
    let store: ShotsStore

    func makeNSView(context: Context) -> ShotsUndoView {
        ShotsUndoView(store: store)
    }

    func updateNSView(_ view: ShotsUndoView, context: Context) {
        view.history.store = store
        view.install()
    }

    static func dismantleNSView(_ view: ShotsUndoView, coordinator: ()) {
        view.uninstall()
    }
}

final class ShotsUndoView: NSView {
    let history: ShotsHistoryResponder
    private weak var anchor: NSView?

    init(store: ShotsStore) {
        history = ShotsHistoryResponder(store: store)
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        install()
    }

    func install() {
        guard let content = window?.contentView else { uninstall(); return }
        guard anchor !== content || content.nextResponder !== history else { return }
        uninstall()
        // SwiftUI may mount a replacement before dismantling the old bridge.
        // Skip that retiring bridge so it cannot remain in the native chain.
        let previous = content.nextResponder
        history.nextResponder = (previous as? ShotsHistoryResponder)?.nextResponder ?? previous
        history.hostWindow = window
        anchor = content
        content.nextResponder = history
    }

    func uninstall() {
        if anchor?.nextResponder === history { anchor?.nextResponder = history.nextResponder }
        anchor = nil
        history.hostWindow = nil
        history.nextResponder = nil
    }
}

final class ShotsHistoryResponder: NSResponder, NSMenuItemValidation {
    weak var store: ShotsStore? {
        didSet { documentUndoManager.store = store }
    }

    weak var hostWindow: NSWindow?
    private let documentUndoManager: ShotsDocumentUndoManager

    init(store: ShotsStore) {
        self.store = store
        documentUndoManager = ShotsDocumentUndoManager(store: store)
        super.init()
    }

    /// SwiftUI's standard Edit commands consult this manager before sending native undo actions.
    /// An active text editor continues through the window's ordinary text undo manager.
    override var undoManager: UndoManager? {
        textEditor == nil ? documentUndoManager : nextResponder?.undoManager
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    private var textEditor: NSTextView? {
        hostWindow?.firstResponder as? NSTextView
    }

    @objc func undo(_ sender: Any?) {
        if let textEditor { textEditor.undoManager?.undo() } else { store?.undo() }
    }

    @objc func redo(_ sender: Any?) {
        if let textEditor { textEditor.undoManager?.redo() } else { store?.redo() }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)):
            if let textEditor { return textEditor.undoManager?.canUndo == true }
            return store?.canUndo == true
        case #selector(redo(_:)):
            if let textEditor { return textEditor.undoManager?.canRedo == true }
            return store?.canRedo == true
        default: return false
        }
    }
}

/// Adapts the store's snapshot history to the native manager queried by the standard Edit menu.
/// Access comes from AppKit's main-thread responder chain.
final class ShotsDocumentUndoManager: UndoManager {
    weak var store: ShotsStore?

    init(store: ShotsStore) {
        self.store = store
        super.init()
    }

    override var canUndo: Bool {
        MainActor.assumeIsolated { store?.canUndo == true }
    }

    override var canRedo: Bool {
        MainActor.assumeIsolated { store?.canRedo == true }
    }

    override func undo() {
        MainActor.assumeIsolated { store?.undo() }
    }

    override func redo() {
        MainActor.assumeIsolated { store?.redo() }
    }
}
