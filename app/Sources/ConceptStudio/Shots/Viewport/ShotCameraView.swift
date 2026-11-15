import CoreGraphics
import Observation
import PrevisCore
import ShotsMedia
import SwiftUI

/// Immutable snapshot of the inputs required to render one shot-camera look-through frame.
struct ShotCameraRenderRequest: Sendable, Equatable {
    let sceneID: SceneID
    let sceneRevision: Int
    let shotID: ShotID
    let shotName: String
    let frame: SceneFrame
    let look: PrevisLook
    /// Where the plate images are, and the shot's film format: what drawing the frame over its plate needs.
    var plateFolder: URL?
    var sensor: Sensor = .super35

    @MainActor
    static func make(from store: ShotsStore) -> ShotCameraRenderRequest? {
        guard let scene = store.currentScene,
              let shot = store.currentShot,
              let frame = store.frame
        else {
            return nil
        }
        return ShotCameraRenderRequest(
            sceneID: scene.id,
            sceneRevision: scene.revision,
            shotID: shot.id,
            shotName: shot.name,
            frame: frame,
            look: PrevisLook(scene: scene),
            plateFolder: store.plateFolder,
            sensor: shot.camera.sensor
        )
    }
}

/// Coalesces offscreen `ShotFrameRenderer` requests for `ShotCameraView` so at most one render is in flight
/// and at most one newest pending request waits behind it (`LANE-D-VIEWPORT.md` lines 47-49, 136-144).
@MainActor
@Observable
final class ShotCameraPreviewSession {
    typealias RenderClosure = @MainActor (SceneFrame, PrevisLook) async throws -> CGImage

    private final class RendererBox {
        var renderer: ShotFrameRenderer?
        var plates: PlateImages?
        /// The request being rendered, so the default renderer can find the frame's plate.
        var request: ShotCameraRenderRequest?
    }

    private let box = RendererBox()

    private(set) var renderedImage: CGImage?
    private(set) var renderedRequest: ShotCameraRenderRequest?
    private(set) var isRendering = false
    private(set) var errorMessage: String?

    private let renderClosure: RenderClosure
    private var desiredRequest: ShotCameraRenderRequest?
    private var inFlightRequest: ShotCameraRenderRequest?
    private var pendingRequest: ShotCameraRenderRequest?
    private var onErrorHandler: (@MainActor (String) -> Void)?
    private var drainTask: Task<Void, Never>?
    private var activeDrainRunID: UInt64 = 0

    init(renderImage: RenderClosure? = nil) {
        if let renderImage {
            renderClosure = renderImage
        } else {
            let box = box
            renderClosure = { frame, look in
                if box.renderer == nil {
                    box.renderer = try ShotFrameRenderer()
                }
                guard let renderer = box.renderer else {
                    throw ShotsMediaError("Shots couldn't initialize the frame renderer.")
                }
                // A shot blocked over a plate is drawn over it, with the plate's own set pieces showing faintly
                // so they can be fitted to it.
                if let plate = frame.plate, let request = box.request, let folder = request.plateFolder {
                    if box.plates?.folder != folder { box.plates = PlateImages(folder: folder) }
                    if let image = try? box.plates?.image(for: plate) {
                        return try await renderer.image(
                            of: frame, over: image, look: look, options: .blocking, sensor: request.sensor
                        )
                    }
                }
                return try await renderer.image(of: frame, look: look)
            }
        }
    }

    func requestRender(for store: ShotsStore) {
        requestRender(ShotCameraRenderRequest.make(from: store), onError: store.onError)
    }

    func requestRender(_ request: ShotCameraRenderRequest?, onError: (@MainActor (String) -> Void)? = nil) {
        onErrorHandler = onError
        guard let request else {
            clearContext()
            return
        }
        if let renderedRequest,
           renderedRequest.sceneID != request.sceneID
           || renderedRequest.shotID != request.shotID
           || renderedRequest.frame.canvas != request.frame.canvas {
            renderedImage = nil
            self.renderedRequest = nil
            errorMessage = nil
        }
        desiredRequest = request
        if renderedRequest == request,
           renderedImage != nil,
           inFlightRequest == nil,
           pendingRequest == nil,
           errorMessage == nil {
            return
        }
        if inFlightRequest == request {
            pendingRequest = nil
            return
        }
        pendingRequest = request
        isRendering = true
        if drainTask == nil {
            activeDrainRunID &+= 1
            let runID = activeDrainRunID
            drainTask = Task { @MainActor [weak self] in
                await self?.drainQueue(runID: runID)
            }
        }
    }

    func cancel() {
        activeDrainRunID &+= 1
        drainTask?.cancel()
        drainTask = nil
        pendingRequest = nil
        inFlightRequest = nil
        isRendering = false
    }

    func waitForIdle() async {
        while let task = drainTask {
            await task.value
        }
    }

    private func clearContext() {
        cancel()
        desiredRequest = nil
        renderedImage = nil
        renderedRequest = nil
        errorMessage = nil
    }

    private func drainQueue(runID: UInt64) async {
        while activeDrainRunID == runID, !Task.isCancelled, let next = pendingRequest {
            pendingRequest = nil
            inFlightRequest = next
            isRendering = true
            do {
                box.request = next
                let image = try await renderClosure(next.frame, next.look)
                guard activeDrainRunID == runID, !Task.isCancelled else { break }
                if desiredRequest?.sceneID == next.sceneID,
                   desiredRequest?.shotID == next.shotID,
                   desiredRequest?.frame.canvas == next.frame.canvas {
                    if pendingRequest == nil || renderedImage == nil {
                        renderedImage = image
                        renderedRequest = next
                    }
                    errorMessage = nil
                }
            } catch is CancellationError {
                break
            } catch {
                guard activeDrainRunID == runID, !Task.isCancelled else { break }
                if desiredRequest?.sceneID == next.sceneID,
                   desiredRequest?.shotID == next.shotID {
                    let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    errorMessage = message
                    renderedImage = nil
                    renderedRequest = nil
                    onErrorHandler?(message)
                }
            }
        }
        if activeDrainRunID == runID {
            inFlightRequest = nil
            isRendering = false
            drainTask = nil
        }
    }
}

/// Look-through view for the active shot camera, rendered through `ShotFrameRenderer` with `PrevisLook(scene:)`
/// and letterboxed to the shot canvas (`CONTRACTS.md` section 7, `LANE-D-VIEWPORT.md` lines 47-49, 136-144).
///
/// Reference: Blockout `src/renderer/viewport/SceneManager.ts:2101-2105, 2220-2240, 2371-2450` and
/// `src/renderer/viewport/Viewport.tsx:335-374, 540-588`.
struct ShotCameraView: View {
    let store: ShotsStore
    var externalSession: ViewportLiveSession?
    var onToggleLookThrough: (() -> Void)?
    var claimFocusOnAppear = false
    var onClaimedFocus: (() -> Void)?

    /// The look-through render queue (D5 rendering slice).
    @State var session: ShotCameraPreviewSession
    /// The viewport's live session, shared with the scene view for keys, focus and announcements (D5 keyboard slice).
    @State private var ownedLiveSession = ViewportLiveSession()
    /// Selecting a stand-in and sliding it along the floor, straight on the picture.
    @State private var floorDrag = ShotCameraFloorDrag()

    init(
        store: ShotsStore,
        externalSession: ViewportLiveSession? = nil,
        onToggleLookThrough: (() -> Void)? = nil,
        claimFocusOnAppear: Bool = false,
        onClaimedFocus: (() -> Void)? = nil,
        session: ShotCameraPreviewSession? = nil
    ) {
        self.store = store
        self.externalSession = externalSession
        self.onToggleLookThrough = onToggleLookThrough
        self.claimFocusOnAppear = claimFocusOnAppear
        self.onClaimedFocus = onClaimedFocus
        _session = State(initialValue: session ?? ShotCameraPreviewSession())
    }

    var liveSession: ViewportLiveSession {
        externalSession ?? ownedLiveSession
    }

    static func letterboxRect(in containerSize: CGSize, canvas: ShotCanvas) -> CGRect {
        guard containerSize.width > 0, containerSize.height > 0,
              canvas.width > 0, canvas.height > 0
        else {
            return .zero
        }
        let aspect = CGFloat(canvas.aspect)
        var fittedWidth = containerSize.width
        var fittedHeight = fittedWidth / aspect
        if fittedHeight > containerSize.height {
            fittedHeight = containerSize.height
            fittedWidth = fittedHeight * aspect
        }
        let originX = (containerSize.width - fittedWidth) * 0.5
        let originY = (containerSize.height - fittedHeight) * 0.5
        return CGRect(x: originX, y: originY, width: fittedWidth, height: fittedHeight)
    }

    private var canvas: ShotCanvas {
        store.currentShot?.canvas ?? .portrait
    }

    var body: some View {
        let currentRequest = ShotCameraRenderRequest.make(from: store)
        let currentSelection = store.selection

        GeometryReader { geometry in
            let currentSize = PixelSize(
                width: max(Int(geometry.size.width.rounded()), 1),
                height: max(Int(geometry.size.height.rounded()), 1)
            )
            let innerSize = CGSize(
                width: max(geometry.size.width - 16, 1),
                height: max(geometry.size.height - 16, 1)
            )
            let rect = Self.letterboxRect(in: innerSize, canvas: canvas)
            ZStack {
                InstantPrint.ground
                canvasSurface(size: rect.size)
                    .frame(width: max(rect.width, 1), height: max(rect.height, 1))
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay {
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Color.primary.opacity(0.20), lineWidth: 1)
                    }

                ViewportKeyCaptureOverlay(
                    session: liveSession,
                    selection: currentSelection,
                    claimFocusOnAppear: claimFocusOnAppear,
                    onClaimedFocus: onClaimedFocus,
                    onPointer: { phase, location in
                        // The canvas is centred in the view; pointer positions become fractions of the canvas.
                        let origin = CGPoint(
                            x: (geometry.size.width - rect.width) / 2, y: (geometry.size.height - rect.height) / 2
                        )
                        guard rect.width > 0, rect.height > 0 else { return }
                        let point = Point2(
                            x: (location.x - origin.x) / rect.width, y: (location.y - origin.y) / rect.height
                        )
                        floorDrag.handle(phase, at: point, in: store)
                        if phase == .up { liveSession.syncSelectionAnnouncement(with: store) }
                    },
                    onSync: {
                        liveSession.viewportSize = currentSize
                        liveSession.syncSelectionAnnouncement(with: store)
                    },
                    onKeyDown: { characters, keyCode, modifiers in
                        liveSession.viewportSize = currentSize
                        let handled = ViewportKeyboard.handleKeyDown(
                            charactersIgnoringModifiers: characters,
                            keyCode: keyCode,
                            modifiers: modifiers,
                            in: store,
                            session: liveSession,
                            onToggleLookThrough: onToggleLookThrough
                        )
                        if handled {
                            liveSession.syncSelectionAnnouncement(with: store)
                        }
                        return handled
                    }
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear {
                liveSession.viewportSize = currentSize
                liveSession.syncSelectionAnnouncement(with: store)
            }
            .onChange(of: currentSelection) { _, _ in
                liveSession.syncSelectionAnnouncement(with: store)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.primary.opacity(0.18), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabelText)
        .onAppear {
            session.requestRender(currentRequest, onError: store.onError)
        }
        .onChange(of: currentRequest) { _, updated in
            session.requestRender(updated, onError: store.onError)
        }
        .onDisappear {
            session.cancel()
        }
    }

    var activeRenderedRequest: ShotCameraRenderRequest? {
        guard session.renderedImage != nil,
              session.errorMessage == nil,
              let rendered = session.renderedRequest,
              rendered.sceneID == store.currentSceneID,
              rendered.shotID == store.currentShotID,
              rendered.frame.canvas == canvas
        else {
            return nil
        }
        return rendered
    }

    @ViewBuilder
    private func canvasSurface(size: CGSize) -> some View {
        if let image = session.renderedImage,
           activeRenderedRequest != nil {
            ZStack(alignment: .bottomLeading) {
                Image(decorative: image, scale: 1.0, orientation: .up)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size.width, height: size.height)

                Text(captionText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                    .monospacedDigit()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(InstantPrint.ground.opacity(0.88), in: RoundedRectangle(cornerRadius: 4))
                    .overlay {
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Color.primary.opacity(0.16), lineWidth: 1)
                    }
                    .padding(8)
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: session.errorMessage == nil ? "video" : "exclamationmark.triangle")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("Shot camera")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(session.errorMessage ?? captionText)
                    .font(.system(size: 12))
                    .foregroundStyle(StudioStyle.supportingText)
                    .monospacedDigit()
                    .multilineTextAlignment(.center)
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    var captionText: String {
        if let rendered = activeRenderedRequest {
            let canvasText = "\(rendered.frame.canvas.width) × \(rendered.frame.canvas.height)"
            let frameIndex = rendered.frame.index ?? FrameGrid.frame(atTime: rendered.frame.time)
            return "Shot \(rendered.shotName) · \(canvasText) · Frame \(frameIndex)"
        }
        guard let shot = store.currentShot else {
            return "No active shot · \(canvas.width) × \(canvas.height)"
        }
        return "Shot \(shot.name) · \(canvas.width) × \(canvas.height) · Frame \(store.playhead)"
    }

    /// The caption, then a render error if there is one, then the selection when something is selected.
    var accessibilityLabelText: String {
        var parts = ["Shot camera preview", captionText]
        if let errorMessage = session.errorMessage {
            parts.append(errorMessage)
        }
        if store.selection != .none {
            parts.append(ViewportLiveSession.selectionAnnouncement(for: store.selection, in: store))
        }
        return parts.joined(separator: ". ")
    }
}

/// Pointer editing in the look-through view: a click selects the stand-in under it, and a drag slides the selected
/// one along the floor it stands on, seen through the shot camera. With a plate behind, that is blocking directly
/// on the plate. The drag previews through `store.preview` and commits once on release, as one undo step.
@MainActor
struct ShotCameraFloorDrag {
    private struct Active {
        let entityID: EntityID
        let scene: PrevisScene
        let shot: Shot
        let camera: CameraFrame
        let canvas: PixelSize
        let planeY: Double
        let start: Vec3
    }

    private var active: Active?
    private var pressed: Point2?
    private var moved = false

    mutating func handle(_ phase: ViewportKeyCaptureOverlay.PointerPhase, at point: Point2, in store: ShotsStore) {
        switch phase {
        case .down:
            pressed = point
            moved = false
            active = nil
        case .moved:
            guard let pressed, !store.isReadOnly else { return }
            if !moved, hypot(point.x - pressed.x, point.y - pressed.y) < 0.008 { return }
            moved = true
            if active == nil { active = Self.begin(at: pressed, in: store) }
            guard let active, let hit = Self.floorHit(
                point,
                camera: active.camera,
                canvas: active.canvas,
                planeY: active.planeY
            )
            else { return }
            let delta = Vec3(hit.x - active.start.x, 0, hit.z - active.start.z)
            store.preview = ViewportKeyboard.entityNudgeCommands(
                for: [active.entityID], by: delta, in: active.scene, currentShot: active.shot
            )
        case .up:
            defer {
                active = nil
                pressed = nil
            }
            if moved, active != nil {
                let commands = store.preview
                store.preview = []
                if !commands.isEmpty { store.run(commands) }
            } else if let pressed {
                Self.select(at: pressed, in: store)
            }
        }
    }

    /// The actor whose visible part is under the point becomes the selection; a click on nothing clears it.
    static func select(at point: Point2, in store: ShotsStore) {
        guard let frame = store.frame, (0 ... 1).contains(point.x), (0 ... 1).contains(point.y) else { return }
        let hit = StagingAnalysis.characters(in: frame).filter(\.isVisible).filter { character in
            guard let box = character.box else { return false }
            return point.x >= box.x && point.x <= box.x + box.width && point.y >= box.y && point.y <= box.y + box.height
        }
        // The nearest of several overlapping stand-ins is the one in front.
        if let nearest = hit.min(by: { $0.distance < $1.distance }) {
            store.selection = .entities([nearest.entityID])
        } else {
            store.selection = .none
        }
    }

    /// A drag moves the one selected entity. Without a selection it first selects what is under the press.
    private static func begin(at point: Point2, in store: ShotsStore) -> Active? {
        if case .entities = store.selection {} else { select(at: point, in: store) }
        guard case let .entities(ids) = store.selection, let id = ids.first,
              let scene = store.document.scenes.first(where: { $0.id == store.currentSceneID }),
              let shot = scene.shots.first(where: { $0.id == store.currentShotID }),
              let frame = store.frame, let posed = frame.entities.first(where: { $0.id == id }),
              let start = floorHit(
                  point,
                  camera: frame.camera,
                  canvas: frame.canvas.pixelSize,
                  planeY: posed.position.y
              )
        else { return nil }
        return Active(
            entityID: id, scene: scene, shot: shot, camera: frame.camera, canvas: frame.canvas.pixelSize,
            planeY: posed.position.y, start: start
        )
    }

    /// Where the shot camera's line of sight through a point of the canvas meets the level the entity stands on.
    static func floorHit(_ point: Point2, camera: CameraFrame, canvas: PixelSize, planeY: Double) -> Vec3? {
        let ray = camera.ray(
            through: Point2(x: point.x * Double(canvas.width), y: point.y * Double(canvas.height)), size: canvas
        )
        guard ray.direction.y < -1e-4 else { return nil }
        let distance = (planeY - ray.origin.y) / ray.direction.y
        guard distance > 0, distance < 400 else { return nil }
        return Vec3(ray.origin.x + ray.direction.x * distance, planeY, ray.origin.z + ray.direction.z * distance)
    }
}
