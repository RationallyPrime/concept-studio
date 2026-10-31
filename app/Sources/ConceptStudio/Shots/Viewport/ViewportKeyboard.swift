import AppKit
import Foundation
import PrevisCore
import SwiftUI

/// Guarded AppKit accessibility announcement helper for the 3D viewport (`LANE-D-VIEWPORT.md` D5).
/// Only posts live `NSAccessibility` notifications when no custom test poster is injected and the host
/// `NSWindow` is visible in an active application, remaining a no-op in headless/unshown test windows.
enum ViewportAccessibility {
    @MainActor
    static func postAnnouncementIfWindowVisible(_ message: String, in view: NSView?) {
        guard let window = view?.window,
              window.isVisible,
              NSApp?.isActive == true
        else { return }
        NSAccessibility.post(
            element: window,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }
}

/// Viewport-focused keyboard command dispatcher and selection framing/nudge helpers
/// (`CONTRACTS.md` section 7 lines 767-777, `LANE-D-VIEWPORT.md` D5 lines 138-146).
///
/// Reference: Blockout `src/renderer/viewport/SceneManager.ts:960-994`,
/// `src/renderer/viewport/Viewport.tsx:303-327`, and `src/renderer/App.tsx:150-206`.
/// Plan-required Swift adaptations:
/// - `V` select tool, `←`/`↑`/`→`/`↓` `5 cm` (`⇧` `50 cm`) world-XZ selection nudge, `F` selection-bounds framing in
///   `EditorCamera`, and atomic multi-entity nudge via `ShotsStore.run([ShotsCommand])`.
enum ViewportKeyboard {
    static let nudgeStepMeters: Double = 0.05
    static let shiftNudgeStepMeters: Double = 0.50
    static let framePaddingFactor: Double = 1.35
    static let minimumFrameRadiusMeters: Double = 0.75

    static let escapeKeyCode: UInt16 = 53
    static let deleteKeyCode: UInt16 = 51
    static let forwardDeleteKeyCode: UInt16 = 117
    static let leftArrowKeyCode: UInt16 = 123
    static let rightArrowKeyCode: UInt16 = 124
    static let downArrowKeyCode: UInt16 = 125
    static let upArrowKeyCode: UInt16 = 126

    @MainActor
    @discardableResult
    static func handleKeyDown(
        charactersIgnoringModifiers: String?,
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags = [],
        in store: ShotsStore,
        session: ViewportLiveSession? = nil,
        onToggleLookThrough: (() -> Void)? = nil
    ) -> Bool {
        let disallowedModifiers: NSEvent.ModifierFlags = [.command, .control, .option]
        guard modifiers.isDisjoint(with: disallowedModifiers),
              !(NSApp != nil && ShotsTimelineView.editingText),
              !(session?.hostView?.window?.firstResponder is NSText)
        else { return false }

        if keyCode == escapeKeyCode || charactersIgnoringModifiers == "\u{1B}" {
            cancelActivePreview(in: store, session: session)
            store.tool = .select
            session?.postAnnouncement("Select tool active")
            return true
        }
        if isDeleteKey(keyCode: keyCode, charactersIgnoringModifiers: charactersIgnoringModifiers) {
            return deleteSelection(in: store, session: session)
        }
        if let delta = nudgeDelta(
            keyCode: keyCode,
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            shiftPressed: modifiers.contains(.shift)
        ) {
            return nudgeSelection(by: delta, in: store, session: session)
        }
        return handleCharacterKey(
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            in: store,
            session: session,
            onToggleLookThrough: onToggleLookThrough
        )
    }
}

extension ViewportKeyboard {
    @MainActor
    private static func handleCharacterKey(
        charactersIgnoringModifiers: String?,
        in store: ShotsStore,
        session: ViewportLiveSession?,
        onToggleLookThrough: (() -> Void)?
    ) -> Bool {
        guard let chars = charactersIgnoringModifiers?.lowercased(),
              chars.count == 1
        else { return false }

        if let handledToolKey = handleToolCharacterKey(chars, in: store, session: session) {
            return handledToolKey
        }
        switch chars {
        case "f":
            return frameSelection(in: store, session: session)
        case "c":
            guard store.currentShot != nil, let onToggleLookThrough else { return false }
            cancelActivePreview(in: store, session: session)
            onToggleLookThrough()
            session?.postAnnouncement("Toggled camera view")
            return true
        case "1" ... "9":
            guard let digit = Int(chars), (1 ... 9).contains(digit) else { return false }
            return jumpToCameraMark(atSortedIndex: digit - 1, in: store, session: session)
        default:
            return false
        }
    }

    @MainActor
    private static func handleToolCharacterKey(
        _ chars: String,
        in store: ShotsStore,
        session: ViewportLiveSession?
    ) -> Bool? {
        switch chars {
        case "v":
            cancelActivePreview(in: store, session: session)
            store.tool = .select
            session?.postAnnouncement("Select tool active")
            return true
        case "m":
            guard !store.isReadOnly, store.currentShot != nil else { return false }
            cancelActivePreview(in: store, session: session)
            store.tool = store.tool == .dropMarks ? .select : .dropMarks
            session?.postAnnouncement(
                store.tool == .dropMarks ? "Drop marks tool active" : "Select tool active"
            )
            return true
        case "g":
            guard !store.isReadOnly, store.currentShot != nil else { return false }
            if let session { session.setHandleMode(.move, in: store) } else { store.preview = nil }
            store.tool = .select
            return true
        case "r":
            guard !store.isReadOnly, store.currentShot != nil else { return false }
            if let session { session.setHandleMode(.rotate, in: store) } else { store.preview = nil }
            store.tool = .select
            return true
        default:
            return nil
        }
    }

    static func isDeleteKey(keyCode: UInt16, charactersIgnoringModifiers: String?) -> Bool {
        keyCode == deleteKeyCode
            || keyCode == forwardDeleteKeyCode
            || charactersIgnoringModifiers == "\u{7F}"
            || charactersIgnoringModifiers == "\u{F728}"
    }

    static func nudgeDelta(
        keyCode: UInt16,
        charactersIgnoringModifiers: String?,
        shiftPressed: Bool
    ) -> Vec3? {
        let step = shiftPressed ? shiftNudgeStepMeters : nudgeStepMeters
        if keyCode == leftArrowKeyCode || charactersIgnoringModifiers == "\u{F702}" {
            return Vec3(-step, 0, 0)
        }
        if keyCode == rightArrowKeyCode || charactersIgnoringModifiers == "\u{F703}" {
            return Vec3(step, 0, 0)
        }
        if keyCode == upArrowKeyCode || charactersIgnoringModifiers == "\u{F700}" {
            return Vec3(0, 0, -step)
        }
        if keyCode == downArrowKeyCode || charactersIgnoringModifiers == "\u{F701}" {
            return Vec3(0, 0, step)
        }
        return nil
    }
}

@MainActor
extension ViewportKeyboard {
    static func cancelActivePreview(in store: ShotsStore, session: ViewportLiveSession?) {
        if let session {
            session.cancelActiveHandleDrag(in: store)
        } else {
            store.preview = nil
        }
    }

    static func deleteSelection(in store: ShotsStore, session: ViewportLiveSession?) -> Bool {
        guard !store.isReadOnly else { return false }
        cancelActivePreview(in: store, session: session)
        let before = store.document
        switch store.selection {
        case .none, .camera:
            return false
        case let .entities(ids):
            guard !ids.isEmpty else { return false }
            store.run(.deleteEntities(ids))
            guard store.document != before else { return false }
            session?.postAnnouncement("Deleted selection")
            return true
        case let .actorMark(_, markID), let .cameraMark(markID):
            guard let shotID = store.currentShotID else { return false }
            store.run(.deleteMarks(shotID, [markID]))
            guard store.document != before else { return false }
            session?.postAnnouncement("Deleted mark \(markID)")
            return true
        }
    }

    static func jumpToCameraMark(
        atSortedIndex index: Int,
        in store: ShotsStore,
        session: ViewportLiveSession?
    ) -> Bool {
        guard let shot = store.currentShot else { return false }
        let sortedMarks = shot.camera.marks.sorted { $0.time < $1.time }
        guard sortedMarks.indices.contains(index) else { return false }
        cancelActivePreview(in: store, session: session)
        store.isPlaying = false
        store.playhead = FrameGrid.frame(atTime: sortedMarks[index].time)
        session?.postAnnouncement("Jumped to camera mark \(index + 1)")
        return true
    }

    static func nudgeSelection(
        by delta: Vec3,
        in store: ShotsStore,
        session: ViewportLiveSession?
    ) -> Bool {
        guard !store.isReadOnly else { return false }
        cancelActivePreview(in: store, session: session)
        guard let scene = store.currentScene else { return false }
        let before = store.document

        switch store.selection {
        case .none:
            return false
        case let .entities(ids):
            guard !ids.isEmpty else { return false }
            let commands = entityNudgeCommands(
                for: ids,
                by: delta,
                in: scene,
                currentShot: store.currentShot
            )
            store.run(commands)
            guard store.document != before else { return false }
            session?.postAnnouncement("Nudged selection")
            return true
        case let .actorMark(entityID, markID):
            return nudgeActorMark(entityID: entityID, markID: markID, by: delta, in: store, session: session)
        case let .cameraMark(markID):
            return nudgeCameraMark(markID: markID, by: delta, in: store, session: session)
        case .camera:
            guard let shot = store.currentShot,
                  let mark = ViewportHandles.activeCameraMark(
                      in: shot,
                      at: FrameGrid.time(ofFrame: store.playhead)
                  )
            else { return false }
            return nudgeCameraMark(markID: mark.id, by: delta, in: store, session: session)
        }
    }
}

@MainActor
extension ViewportKeyboard {
    private static func entityNudgeCommands(
        for ids: [EntityID],
        by delta: Vec3,
        in scene: PrevisScene,
        currentShot: Shot?
    ) -> [ShotsCommand] {
        let shot = currentShot ?? scene.shots.first
        let take = shot.flatMap { active in
            scene.blocking.first { $0.id == active.blockingTakeID }
        } ?? scene.blocking.first
        var commands: [ShotsCommand] = []
        for id in ids {
            var placement = scene.entities.first(where: { $0.id == id })?.placement
                ?? Placement(position: .zero, heading: 0, scale: 1)
            placement.position = Vec3(
                placement.position.x + delta.x,
                placement.position.y + delta.y,
                placement.position.z + delta.z
            )
            commands.append(.setPlacement(id, placement))
            if let shotID = shot?.id,
               let track = take?.tracks.first(where: { $0.entityID == id }) {
                for var mark in track.marks {
                    mark.position = Vec3(
                        mark.position.x + delta.x,
                        mark.position.y + delta.y,
                        mark.position.z + delta.z
                    )
                    mark.via = mark.via.map { waypoint in
                        Vec3(waypoint.x + delta.x, waypoint.y + delta.y, waypoint.z + delta.z)
                    }
                    commands.append(.updateActorMark(shotID, id, mark))
                }
            }
        }
        return commands
    }

    private static func nudgeActorMark(
        entityID: EntityID,
        markID: MarkID,
        by delta: Vec3,
        in store: ShotsStore,
        session: ViewportLiveSession?
    ) -> Bool {
        guard let scene = store.currentScene,
              let shot = store.currentShot
        else { return false }
        let take = scene.blocking.first { $0.id == shot.blockingTakeID } ?? scene.blocking.first
        guard var mark = take?.tracks.first(where: { $0.entityID == entityID })?.marks
            .first(where: { $0.id == markID })
        else { return false }
        let before = store.document
        mark.position = Vec3(
            mark.position.x + delta.x,
            mark.position.y + delta.y,
            mark.position.z + delta.z
        )
        store.run(.updateActorMark(shot.id, entityID, mark))
        guard store.document != before else { return false }
        session?.postAnnouncement("Nudged actor mark \(markID)")
        return true
    }

    private static func nudgeCameraMark(
        markID: MarkID,
        by delta: Vec3,
        in store: ShotsStore,
        session: ViewportLiveSession?
    ) -> Bool {
        guard let shot = store.currentShot,
              var mark = shot.camera.marks.first(where: { $0.id == markID })
        else { return false }
        let before = store.document
        let mountPose = ViewportHandles.resolveMountPose(for: shot, at: mark.time, in: store)
        let target = ViewportHandleTarget.cameraMark(
            shotID: shot.id,
            initialMark: mark,
            mountPose: mountPose
        )
        let newWorldPos = Vec3(
            target.worldPivot.x + delta.x,
            target.worldPivot.y + delta.y,
            target.worldPivot.z + delta.z
        )
        if let mount = mountPose {
            let dx = newWorldPos.x - mount.position.x
            let dz = newWorldPos.z - mount.position.z
            let c = cos(mount.heading)
            let s = sin(mount.heading)
            mark.position = Vec3(
                dx * c - dz * s,
                newWorldPos.y - mount.position.y,
                dx * s + dz * c
            )
        } else {
            mark.position = newWorldPos
        }
        store.run(.updateCameraMark(shot.id, mark))
        guard store.document != before else { return false }
        session?.postAnnouncement("Nudged camera mark \(markID)")
        return true
    }
}

@MainActor
extension ViewportKeyboard {
    static func frameSelection(in store: ShotsStore, session: ViewportLiveSession?) -> Bool {
        cancelActivePreview(in: store, session: session)
        guard let session,
              frameSelection(in: store, camera: &session.editorCamera, size: session.viewportSize)
        else {
            return false
        }
        session.syncCamera(in: store)
        session.postAnnouncement("Framed selection")
        return true
    }

    static func frameSelection(
        in store: ShotsStore,
        camera: inout EditorCamera,
        size: PixelSize
    ) -> Bool {
        guard let bounds = selectionBounds(in: store) else { return false }
        let center = Vec3(
            (bounds.min.x + bounds.max.x) * 0.5,
            (bounds.min.y + bounds.max.y) * 0.5,
            (bounds.min.z + bounds.max.z) * 0.5
        )
        let extentX = max(bounds.max.x - bounds.min.x, 0)
        let extentY = max(bounds.max.y - bounds.min.y, 0)
        let extentZ = max(bounds.max.z - bounds.min.z, 0)
        let halfDiagonal = (extentX * extentX + extentY * extentY + extentZ * extentZ).squareRoot() * 0.5
        let radius = max(halfDiagonal, minimumFrameRadiusMeters)

        let safeSize = PixelSize(width: max(size.width, 1), height: max(size.height, 1))
        let camFrame = camera.cameraFrame(for: safeSize)
        let vHalfFOV = max(camFrame.verticalFOV * 0.5, 0.05)
        let hHalfFOV = max(atan(tan(vHalfFOV) * max(safeSize.aspect, 0.1)), 0.05)
        let minHalfFOV = min(vHalfFOV, hHalfFOV)
        let fittedDistance = (radius * framePaddingFactor) / tan(minHalfFOV)

        camera.target = center
        camera.distance = fittedDistance
        return true
    }

    static func selectionBounds(in store: ShotsStore) -> Box3? {
        guard let scene = store.currentScene else { return nil }
        let frame = store.frame
        switch store.selection {
        case .none:
            return nil
        case let .entities(ids):
            var boxes: [Box3] = []
            for id in ids {
                if let entityFrame = frame?.entities.first(where: { $0.id == id }) {
                    boxes.append(entityFrame.bounds)
                } else if let entity = scene.entities.first(where: { $0.id == id }) {
                    boxes.append(pointBounds(around: entity.placement.position, halfExtent: 0.5))
                }
            }
            return unionBounds(boxes)
        case let .actorMark(entityID, markID):
            guard let shot = store.currentShot else { return nil }
            let take = scene.blocking.first { $0.id == shot.blockingTakeID } ?? scene.blocking.first
            guard let mark = take?.tracks.first(where: { $0.entityID == entityID })?.marks
                .first(where: { $0.id == markID })
            else { return nil }
            return pointBounds(around: mark.position, halfExtent: minimumFrameRadiusMeters)
        case let .cameraMark(markID):
            guard let shot = store.currentShot,
                  let mark = shot.camera.marks.first(where: { $0.id == markID })
            else { return nil }
            let mountPose = ViewportHandles.resolveMountPose(for: shot, at: mark.time, in: store)
            let target = ViewportHandleTarget.cameraMark(shotID: shot.id, initialMark: mark, mountPose: mountPose)
            return pointBounds(around: target.worldPivot, halfExtent: minimumFrameRadiusMeters)
        case .camera:
            if let camPos = frame?.camera.position {
                return pointBounds(around: camPos, halfExtent: minimumFrameRadiusMeters)
            }
            guard let shot = store.currentShot,
                  let mark = ViewportHandles.activeCameraMark(
                      in: shot,
                      at: FrameGrid.time(ofFrame: store.playhead)
                  )
            else { return nil }
            let mountPose = ViewportHandles.resolveMountPose(for: shot, at: mark.time, in: store)
            let target = ViewportHandleTarget.cameraMark(shotID: shot.id, initialMark: mark, mountPose: mountPose)
            return pointBounds(around: target.worldPivot, halfExtent: minimumFrameRadiusMeters)
        }
    }
}

extension ViewportKeyboard {
    private static func pointBounds(around point: Vec3, halfExtent: Double) -> Box3 {
        Box3(
            min: Vec3(point.x - halfExtent, point.y - halfExtent, point.z - halfExtent),
            max: Vec3(point.x + halfExtent, point.y + halfExtent, point.z + halfExtent)
        )
    }

    private static func unionBounds(_ boxes: [Box3]) -> Box3? {
        guard let first = boxes.first else { return nil }
        var low = first.min
        var high = first.max
        for box in boxes.dropFirst() {
            low = Vec3(min(low.x, box.min.x), min(low.y, box.min.y), min(low.z, box.min.z))
            high = Vec3(max(high.x, box.max.x), max(high.y, box.max.y), max(high.z, box.max.z))
        }
        return Box3(min: low, max: high)
    }
}

/// Focusable AppKit key-capture overlay for `ShotCameraView` so look-through mode accepts viewport-focused
/// shortcuts (such as `C` to return to `ShotsViewport` and `1–9` camera-mark jumps) without intercepting
/// text editing or non-viewport responders.
struct ViewportKeyCaptureOverlay: NSViewRepresentable {
    var session: ViewportLiveSession?
    var selection: ShotsSelection = .none
    var claimFocusOnAppear = false
    var onClaimedFocus: (() -> Void)?
    var onSync: (() -> Void)?
    var onKeyDown: ((String?, UInt16, NSEvent.ModifierFlags) -> Bool)?

    func makeNSView(context: Context) -> KeyCapturingView {
        let view = KeyCapturingView()
        configure(view)
        onSync?()
        return view
    }

    func updateNSView(_ nsView: KeyCapturingView, context: Context) {
        configure(nsView)
        onSync?()
    }

    private func configure(_ view: KeyCapturingView) {
        view.session = session
        session?.hostView = view
        view.onKeyDown = onKeyDown
        view.onClaimedFocus = onClaimedFocus
        if claimFocusOnAppear {
            view.requestFocusIfNeeded()
        }
    }

    final class KeyCapturingView: NSView {
        weak var session: ViewportLiveSession?
        var onClaimedFocus: (() -> Void)?
        var onKeyDown: ((String?, UInt16, NSEvent.ModifierFlags) -> Bool)?
        private var pendingFocusRequest = false

        override var acceptsFirstResponder: Bool {
            true
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            true
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if pendingFocusRequest {
                requestFocusIfNeeded()
            }
        }

        func requestFocusIfNeeded() {
            guard let window else {
                pendingFocusRequest = true
                return
            }
            pendingFocusRequest = false
            window.makeFirstResponder(self)
            onClaimedFocus?()
        }

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
        }

        override func keyDown(with event: NSEvent) {
            if let responder = window?.firstResponder {
                if responder is NSText { return }
                if responder !== self, responder !== window { return }
            }
            if onKeyDown?(event.charactersIgnoringModifiers, event.keyCode, event.modifierFlags) == true {
                return
            }
            super.keyDown(with: event)
        }
    }
}
