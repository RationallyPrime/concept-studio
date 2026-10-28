import AppKit
import Observation
import PrevisCore
import RealityKit
import ShotsMedia
import SwiftUI

/// Live viewport scene state shared between `ShotsViewport`'s `RealityView` and `ViewportScrollWheelOverlay`.
/// Synchronizing through this object ensures that stage updates (`store.frame`, `store.currentScene?.lighting`)
/// and input gestures (`EditorCamera`) apply deterministically both inside live `RealityView` rendering
/// and during headless AppKit hosting layout/event routing.
@MainActor
@Observable
final class ViewportLiveSession {
    var editorCamera = EditorCamera.defaultView {
        didSet {
            ViewportOverlays.orientLabels(in: overlayRoot, to: editorCamera)
        }
    }

    let mapper = PrevisSceneMapper(look: PrevisLook(lighting: .day))
    let overlayRoot = ViewportGrid.makeOverlayRoot()
    let skyDome = ViewportGrid.makeSkyDomeEntity(for: .day)
    var viewportSize = PixelSize(width: 640, height: 480)
    private(set) var activeLighting: LightingPreset = .day
    var showMarks = true
    var showPaths = true

    func setShowMarks(_ visible: Bool) {
        showMarks = visible
        ViewportOverlays.ensureGroup(named: ViewportOverlays.marksGroupName, in: overlayRoot).isEnabled = visible
    }

    func setShowPaths(_ visible: Bool) {
        showPaths = visible
        ViewportOverlays.ensureGroup(named: ViewportOverlays.pathsGroupName, in: overlayRoot).isEnabled = visible
    }

    func toggleMarks() {
        setShowMarks(!showMarks)
    }

    func togglePaths() {
        setShowPaths(!showPaths)
    }

    func sync(with store: ShotsStore, frame: SceneFrame?, size: PixelSize) {
        viewportSize = size
        let lighting = store.currentScene?.lighting ?? .day
        activeLighting = lighting
        mapper.setLook(PrevisLook(lighting: lighting))
        ViewportGrid.updateSkyDome(skyDome, for: lighting)

        if let frame {
            mapper.apply(frame)
        } else {
            let emptyFrame = SceneFrame(
                index: 0,
                time: 0,
                canvas: store.currentShot?.canvas ?? .portrait,
                camera: editorCamera.cameraFrame(for: size),
                entities: []
            )
            mapper.apply(emptyFrame)
        }
        ViewportOverlays.sync(
            overlayRoot: overlayRoot,
            scene: store.currentScene,
            shot: store.currentShot,
            evaluator: store.evaluator,
            frame: frame,
            selection: store.selection,
            showMarks: showMarks,
            showPaths: showPaths
        )
        syncCamera()
    }

    func syncCamera() {
        ViewportOverlays.orientLabels(in: overlayRoot, to: editorCamera)
        _ = mapper.cameraEntity(for: editorCamera.cameraFrame(for: viewportSize))
    }

    var mappedEntityContainerNames: [String] {
        var names: [String] = []
        func collect(from entity: Entity) {
            if entity.name.hasPrefix("previs:") {
                names.append(entity.name)
            }
            for child in entity.children {
                collect(from: child)
            }
        }
        collect(from: mapper.root)
        return names.sorted()
    }
}

/// Free editor camera viewport for 3D shot blocking (CONTRACTS section 7).
/// D1 renders `store.frame` through `PrevisSceneMapper` alongside a separate `overlayRoot` holding the ground grid,
/// with post effects disabled and orbit/pan/dolly trackpad and mouse gestures.
///
/// Reference: Blockout `src/renderer/viewport/Viewport.tsx:19-99, 329-604` and
/// `src/renderer/viewport/SceneManager.ts:178-255, 370-403, 764-796, 1994-2113`.
/// Intentional Swift/RealityKit deviations:
/// - `RealityView` mounts separate root entities (`mapper.root`, `overlayRoot`, and `skyDome`) so editor chrome never
///   leaks into exported passes (`LANE-D-VIEWPORT.md` lines 38-44; `SHOTS-PLAN.md` section 4).
/// - Post effects (`motionBlur`, `depthOfField`, `cameraGrain`, HDR) are disabled on `RealityView` content.
struct ShotsViewport: View {
    let store: ShotsStore

    @State var session = ViewportLiveSession()

    var body: some View {
        let activeLighting = store.currentScene?.lighting ?? .day
        let currentFrame = store.frame
        let currentSelection = store.selection
        let showMarks = session.showMarks
        let showPaths = session.showPaths

        GeometryReader { geometry in
            let currentSize = PixelSize(
                width: max(Int(geometry.size.width.rounded()), 1),
                height: max(Int(geometry.size.height.rounded()), 1)
            )
            ZStack(alignment: .topLeading) {
                ViewportGrid.backgroundColor(for: activeLighting)

                RealityView { content in
                    content.renderingEffects.motionBlur = .disabled
                    content.renderingEffects.depthOfField = .disabled
                    content.renderingEffects.cameraGrain = .disabled
                    content.renderingEffects.dynamicRange = .standard
                    ViewportGrid.disableOcclusionCulling(on: session.mapper.root)
                    ViewportGrid.disableOcclusionCulling(on: session.overlayRoot)
                    ViewportGrid.disableOcclusionCulling(on: session.skyDome)
                    content.add(session.skyDome)
                    content.add(session.mapper.root)
                    content.add(session.overlayRoot)
                    syncScene(in: content, frame: currentFrame, size: currentSize)
                } update: { content in
                    _ = (currentSelection, showMarks, showPaths)
                    syncScene(in: content, frame: currentFrame, size: currentSize)
                }

                ViewportScrollWheelOverlay(
                    session: session,
                    onSync: {
                        _ = (currentSelection, showMarks, showPaths)
                        session.sync(with: store, frame: currentFrame, size: currentSize)
                    },
                    onScroll: { event in
                        let optionPressed = event.modifierFlags.contains(.option)
                        ViewportCameraGestures.applyScrollOrTrackpad(
                            to: &session.editorCamera,
                            scrollingDeltaX: event.scrollingDeltaX,
                            scrollingDeltaY: event.scrollingDeltaY,
                            hasPreciseScrollingDeltas: event.hasPreciseScrollingDeltas,
                            optionPressed: optionPressed,
                            viewportSize: currentSize
                        )
                        session.syncCamera()
                    },
                    onDrag: { delta, optionPressed in
                        ViewportCameraGestures.applyDrag(
                            to: &session.editorCamera,
                            deltaPoints: delta,
                            viewportSize: currentSize,
                            optionPressed: optionPressed
                        )
                        session.syncCamera()
                    },
                    onMagnify: { magnification in
                        ViewportCameraGestures.applyMagnify(
                            to: &session.editorCamera,
                            magnification: magnification
                        )
                        session.syncCamera()
                    }
                )

                if hasEmptyStage {
                    emptyStagePrompt
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .allowsHitTesting(false)
                }

                viewportHUD
            }
            .onAppear {
                session.sync(with: store, frame: currentFrame, size: currentSize)
            }
            .onChange(of: currentSize) { _, updated in
                session.sync(with: store, frame: currentFrame, size: updated)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.primary.opacity(0.16), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    private func syncScene(in content: RealityViewCameraContent, frame: SceneFrame?, size: PixelSize) {
        session.sync(with: store, frame: frame, size: size)
        let cameraEntity = session.mapper.cameraEntity(for: session.editorCamera.cameraFrame(for: size))
        if cameraEntity.parent == nil, !content.entities.contains(where: { $0 === cameraEntity }) {
            content.add(cameraEntity)
        }
    }

    private var viewportHUD: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "cube.transparent")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(summaryText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .monospacedDigit()
                if store.isReadOnly {
                    Text("Read-only")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(InstantPrint.chipText)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(InstantPrint.chip, in: RoundedRectangle(cornerRadius: 4))
                }
                Divider()
                    .frame(height: 12)
            }
            .allowsHitTesting(false)

            ViewportOverlayTogglesRepresentable(session: session)
                .frame(width: 96, height: 18)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 5)
                .fill(InstantPrint.ground.opacity(0.88))
                .allowsHitTesting(false)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .padding(10)
    }

    private var emptyStagePrompt: some View {
        VStack(spacing: 6) {
            Text("3D blocking viewport")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
            Text(
                store.currentShot == nil
                    ? "No active shot selected."
                    : "Click a library item, then click the floor to place it."
            )
            .font(.system(size: 12))
            .foregroundStyle(StudioStyle.supportingText)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(InstantPrint.ground.opacity(0.88), in: RoundedRectangle(cornerRadius: 6))
    }

    private var hasEmptyStage: Bool {
        guard let scene = store.currentScene else { return true }
        return (store.frame?.entities.count ?? scene.entities.count) == 0
    }

    private var summaryText: String {
        guard let scene = store.currentScene, let shot = store.currentShot else {
            return "No active shot selected."
        }
        let entityCount = store.frame?.entities.count ?? scene.entities.count
        let lens = Int((store.frame?.camera.focalLength ?? 35).rounded())
        let frameSummary = "Frame \(store.playhead) of \(shot.frameCount)"
        return "\(scene.name) · Shot \(shot.name) · \(lens) mm · \(frameSummary) · \(entityCount) entities"
    }

    private var accessibilityDescription: String {
        if store.isReadOnly {
            return "3D blocking viewport, read-only. \(summaryText)"
        }
        return "3D blocking viewport. \(summaryText)"
    }
}
