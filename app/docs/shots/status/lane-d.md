# Lane D status

Owner: Metis (Gemini). Canonical branch: `shots/d-viewport`. Current base `main`: `c23dea809c176e77daf738c742c1d50b04ca8449` (includes merged D0 `#61`, A1 `#59`, A2 `#64`, A3 `#65`, C1 `#66`, C2 `#68`, B3 `#58`, A4 `#67`, B reader `#74`, C3 `#70`, C4 `#71`, A5 `#73`).
Reference implementation: [Blockout](https://github.com/wassermanproductions/blockout) at `3f2d0564fd575f70fc28e9bfaa7e94b05e3955d9` (`scripts/blockout/fetch.sh`).

## Checkpoints

| Checkpoint | State | Remaining work |
| --- | --- | --- |
| D0: shell and editor camera maths | **Merged** ([RationallyPrime/concept-studio#61](https://github.com/RationallyPrime/concept-studio/pull/61), `42871fbdec650df2f8436febb3d94858b71c9769`) | Complete. |
| D1: RealityView display, gestures, grid and snapshots | **Draft PR [#72](https://github.com/RationallyPrime/concept-studio/pull/72) on `shots/d-viewport`** (Round 1 review fixes applied, rebased onto `c23dea8`, audited against Blockout `3f2d056`) | Current-head CI, independent review closure, and integrator merge approval. |
| D2: overlays and playback | Ready to implement (A2 `#64`, A3 `#65`, A5 `#73`, C4 `#71` merged on `main`) | Marks (`markMesh`), path ribbons (`evaluator.paths()`), camera body and frustum (`buildCameraBody`), selection box (`BoxHelper`), overlay toggles, playback, and 3-pose sign-check snapshot (`jab-cross`, `wave`, `sit`). |
| D3: picking and tools | Unblocked (C2 `#68`, C3 `#70` merged on `main`) | CPU ray-vs-part-bounds picking, ground-plane (`y = 0`) intersection, select/shift-select, place tool (`⌥` multi-place, `Esc` cancel), and drop-marks tool (`M`). |
| D4: move and rotate handles | After D3 | Entity, actor-mark and camera-mark handles with `store.preview` while dragging and single `store.run` on release. |
| D5: look-through view, keyboard and VoiceOver | Unblocked (B3 `#58` merged on `main`) | Coalesced `ShotCameraView` rendering, letterboxed canvas, look-through parity against `middle-f0011-clean.png` on `twoPersonWalk(small: true)`, viewport keyboard shortcuts, and VoiceOver selection announcements. |
| D6: integration, performance and IT4 | Blocked on B6 | Needs merged B6; scripted IT4 workflow and release-build frame-time measurements. |

## Blockout Reference Audit & Intentional Swift/RealityKit Deviations (D0 & D1)

### Reference files inspected (`3f2d0564fd575f70fc28e9bfaa7e94b05e3955d9`)
- `src/renderer/viewport/SceneManager.ts`:
  - `lines 60-110, 178-255`: scene setup, `freeCam`, `shotCam`, `OrbitControls`, `this.overlay` group, ground grid (`new THREE.GridHelper(60, 60, 0x33343a, 0x27282d)`), environment lights and sky background.
  - `lines 343-364`: `buildCameraBody` (`0.22×0.24×0.40` body, `0.07..0.09×0.18` lens cylinder, `0xf5a524` wireframe frustum cone) — reference for D2.
  - `lines 370-403, 611-760`: `syncFromStore`, `rebuildOverlay`, `applyOverlayToggles`, `rebuildSelectionDecorations` — reference for D1/D2.
  - `lines 764-824`: `applyEnvironment` (`day` `#394048`, `goldenHour` `#3a2d1e`, `night` `#11151c`, `interiorWarm` `#27231d`, `interiorCool` `#212528`).
  - `lines 828-1000`: pointer NDC conversion, `groundHit` against `y = 0` plane, entity/camera picking, shift-click multi-selection — reference for D3.
  - `lines 1994-2118`: `applyTime(t)` deterministic frame application without frame-to-frame accumulation.
  - `lines 2371-2504`: `renderFrameAt` and `renderTopDown` (`cam.up.set(0, 0, -1)` looking straight down).
- `src/renderer/viewport/Viewport.tsx`:
  - `lines 19-99`: `Hud` showing lens (`mm`), aspect/canvas, duration/frame count, FPS, and overlay toggles.
  - `lines 329-605`: viewport layout, letterbox framing, tool hints, and empty-stage state (`"Click a library item, then click the floor to place it."`).
- `src/renderer/viewport/builders.ts`:
  - `lines 6147-6252`: `markMesh` (floor spike-tape `"T"` mark: `0.4×0.02×0.08` cross bar at `z = -0.14` + `0.08×0.02×0.4` stem at `z = 0.06` + floating number label at `y = 0.3`) and `labelSprite` — reference for D2.
- `src/engine/camera.ts`:
  - `lines 17-52`: sensor gate sizes and crop-to-aspect vertical/horizontal FOV math.
- `tests/e2e/smoke.spec.ts` (`lines 114-130`): deterministic rendering check (`same t → byte-identical frames` across interleaved renders).
- `tests/e2e/interaction.spec.ts` (`lines 30-65, 136-193`) and `tests/e2e/screenshots.spec.ts` (`lines 33-98`): viewport stage/shoot/look-through states and gizmo drag verification.

### Preserved Blockout behaviors and algorithms in D0 & D1
1. **Ground grid (`ViewportGrid.swift` ← `SceneManager.ts:200-205`):**
   - Preserves Blockout's exact `60 m × 60 m` (`-30...30` m) grid extent with `60` 1-metre divisions, center-axis color `0x33343a`, minor-division color `0x27282d`, `0.6` opacity, and placement under the editor-only `overlayRoot`.
2. **Orbit, pan, and dolly camera controls (`EditorCamera.swift`, `ViewportGestures.swift` ← `SceneManager.ts:189-198` & `OrbitControls`):**
   - Preserves initial target `(0, 1, 0)`, polar pitch clamping just shy of $\pm\pi/2$ (`maxPitch = .pi / 2 - 0.01`, matching `SceneManager.ts:197`), viewport-height-normalised orbit speed (`2π / viewportHeight` radians per point, matching `OrbitControls.handleMouseMoveRotate`), and perspective image-plane pan scaling (`2 * distance * tan(verticalFOV / 2) / viewportHeight` metres per point along camera right/up, matching `OrbitControls.pan`).
   - Preserves top-down camera orientation (`yaw = 0`, `pitch = -maxPitch`, aligning camera $+Y$ with world $-Z$, matching `cam.up.set(0, 0, -1)` in `SceneManager.ts:2481`).
   - Trackpad two-finger scroll gestures (`hasPreciseScrollingDeltas == true`) always pan in both axes (`applyPan`), including purely vertical (`scrollingDeltaX == 0`) and near-vertical trackpad gestures, while discrete mouse-wheel events (`hasPreciseScrollingDeltas == false`) dolly along camera distance.
3. **Canonical lighting background & sky enclosure (`ViewportGrid.swift`, `ShotsViewport.swift` ← `SceneManager.ts:764-796`, `PrevisLook.swift:36-78`, `ShotFrameRenderer.swift:41`):**
   - Preserves Blockout's canonical background palette per `LightingPreset` (`day` `#394048`, `goldenHour` `#3a2d1e`, `night` `#11151c`, `interiorWarm` `#27231d`, `interiorCool` `#212528`) both as the live viewport's backing surface and as an inward-facing 600 m unlit sky enclosure (`viewport.skyDome`) so rays above the horizon or beyond the 200 m ground plane match `ShotFrameRenderer`.
4. **HUD & empty-stage prompt (`ShotsViewport.swift` ← `Viewport.tsx:19-99, 592-596`):**
   - Preserves lens (`mm`), scene/shot/frame summary, and the empty-stage prompt (`"Click a library item, then click the floor to place it."`) when a scene has no entities.
5. **Deterministic frame evaluation, stage clearing & snapshot verification (`ShotsViewport.swift`, `ViewportSnapshotRenderer.swift`, `ViewportDisplayTests.swift` ← `SceneManager.ts:370-403, 1994-2113, 2371-2504`, `tests/e2e/smoke.spec.ts:114-130`):**
   - Scene state is applied purely from `store.frame` (`PrevisSceneMapper.apply`) with no frame-to-frame accumulation; when `store.frame` becomes `nil` (for example after deleting the last shot or scene), an empty `SceneFrame` is applied so all `previs:*` entity containers are removed from `mapper.root`. Interleaved default/top/default renders are verified byte-identical.

### Intentional Swift/RealityKit deviations in D0 & D1
1. **Pure value `EditorCamera` instead of `THREE.OrbitControls` (`LANE-D-VIEWPORT.md` lines 28-34, 66-69):**
   - RealityKit's built-in camera controls cannot be read back deterministically for headless tests or CPU ray picking, and `OrbitControls`'s frame-rate-dependent damping (`dampingFactor = 0.12`) is non-deterministic across frame rates. `EditorCamera` is a pure `Sendable` value producing `CameraFrame` via `PrevisCore`'s `CameraFrame.make` and rays via `CameraFrame.ray`, with distance clamped to `0.5...200` m.
   - `EditorCamera.defaultView` (`target = (0, 1, 0)`, `distance = 6.5`, `yaw = 0`, `pitch = -0.18`, `35 mm` on `.super35`) and `EditorCamera.topView` (`target = (0, 0, -0.8)`, `distance = 10`, `yaw = 0`, `pitch = -maxPitch`, perspective camera via `CameraFrame.make` rather than `THREE.OrthographicCamera` because `PrevisSceneMapper.cameraEntity` uses `PerspectiveCameraComponent`) frame all four entities of `ShotsSamples.twoPersonWalk` inside the 9:16 portrait canvas (`320×576` and `640×1152`).
2. **Separate RealityKit roots instead of visibility-toggling on a shared scene (`SHOTS-PLAN.md` section 4, `LANE-D-VIEWPORT.md` lines 38-44, 170):**
   - Blockout toggled `this.overlay.visible = false` and `this.tintedMaterials` in `renderFrameAt`. In Shots, `RealityView` mounts `mapper.root`, `overlayRoot`, and `skyDome` as separate roots; clean exports only ever mount `PrevisSceneMapper.root`, and viewport snapshots pass `overlay: overlayRoot.clone(recursive: true)` (since a RealityKit `Entity` can have only one parent).
3. **Batched quad-strip `MeshResource` for the ground grid (`ViewportGrid.swift`):**
   - RealityKit `MeshResource` supports `.triangles` primitives rather than `GL_LINES`. `ViewportGrid` batches the 60 m × 60 m grid into two `ModelEntity` triangle meshes (`viewport.groundGrid.axes` and `viewport.groundGrid.divisions`) lifted `0.002` m above `y = 0` to prevent z-fighting with `PrevisSceneMapper`'s ground plane.
4. **AppKit `ScrollCapturingView` input overlay (`ViewportGestures.swift`, `ShotsViewport.swift`):**
   - `ViewportScrollWheelOverlay.ScrollCapturingView` participates in AppKit hit-testing (`hitTest(_:)` returns `self` within bounds) and routes `scrollWheel(with:)`, `mouseDown(with:)`/`mouseDragged(with:)`/`mouseUp(with:)`, and `magnify(with:)` to `ViewportLiveSession`, ensuring both scroll-wheel / trackpad two-finger gestures and click-drag orbit / `⌥`-drag pan work in live windows and headless AppKit tests.
5. **Post effects and macOS 27 occlusion culling (`ShotsViewport.swift`, `ViewportGrid.swift`):**
   - `RealityView` disables `motionBlur`, `depthOfField`, `cameraGrain` and sets `.standard` dynamic range (`LANE-D-VIEWPORT.md` lines 82, 168), and disables `OcclusionCullingComponent` on macOS 27 so off-origin entities are never culled.
6. **Appearance-adaptive InstantPrint HUD surfaces (`ShotsViewport.swift`, `ShotCameraView.swift`):**
   - Uses `.primary`, `StudioStyle.supportingText`, and `Color.primary.opacity(0.16)` over `InstantPrint.ground` for HUD pills and `ShotCameraView` chrome per `app/DESIGN.md` so both `.aqua` (light) and `.darkAqua` (dark) appearances remain high-contrast while the 3D stage background uses the active `LightingPreset` palette.

### PR #72 Round 1 Review Repairs ([issuecomment-6428253007](https://github.com/RationallyPrime/concept-studio/pull/72#issuecomment-6428253007))
1. **`4382946767` (P1 — `ViewportGestures.swift`, `ShotsViewport.swift`):** Removed `.allowsHitTesting(false)` from `ViewportScrollWheelOverlay` and updated `ScrollCapturingView.hitTest(_:)` to return `self` inside bounds while handling `scrollWheel`, `mouseDown`/`mouseDragged`/`mouseUp`, and `magnify`, so AppKit hit-testing routes both scroll/trackpad and click-drag gestures to the viewport session.
2. **`4382946774` (P2 — `ViewportGestures.swift`):** Removed the `optionPressed || abs(scrollingDeltaX) > 0.01` gate on `hasPreciseScrollingDeltas` so purely vertical (`scrollingDeltaX == 0`) and near-vertical (`abs(scrollingDeltaX) <= 0.01`) trackpad two-finger gestures stay in pan mode instead of switching into dolly.
3. **`4382946781` (P2 — `ShotsViewport.swift`):** `ViewportLiveSession.sync(with:size:)` now applies an empty `SceneFrame(entities: [])` when `store.frame == nil`, removing all mapped `previs:*` entity containers when the last shot or scene is deleted.
4. **`4382946784` (P2 — `ShotsViewport.swift`, `ViewportGrid.swift`):** Replaced the appearance-dependent `InstantPrint.ground` viewport backdrop with `ViewportGrid.backgroundColor(for: activeLighting)` and added `viewport.skyDome` (`ViewportGrid.makeSkyDomeEntity(for:)`) matching `PrevisLook`'s canonical background palette across all five lighting presets.

## Delivered in D1 (`shots/d-viewport`)

- `ShotsViewport` & `ViewportLiveSession`: hosts `RealityView` displaying `store.frame` through `PrevisSceneMapper`, clears mapped stage entities when `store.frame == nil`, applies the active look's canonical background colour and `skyDome`, attaches `overlayRoot` as a separate root so editor chrome never leaks into exported passes, disables post-effects (`motionBlur`, `depthOfField`, `cameraGrain`, standard dynamic range) and macOS 27 `OcclusionCullingComponent`, and renders the empty-stage prompt and HUD.
- `ViewportGrid`: 60 m × 60 m (`-30...30` m) 1 m ground grid matching Blockout's `THREE.GridHelper(60, 60, 0x33343a, 0x27282d)` at `0.6` opacity under `overlayRoot`, plus canonical `LightingPreset` background colors and `viewport.skyDome`.
- `ViewportCameraGestures` & `ViewportScrollWheelOverlay`: hit-testable AppKit capture overlay routing trackpad two-finger pan (`hasPreciseScrollingDeltas`), discrete scroll-wheel dolly, primary click-drag orbit (`2π / viewportHeight`), `⌥`-drag perspective pan (`2 * distance * tan(vFOV / 2) / viewportHeight`), and pinch magnify dolly.
- `ViewportSnapshotRenderer`: renders offscreen viewport snapshots via `ShotFrameRenderer.image(of:look:camera:overlay:size:)` using `editorCamera.cameraFrame(for:)` and `overlayRoot.clone(recursive: true)`.
- `ViewportDisplayTests`:
  - Verifies deterministic orbit, pan and dolly gesture updates on `EditorCamera`.
  - Verifies purely vertical (`scrollingDeltaX == 0`) and near-vertical (`abs(scrollingDeltaX) <= 0.01`) trackpad gestures stay in pan mode while discrete wheel events dolly (`verticalAndNearVerticalTrackpadScrollStayInPanModeWhileMouseWheelDollies`).
  - Verifies AppKit `NSHostingView.hitTest(_:)` returns `ScrollCapturingView` and routes synthesized trackpad scroll, mouse-wheel scroll, primary drag orbit, and `⌥`-drag pan through the mounted viewport (`appKitHitTestingRoutesScrollAndDragEventsThroughViewportOverlay`).
  - Verifies deleting the active shot transitions `store.frame` to `nil` and clears all mapped `previs:*` entity containers from `mapper.root` (`deletingLastShotOrSceneClearsMappedEntitiesFromViewportStage`).
  - Verifies the mounted viewport renders the selected `LightingPreset`'s canonical background across `.day`, `.night`, `.goldenHour`, `.interiorWarm`, and `.interiorCool` in both `.aqua` and `.darkAqua` appearances (`liveViewportAppliesSelectedLookCanonicalBackgroundInLightAndDarkAppearances`).
  - Verifies `ViewportGrid` matches the 60 m × 60 m Blockout reference hierarchy.
  - Regenerates default-view and top-view snapshots of `ShotsSamples.twoPersonWalk(small: true)` and verifies every entity's projected centre pixel is inside the frame, differs from the background colour, and differs from a bare (no-entities) render at that pixel.
  - Verifies byte-identical render determinism across interleaved default/top/default camera renders and verifies the grid overlay renders in viewport snapshots while leaving `overlayRoot.parent == nil` and clean export renders untouched.
  - Regenerates full-size (`640×1152`) snapshots (`d1-sample-default.png`, `d1-sample-top.png`) when `SHOTS_SNAPSHOT_DIR` is set.

## How to verify D1

From the repository root:

```sh
.github/scripts/swift-test-watchdog.sh --package-path app --build-system native \
  --filter 'ViewportEditorCameraTests|ViewportDisplayTests'
```

To regenerate the full-size (`640×1152`) default-view and top-view snapshots (`d1-sample-default.png`, `d1-sample-top.png`):

```sh
SHOTS_SNAPSHOT_DIR=<dir> .github/scripts/swift-test-watchdog.sh --package-path app --build-system native \
  --filter 'ViewportDisplayTests/writesFullSizeDefaultAndTopSnapshotsWhenSnapshotDirectoryIsSet'
```

And the full CI lint and core gates:

```sh
.github/scripts/swift-test-watchdog.sh --package-path app/PrevisCore --build-system native
cd app && mise exec -- swiftlint lint --strict && \
  mise exec -- swiftformat Sources Tests PrevisCore/Sources PrevisCore/Tests --lint
```

### Verification results (macOS Apple silicon, local Xcode / RealityKit, base `c23dea8`)

- **Run and passed:**
  - `ViewportEditorCameraTests|ViewportDisplayTests` (default env): 12 tests in 2 suites — 11 ran and passed (including `verticalAndNearVerticalTrackpadScrollStayInPanModeWhileMouseWheelDollies`, `appKitHitTestingRoutesScrollAndDragEventsThroughViewportOverlay`, `deletingLastShotOrSceneClearsMappedEntitiesFromViewportStage`, `liveViewportAppliesSelectedLookCanonicalBackgroundInLightAndDarkAppearances`, `defaultAndTopSnapshotsDrawEveryEntityAboveBackgroundAndKeepOverlaySeparate`, and `groundGridMatchesBlockoutSixtyMetreReference`), 0 failed, 1 skipped (`writesFullSizeDefaultAndTopSnapshotsWhenSnapshotDirectoryIsSet` when `SHOTS_SNAPSHOT_DIR` is unset).
  - `ViewportEditorCameraTests|ViewportDisplayTests` (with `SHOTS_SNAPSHOT_DIR` set): 12 tests in 2 suites — 12 ran and passed (`1.009s`), 0 failed, 0 skipped, writing `d1-sample-default.png` and `d1-sample-top.png`.
  - Focused Shots & Viewport suites (`--filter 'Shots|Viewport'`): 84 tests in 23 suites — 82 ran and passed (`4.854s`), 0 failed, 2 skipped (`writesTheSampleFrameForReview` and `writesFullSizeDefaultAndTopSnapshotsWhenSnapshotDirectoryIsSet` when snapshot env vars are unset).
  - `PrevisCoreTests`: 148 tests in 20 suites — 144 ran and passed (`1.660s`), 0 failed, 4 skipped (`correctedEvaluatorAgreesWithBlockoutWhereTheCorrectionsDoNotApply`, `everyScenePasses`, `cameraMovesMatchBlockout`, `actionPathsMatchBlockout`, gated on `PREVIS_GOLDENS`/`PREVIS_VECTORS`).
  - `swiftlint lint --strict` (from `app/`): 0 violations, 0 serious across 396 files.
  - `swiftformat --lint` (from `app/`): 0/8 Lane D files require formatting.
- **Not run locally:**
  - Unfiltered full `ConceptStudioTests` suite (existing non-Shots suites trigger the pre-existing local login Keychain prompt).
  - Live window interactive walkthrough and signed sandbox UI verification.

## Blockers and dependencies

- **D1:** Round 1 review findings (`4382946767`, `4382946774`, `4382946781`, `4382946784`) repaired on `shots/d-viewport` and rebased onto `c23dea8`; awaiting current-head CI, independent review closure, and integrator merge.
- **D2, D3, D5:** Unblocked on `main` (A2 `#64`, A3 `#65`, C1 `#66`, C2 `#68`, B3 `#58`, A4 `#67`, C3 `#70`, C4 `#71`, A5 `#73` are all merged on `c23dea8`).
- **D6:** Blocked on merged B6.

## Open questions

- None for D1.
