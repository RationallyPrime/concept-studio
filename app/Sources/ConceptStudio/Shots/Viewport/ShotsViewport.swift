import AppKit
import PrevisCore
import RealityKit
import ShotsMedia
import SwiftUI

/// Free editor camera viewport for 3D shot blocking (CONTRACTS section 7).
/// D1 renders `store.frame` through `PrevisSceneMapper` alongside a separate `overlayRoot` holding the ground grid,
/// with post effects disabled and orbit/pan/dolly trackpad and mouse gestures.
///
/// Reference: Blockout `src/renderer/viewport/Viewport.tsx:19-99, 329-604` and
/// `src/renderer/viewport/SceneManager.ts:178-255, 370-403, 764-796, 1994-2113`.
/// Intentional Swift/RealityKit deviations:
/// - `RealityView` mounts two separate root entities (`mapper.root` and `overlayRoot`) so editor chrome never
///   leaks into exported passes (`LANE-D-VIEWPORT.md` lines 38-44; `SHOTS-PLAN.md` section 4).
/// - Post effects (`motionBlur`, `depthOfField`, `cameraGrain`, HDR) are disabled on `RealityView` content.
struct ShotsViewport: View {
    let store: ShotsStore

    @State private var editorCamera = EditorCamera.defaultView
    @State private var mapper = PrevisSceneMapper(look: PrevisLook(lighting: .day))
    @State private var overlayRoot = ViewportGrid.makeOverlayRoot()
    @State private var viewportSize = PixelSize(width: 640, height: 480)
    @State private var lastDragTranslation: CGSize?
    @State private var pinchStartDistance: Double?

    init(store: ShotsStore) {
        self.store = store
    }

    var body: some View {
        GeometryReader { geometry in
            let currentSize = PixelSize(
                width: max(Int(geometry.size.width.rounded()), 1),
                height: max(Int(geometry.size.height.rounded()), 1)
            )
            ZStack(alignment: .topLeading) {
                InstantPrint.ground

                RealityView { content in
                    content.renderingEffects.motionBlur = .disabled
                    content.renderingEffects.depthOfField = .disabled
                    content.renderingEffects.cameraGrain = .disabled
                    content.renderingEffects.dynamicRange = .standard
                    ViewportGrid.disableOcclusionCulling(on: mapper.root)
                    ViewportGrid.disableOcclusionCulling(on: overlayRoot)
                    content.add(mapper.root)
                    content.add(overlayRoot)
                    syncScene(in: content, size: currentSize)
                } update: { content in
                    syncScene(in: content, size: currentSize)
                }
                .gesture(dragGesture(for: currentSize))
                .gesture(magnifyGesture)

                ViewportScrollWheelOverlay { event in
                    let optionPressed = event.modifierFlags.contains(.option)
                    ViewportCameraGestures.applyScrollOrTrackpad(
                        to: &editorCamera,
                        scrollingDeltaX: event.scrollingDeltaX,
                        scrollingDeltaY: event.scrollingDeltaY,
                        hasPreciseScrollingDeltas: event.hasPreciseScrollingDeltas,
                        optionPressed: optionPressed,
                        viewportSize: currentSize
                    )
                }
                .allowsHitTesting(false)

                if hasEmptyStage {
                    emptyStagePrompt
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .allowsHitTesting(false)
                }

                viewportHUD
            }
            .onAppear { viewportSize = currentSize }
            .onChange(of: currentSize) { _, updated in viewportSize = updated }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.primary.opacity(0.16), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    private func syncScene(in content: RealityViewCameraContent, size: PixelSize) {
        if let scene = store.currentScene {
            mapper.setLook(PrevisLook(scene: scene))
        }
        if let frame = store.frame {
            mapper.apply(frame)
        }
        let cameraEntity = mapper.cameraEntity(for: editorCamera.cameraFrame(for: size))
        if cameraEntity.parent == nil, !content.entities.contains(where: { $0 === cameraEntity }) {
            content.add(cameraEntity)
        }
    }

    private func dragGesture(for size: PixelSize) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let previous = lastDragTranslation ?? .zero
                let delta = CGSize(
                    width: value.translation.width - previous.width,
                    height: value.translation.height - previous.height
                )
                lastDragTranslation = value.translation
                let optionPressed = NSEvent.modifierFlags.contains(.option)
                ViewportCameraGestures.applyDrag(
                    to: &editorCamera,
                    deltaPoints: delta,
                    viewportSize: size,
                    optionPressed: optionPressed
                )
            }
            .onEnded { _ in
                lastDragTranslation = nil
            }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let start = pinchStartDistance ?? editorCamera.distance
                pinchStartDistance = start
                let magnification = max(Double(value.magnification), 0.05)
                editorCamera.distance = start / magnification
            }
            .onEnded { _ in
                pinchStartDistance = nil
            }
    }

    private var viewportHUD: some View {
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
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(InstantPrint.ground.opacity(0.88), in: RoundedRectangle(cornerRadius: 5))
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
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
