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
            look: PrevisLook(scene: scene)
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
    }

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
            let box = RendererBox()
            renderClosure = { frame, look in
                if box.renderer == nil {
                    box.renderer = try ShotFrameRenderer()
                }
                guard let renderer = box.renderer else {
                    throw ShotsMediaError("Shots couldn't initialize the frame renderer.")
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
