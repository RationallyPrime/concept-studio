import AppKit
@testable import ConceptStudio
import Foundation
import PrevisCore
import SwiftUI
import Testing

@MainActor
@Suite("Viewport D5 keyboard shortcuts, atomic nudge and accessibility")
struct ViewportKeyboardTests {
    @Test
    func singleCommandFalseToTrueCoalescingIsPreservedWhileGroupedEditsCommitAndRollbackAtomically() throws {
        let catalog = try ContentCatalog.bundled()
        let document = ShotsSamples.twoPersonWalk(small: true)
        let store = ShotsStore(catalog: catalog, document: document, saveURL: nil)
        let firstID = "ent_000000000001"
        let secondID = "ent_000000000002"
        let initialDocument = store.document
        let initialRevision = try #require(store.currentScene?.revision)

        // 1. perform(command, coalescing: false) followed immediately by same-target coalescing: true joins into 1 Undo
        var firstPlacement = try #require(
            store.currentScene?.entities.first(where: { $0.id == firstID })?.placement
        )
        firstPlacement.position.x += 0.20
        try store.perform(.setPlacement(firstID, firstPlacement), coalescing: false)
        firstPlacement.position.x += 0.30
        try store.perform(.setPlacement(firstID, firstPlacement), coalescing: true)
        let afterCoalesced = try #require(
            store.currentScene?.entities.first(where: { $0.id == firstID })?.placement
        )
        #expect(abs(afterCoalesced.position.x - (initialDocument.scenes[0].entities[0].placement.position.x + 0.50)) <
            1e-6)
        store.undo()
        #expect(store.document == initialDocument)
        #expect(!store.canUndo)

        // 2. Grouped perform([cmdA, cmdB]) does not coalesce into prior single-command edit and bumps revision once
        try store.perform(.setPlacement(firstID, firstPlacement), coalescing: false)
        let afterSingle = store.document
        let revAfterSingle = try #require(store.currentScene?.revision)
        #expect(revAfterSingle == initialRevision + 1)

        var p1 = firstPlacement
        p1.position.z -= 0.15
        var p2 = try #require(store.currentScene?.entities.first(where: { $0.id == secondID })?.placement)
        p2.position.z -= 0.15
        try store.perform([.setPlacement(firstID, p1), .setPlacement(secondID, p2)])
        #expect(store.currentScene?.revision == revAfterSingle + 1)

        // Subsequent coalescing: true on firstID must NOT join the grouped edit
        var p1Follow = p1
        p1Follow.position.z -= 0.10
        try store.perform(.setPlacement(firstID, p1Follow), coalescing: true)
        store.undo()
        #expect(
            store.currentScene?.entities.first(where: { $0.id == firstID })?.placement.position == p1.position
        )
        store.undo()
        #expect(store.document == afterSingle)
        store.redo()
        #expect(
            store.currentScene?.entities.first(where: { $0.id == secondID })?.placement.position == p2.position
        )
    }
}

extension ViewportKeyboardTests {
    @Test
    func arrowKeysNudgeSingleAndMultiEntitySelectionsAndRollbackAtomicallyOnInvalidSecondTarget() throws {
        let catalog = try ContentCatalog.bundled()
        let document = ShotsSamples.twoPersonWalk(small: true)
        let store = ShotsStore(catalog: catalog, document: document, saveURL: nil)
        let session = ViewportLiveSession()
        let firstID = "ent_000000000001"
        let secondID = "ent_000000000002"
        let initialFirst = try #require(store.currentScene?.entities.first(where: { $0.id == firstID })?.placement)
        let initialSecond = try #require(store.currentScene?.entities.first(where: { $0.id == secondID })?.placement)

        // Multi-entity selection: Left (-0.05 X), Shift+Right (+0.50 X), Up (-0.05 Z), Shift+Down (+0.50 Z)
        store.selection = .entities([firstID, secondID])
        #expect(
            ViewportKeyboard.handleKeyDown(
                charactersIgnoringModifiers: "\u{F702}",
                keyCode: 123,
                in: store,
                session: session
            )
        )
        #expect(
            ViewportKeyboard.handleKeyDown(
                charactersIgnoringModifiers: "\u{F703}",
                keyCode: 124,
                modifiers: [.shift],
                in: store,
                session: session
            )
        )
        #expect(
            ViewportKeyboard.handleKeyDown(
                charactersIgnoringModifiers: "\u{F700}",
                keyCode: 126,
                in: store,
                session: session
            )
        )
        #expect(
            ViewportKeyboard.handleKeyDown(
                charactersIgnoringModifiers: "\u{F701}",
                keyCode: 125,
                modifiers: [.shift],
                in: store,
                session: session
            )
        )

        let movedFirst = try #require(store.currentScene?.entities.first(where: { $0.id == firstID })?.placement)
        let movedSecond = try #require(store.currentScene?.entities.first(where: { $0.id == secondID })?.placement)
        #expect(abs(movedFirst.position.x - (initialFirst.position.x + 0.45)) < 1e-6)
        #expect(abs(movedFirst.position.z - (initialFirst.position.z + 0.45)) < 1e-6)
        #expect(abs(movedSecond.position.x - (initialSecond.position.x + 0.45)) < 1e-6)
        #expect(abs(movedSecond.position.z - (initialSecond.position.z + 0.45)) < 1e-6)

        // Single Undo step undoes both entities from the last Shift+Down nudge
        store.undo()
        let undoneFirst = try #require(store.currentScene?.entities.first(where: { $0.id == firstID })?.placement)
        let undoneSecond = try #require(store.currentScene?.entities.first(where: { $0.id == secondID })?.placement)
        #expect(abs(undoneFirst.position.z - (initialFirst.position.z - 0.05)) < 1e-6)
        #expect(abs(undoneSecond.position.z - (initialSecond.position.z - 0.05)) < 1e-6)
        #expect(store.canRedo)

        // Adversarial atomic rollback: valid first entity + invalid second entity fails without mutating document or
        // Redo
        let beforeFailureDoc = store.document
        var capturedError: String?
        store.onError = { capturedError = $0 }
        store.selection = .entities([firstID, "ent_missing_invalid"])
        let handled = ViewportKeyboard.handleKeyDown(
            charactersIgnoringModifiers: "\u{F703}",
            keyCode: 124,
            in: store,
            session: session
        )
        #expect(!handled)
        #expect(capturedError != nil)
        #expect(store.document == beforeFailureDoc)
        #expect(store.canRedo)
    }
}

extension ViewportKeyboardTests {
    @Test
    func arrowKeysAndDeleteSupportActorMarksCameraMarksCarMountAndEntities() throws {
        let catalog = try ContentCatalog.bundled()
        var document = ShotsSamples.twoPersonWalk(small: true)
        document.scenes[0].blocking[0].tracks[0].marks[0].hold = 0.75
        document.scenes[0].shots[0].camera.marks[0].focalLength = 50.0
        let store = ShotsStore(catalog: catalog, document: document, saveURL: nil)
        let session = ViewportLiveSession()
        let shotID = try #require(store.currentShotID)
        let actorID = "ent_000000000001"
        let actorMarkID = try #require(store.currentScene?.blocking.first?.tracks.first?.marks.first?.id)
        let camMarkID = try #require(store.currentShot?.camera.marks.first?.id)

        // 1. Nudge actor mark preserves hold/gait
        store.selection = .actorMark(actorID, actorMarkID)
        let initialActorMark = try #require(store.currentScene?.blocking.first?.tracks.first?.marks.first)
        #expect(ViewportKeyboard.handleKeyDown(
            charactersIgnoringModifiers: nil,
            keyCode: 124,
            in: store,
            session: session
        ))
        let nudgedActorMark = try #require(store.currentScene?.blocking.first?.tracks.first?.marks.first)
        #expect(abs(nudgedActorMark.position.x - (initialActorMark.position.x + 0.05)) < 1e-6)
        #expect(nudgedActorMark.hold == 0.75)

        // 2. Nudge car-mounted camera mark and .camera selection convert world delta to mount-local
        store.run(.setCameraRig(shotID, sensor: .super35, rig: .carMount, intensity: 0))
        store.run(.setMount(shotID, actorID))
        store.selection = .cameraMark(camMarkID)
        let beforeMountPivot = try #require(ViewportHandles.resolveTarget(in: store)).worldPivot
        #expect(
            ViewportKeyboard.handleKeyDown(
                charactersIgnoringModifiers: nil,
                keyCode: 126,
                modifiers: [.shift],
                in: store,
                session: session
            )
        )
        let afterMountPivot = try #require(ViewportHandles.resolveTarget(in: store)).worldPivot
        #expect(abs(afterMountPivot.z - (beforeMountPivot.z - 0.50)) < 1e-5)
        #expect(store.currentShot?.camera.marks.first?.focalLength == 50.0)

        store.selection = .camera
        #expect(ViewportKeyboard.handleKeyDown(
            charactersIgnoringModifiers: nil,
            keyCode: 123,
            in: store,
            session: session
        ))
        let afterCamSelectionPivot = try #require(ViewportHandles.resolveTarget(in: store)).worldPivot
        #expect(abs(afterCamSelectionPivot.x - (afterMountPivot.x - 0.05)) < 1e-5)

        // 3. Delete on .camera is a safe no-op; Delete on actorMark, cameraMark, and entities removes them
        #expect(!ViewportKeyboard.handleKeyDown(
            charactersIgnoringModifiers: "\u{7F}",
            keyCode: 51,
            in: store,
            session: session
        ))
        store.selection = .actorMark(actorID, actorMarkID)
        #expect(ViewportKeyboard.handleKeyDown(
            charactersIgnoringModifiers: "\u{7F}",
            keyCode: 51,
            in: store,
            session: session
        ))
        #expect(
            store.currentScene?.blocking.first?.tracks.first?.marks.contains(where: { $0.id == actorMarkID }) == false
        )

        store.selection = .cameraMark(camMarkID)
        #expect(ViewportKeyboard.handleKeyDown(
            charactersIgnoringModifiers: "\u{F728}",
            keyCode: 117,
            in: store,
            session: session
        ))
        #expect(store.currentShot?.camera.marks.contains(where: { $0.id == camMarkID }) == false)

        let chairID = "ent_000000000003"
        store.selection = .entities([chairID])
        #expect(ViewportKeyboard.handleKeyDown(
            charactersIgnoringModifiers: "\u{7F}",
            keyCode: 51,
            in: store,
            session: session
        ))
        #expect(store.currentScene?.entities.contains(where: { $0.id == chairID }) == false)
    }
}

extension ViewportKeyboardTests {
    @Test
    func frameKeyAndNumericCameraMarkJumpsUpdateEditorCameraAndPlayheadWithoutMutatingDocument() throws {
        let catalog = try ContentCatalog.bundled()
        var document = ShotsSamples.twoPersonWalk(small: true)
        document.scenes[0].shots[0].frameCount = 48
        let baseCamMark = document.scenes[0].shots[0].camera.marks[0]
        var lateMark = baseCamMark
        lateMark.id = "cam_late"
        lateMark.time = 1.5
        var earlyMark = baseCamMark
        earlyMark.id = "cam_early"
        earlyMark.time = 0.25
        var midMark = baseCamMark
        midMark.id = "cam_mid"
        midMark.time = 0.75
        document.scenes[0].shots[0].camera.marks = [lateMark, earlyMark, midMark]
        let store = ShotsStore(catalog: catalog, document: document, saveURL: nil)
        let session = ViewportLiveSession()
        let beforeDocument = store.document

        // 1. F with .none selection or nil session returns false
        store.selection = .none
        #expect(!pressKey("f", keyCode: 3, in: store, session: session))
        store.selection = .entities(["ent_000000000001"])
        #expect(!pressKey("f", keyCode: 3, in: store, session: nil))

        // 2. F with entity selection centers EditorCamera on EntityFrame.bounds without mutating store.document
        let entityFrame = try #require(store.frame?.entities.first(where: { $0.id == "ent_000000000001" }))
        let expectedCenter = Vec3(
            (entityFrame.bounds.min.x + entityFrame.bounds.max.x) * 0.5,
            (entityFrame.bounds.min.y + entityFrame.bounds.max.y) * 0.5,
            (entityFrame.bounds.min.z + entityFrame.bounds.max.z) * 0.5
        )
        #expect(pressKey("f", keyCode: 3, in: store, session: session))
        #expect(session.editorCamera.target == expectedCenter)
        #expect(store.document == beforeDocument)

        // 3. F with multi-entity selection increases camera distance to fit union bounds
        let singleDistance = session.editorCamera.distance
        store.selection = .entities(["ent_000000000001", "ent_000000000002", "ent_000000000003"])
        #expect(pressKey("f", keyCode: 3, in: store, session: session))
        #expect(session.editorCamera.distance > singleDistance)
        #expect(store.document == beforeDocument)

        // 4. 1-9 jump playhead to camera marks sorted by ascending time; out-of-range digits are safe no-ops
        #expect(pressKey("1", keyCode: 18, in: store, session: session))
        #expect(store.playhead == FrameGrid.frame(atTime: 0.25))
        #expect(pressKey("2", keyCode: 19, in: store, session: session))
        #expect(store.playhead == FrameGrid.frame(atTime: 0.75))
        #expect(pressKey("3", keyCode: 20, in: store, session: session))
        #expect(store.playhead == FrameGrid.frame(atTime: 1.5))
        #expect(!pressKey("4", keyCode: 21, in: store, session: session))
        #expect(store.playhead == FrameGrid.frame(atTime: 1.5))
    }
}

extension ViewportKeyboardTests {
    @Test
    func hostedWorkspaceLookThroughToggleRetainsSharedEditorSessionAndRespectsReadOnlyAndFocusGuards() throws {
        let catalog = try ContentCatalog.bundled()
        var document = ShotsSamples.twoPersonWalk(small: true)
        document.scenes[0].shots[0].frameCount = 48
        let studioSession = StudioSession()
        let store = ShotsStore(catalog: catalog, document: document, saveURL: nil)
        studioSession.shots = store

        let windowSize = CGSize(width: 960, height: 640)
        let host = NSHostingView(
            rootView: ShotsWorkspaceView(session: studioSession)
                .frame(width: windowSize.width, height: windowSize.height)
        )
        host.frame = CGRect(origin: .zero, size: windowSize)
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: windowSize),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer {
            window.contentView = nil
            window.close()
        }
        host.layoutSubtreeIfNeeded()

        let scrollOverlay = try #require(findView(
            ofType: ViewportScrollWheelOverlay.ScrollCapturingView.self,
            in: host
        ))
        let sharedSession = try #require(scrollOverlay.session)
        var capturedAnnouncements: [String] = []
        sharedSession.announcementPoster = { capturedAnnouncements.append($0) }

        // Focus viewport, select entity, switch handle mode to Rotate ('R'), and toggle look-through ('C')
        _ = window.makeFirstResponder(scrollOverlay)
        store.selection = .entities(["ent_000000000003"])
        sendKey(characters: "r", keyCode: 15, in: window, to: scrollOverlay)
        #expect(sharedSession.handleMode == .rotate)

        sendKey(characters: "c", keyCode: 8, in: window, to: scrollOverlay)
        host.layoutSubtreeIfNeeded()
        #expect(findView(ofType: ViewportScrollWheelOverlay.ScrollCapturingView.self, in: host) == nil)
        let lookThroughOverlay = try #require(findView(
            ofType: ViewportKeyCaptureOverlay.KeyCapturingView.self,
            in: host
        ))
        #expect(window.firstResponder === lookThroughOverlay)

        // Pressing 'F' while in look-through ('ShotCameraView') updates sharedSession.editorCamera.target & distance
        let defaultTarget = EditorCamera.defaultView.target
        sendKey(characters: "f", keyCode: 3, in: window, to: lookThroughOverlay)
        #expect(sharedSession.editorCamera.target != defaultTarget)
        let framedCamera = sharedSession.editorCamera

        // Pressing 'C' in look-through returns to ShotsViewport with framed EditorCamera and .rotate mode preserved
        sendKey(characters: "c", keyCode: 8, in: window, to: lookThroughOverlay)
        host.layoutSubtreeIfNeeded()
        let restoredScrollOverlay = try #require(
            findView(ofType: ViewportScrollWheelOverlay.ScrollCapturingView.self, in: host)
        )
        #expect(window.firstResponder === restoredScrollOverlay)
        #expect(restoredScrollOverlay.session === sharedSession)
        #expect(sharedSession.editorCamera == framedCamera)
        #expect(sharedSession.handleMode == .rotate)
        #expect(capturedAnnouncements.contains("Framed selection"))
        #expect(capturedAnnouncements.contains("Toggled camera view"))
    }
}

extension ViewportKeyboardTests {
    @Test
    func readOnlyModifierPreviewCancellationAndUnshownWindowAnnouncementGuards() throws {
        let catalog = try ContentCatalog.bundled()
        let document = ShotsSamples.twoPersonWalk(small: true)
        let store = ShotsStore(catalog: catalog, document: document, saveURL: nil)
        let session = ViewportLiveSession()
        let chairID = "ent_000000000003"
        store.selection = .entities([chairID])

        // 1. Active handle drag preview is cancelled before keyboard nudge or camera-mark jump
        let camera = session.editorCamera
        let size = session.viewportSize
        let pivot = try #require(store.currentScene?.entities.first(where: { $0.id == chairID })?.placement.position)
        let startPx = try #require(camera.project(pivot, size: size))
        #expect(session.beginHandleDrag(at: startPx, in: store))
        session.updateHandleDrag(at: Point2(x: startPx.x + 18, y: startPx.y - 12), shiftPressed: false, in: store)
        #expect(store.preview != nil)

        #expect(pressKey("1", keyCode: 18, in: store, session: session))
        #expect(session.activeHandleDrag == nil)
        #expect(store.preview == nil)

        // 2. Command/Control/Option modifiers are ignored so system shortcuts are never hijacked
        #expect(!pressKey("f", keyCode: 3, modifiers: [.command], in: store, session: session))
        #expect(!pressKey("\u{7F}", keyCode: 51, modifiers: [.option], in: store, session: session))

        // 3. Read-only store allows F, C, V, Esc, 1-9 while blocking arrows, Delete, G, R, M
        let readOnlyStore = ShotsStore(catalog: catalog, document: document, saveURL: nil, readOnly: true)
        readOnlyStore.selection = .entities([chairID])
        var lookThroughToggles = 0
        #expect(pressKey("f", keyCode: 3, in: readOnlyStore, session: session))
        #expect(
            ViewportKeyboard.handleKeyDown(
                charactersIgnoringModifiers: "c",
                keyCode: 8,
                in: readOnlyStore,
                session: session,
                onToggleLookThrough: { lookThroughToggles += 1 }
            )
        )
        #expect(lookThroughToggles == 1)
        #expect(pressKey("1", keyCode: 18, in: readOnlyStore, session: session))
        #expect(!pressKey(nil, keyCode: 123, in: readOnlyStore, session: session))
        #expect(!pressKey("\u{7F}", keyCode: 51, in: readOnlyStore, session: session))
        #expect(!pressKey("g", keyCode: 5, in: readOnlyStore, session: session))
        #expect(!pressKey("r", keyCode: 15, in: readOnlyStore, session: session))
        #expect(!pressKey("m", keyCode: 46, in: readOnlyStore, session: session))

        // 4. Default announcement path in unshown test window updates lastAnnouncement without live OS notification
        session.announcementPoster = nil
        session.postAnnouncement("Headless announcement check")
        #expect(session.lastAnnouncement == "Headless announcement check")
    }

    private func pressKey(
        _ chars: String?,
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags = [],
        in store: ShotsStore,
        session: ViewportLiveSession?
    ) -> Bool {
        ViewportKeyboard.handleKeyDown(
            charactersIgnoringModifiers: chars,
            keyCode: keyCode,
            modifiers: modifiers,
            in: store,
            session: session
        )
    }

    private func findView<T: NSView>(ofType type: T.Type, in root: NSView) -> T? {
        if let match = root as? T { return match }
        for child in root.subviews {
            if let match = findView(ofType: type, in: child) { return match }
        }
        return nil
    }

    private func sendKey(characters: String, keyCode: UInt16, in window: NSWindow, to view: NSView) {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ) else { return }
        view.keyDown(with: event)
    }
}

extension ViewportKeyboardTests {
    @Test
    func hostedFocusSuppressionBlocksNewKeysWhenTimelineOrTextEditorOwnsResponderAndFramesMarkTargets() throws {
        let catalog = try ContentCatalog.bundled()
        var document = ShotsSamples.twoPersonWalk(small: true)
        document.scenes[0].shots[0].frameCount = 48
        let studioSession = StudioSession()
        let store = ShotsStore(catalog: catalog, document: document, saveURL: nil)
        studioSession.shots = store

        let windowSize = CGSize(width: 960, height: 640)
        let host = NSHostingView(
            rootView: ShotsWorkspaceView(session: studioSession)
                .frame(width: windowSize.width, height: windowSize.height)
        )
        host.frame = CGRect(origin: .zero, size: windowSize)
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: windowSize),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer {
            window.contentView = nil
            window.close()
        }
        host.layoutSubtreeIfNeeded()

        let scrollOverlay = try #require(findView(
            ofType: ViewportScrollWheelOverlay.ScrollCapturingView.self,
            in: host
        ))
        let sharedSession = try #require(scrollOverlay.session)
        let chairID = "ent_000000000003"
        store.selection = .entities([chairID])
        let beforeDocument = store.document
        let beforeCamera = sharedSession.editorCamera

        // 1. When another non-viewport control or NSTextView owns firstResponder, viewport keys are suppressed
        let externalResponder = FocusableTestView(frame: CGRect(x: 0, y: 0, width: 20, height: 20))
        let textEditor = NSTextView(frame: CGRect(x: 0, y: 0, width: 80, height: 20))
        host.addSubview(externalResponder)
        host.addSubview(textEditor)

        for responder in [externalResponder as NSView, textEditor as NSView] {
            _ = window.makeFirstResponder(responder)
            sendKey(characters: "\u{F703}", keyCode: 124, in: window, to: scrollOverlay)
            sendKey(characters: "\u{7F}", keyCode: 51, in: window, to: scrollOverlay)
            sendKey(characters: "f", keyCode: 3, in: window, to: scrollOverlay)
            sendKey(characters: "c", keyCode: 8, in: window, to: scrollOverlay)
            sendKey(characters: "2", keyCode: 19, in: window, to: scrollOverlay)
        }
        #expect(store.document == beforeDocument)
        #expect(sharedSession.editorCamera == beforeCamera)
        #expect(store.playhead == 0)

        // 2. Framing actorMark, cameraMark, and .camera updates EditorCamera.target to mark/camera world position
        _ = window.makeFirstResponder(scrollOverlay)
        let actorMark = try #require(store.currentScene?.blocking.first?.tracks.first?.marks.first)
        store.selection = .actorMark("ent_000000000001", actorMark.id)
        #expect(ViewportKeyboard.handleKeyDown(
            charactersIgnoringModifiers: "f",
            keyCode: 3,
            in: store,
            session: sharedSession
        ))
        #expect(distance(sharedSession.editorCamera.target, actorMark.position) < 1e-9)

        let camMark = try #require(store.currentShot?.camera.marks.last)
        store.selection = .cameraMark(camMark.id)
        #expect(ViewportKeyboard.handleKeyDown(
            charactersIgnoringModifiers: "f",
            keyCode: 3,
            in: store,
            session: sharedSession
        ))
        #expect(distance(sharedSession.editorCamera.target, camMark.position) < 1e-9)

        store.selection = .camera
        let expectedCamPos = try #require(store.frame?.camera.position)
        #expect(ViewportKeyboard.handleKeyDown(
            charactersIgnoringModifiers: "f",
            keyCode: 3,
            in: store,
            session: sharedSession
        ))
        #expect(distance(sharedSession.editorCamera.target, expectedCamPos) < 1e-9)
    }

    private func distance(_ a: Vec3, _ b: Vec3) -> Double {
        let dx = a.x - b.x
        let dy = a.y - b.y
        let dz = a.z - b.z
        return (dx * dx + dy * dy + dz * dz).squareRoot()
    }
}

private final class FocusableTestView: NSView {
    override var acceptsFirstResponder: Bool {
        true
    }
}
