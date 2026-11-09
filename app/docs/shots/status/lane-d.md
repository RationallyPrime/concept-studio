# Lane D status

Owner: Metis (Gemini) for D0–D5; D6 by the integration owner's delegate (Claude), 2026-11-09. D0–D5 are all on `main`: D2 [#81](https://github.com/RationallyPrime/concept-studio/pull/81), D3 [#82](https://github.com/RationallyPrime/concept-studio/pull/82), D4 [#84](https://github.com/RationallyPrime/concept-studio/pull/84) and both D5 slices ([#85](https://github.com/RationallyPrime/concept-studio/pull/85) keyboard and accessibility, [#83](https://github.com/RationallyPrime/concept-studio/pull/83) look-through rendering) merged on 2026-11-01, last Shots merge `acfd417`. The two overlay syncs share `overlayRoot`, each rebuilding only its own named children; `ShotCameraView` keeps the look-through render session as `session` and the shared live session as `liveSession`. D6 merged on 2026-11-09 ([#91](https://github.com/RationallyPrime/concept-studio/pull/91), `b6252dd`). The handle on an actor with marks follows Blockout since the owner's 2026-11-09 ruling, on `shots/actor-handle-moves-marks` (a `[contract]` PR).
Reference implementation: [Blockout](https://github.com/wassermanproductions/blockout) at `3f2d0564fd575f70fc28e9bfaa7e94b05e3955d9` (`scripts/blockout/fetch.sh`).

## Checkpoints

| Checkpoint | State | Remaining work |
| --- | --- | --- |
| D0: shell and editor camera maths | **Merged** ([#61](https://github.com/RationallyPrime/concept-studio/pull/61), `42871fbdec650df2f8436febb3d94858b71c9769`) | Complete. |
| D1: RealityView display, gestures, grid and snapshots | **Merged** ([#72](https://github.com/RationallyPrime/concept-studio/pull/72), merge commit `139a2e4`) | Complete. |
| D2: overlays and playback | **Merged** ([#81](https://github.com/RationallyPrime/concept-studio/pull/81), merge commit `1d34da3`) | Sign check closed by the owner's ruling of 2026-11-09 (see Open questions). |
| D3: picking and tools | **Merged** ([#82](https://github.com/RationallyPrime/concept-studio/pull/82), merge commit `4916d80`) | Owner's native walkthrough. |
| D4: move and rotate handles | **Merged** ([#84](https://github.com/RationallyPrime/concept-studio/pull/84), merge commit `d903e54`) | Owner's native walkthrough. The handle on an actor with marks: see "Handle on an actor with marks". |
| D5: look-through view, keyboard and VoiceOver | **Merged**: keyboard and accessibility ([#85](https://github.com/RationallyPrime/concept-studio/pull/85), merge commit `968d771`) and look-through rendering ([#83](https://github.com/RationallyPrime/concept-studio/pull/83), merge commit `acfd417`) | Owner's VoiceOver, physical keyboard and focus walkthrough. |
| D6: integration, performance and IT4 | **Merged** ([#91](https://github.com/RationallyPrime/concept-studio/pull/91), merge commit `b6252dd`) | Owner's on-screen M1/M2 and signed-sandbox walkthrough. |

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

### D2 reference concepts and intentional Swift/RealityKit adaptations (`ViewportOverlays.swift`, `ViewportGestures.swift`, `ShotsViewport.swift`)
- **Reference mapping (`builders.ts:6147-6252`, `SceneManager.ts:343-364, 615-760, 2001-2009` at `3f2d0564fd575f70fc28e9bfaa7e94b05e3955d9`):** D2 ports the Blockout viewport overlay concepts for floor marks, motion paths, shot camera representation, selection bounds, and HUD toggles.
- **Numbered floor marks & camera-facing badges ([issuecomment-6457492801](https://github.com/RationallyPrime/concept-studio/pull/81#issuecomment-6457492801)):** Floor `"T"` marks preserve the reference bar/stem dimensions (`0.40×0.02×0.08` at `0, 0.01, -0.14` and `0.08×0.02×0.40` at `0, 0.01, +0.06`) and floating badge height (`y = 0.30`); badges use CoreGraphics/CoreText textures. `ViewportOverlays.orientLabels(in:to:)` orients both `mark.number.*` and `viewport.path.timeLabel:*` planes to `editorCamera.orientation` during `ViewportLiveSession` camera updates (`editorCamera.didSet` and `syncCamera()`, including orbit without playhead/frame changes) and on `overlayClone` inside `ViewportSnapshotRenderer.renderSnapshot` (without mutating the caller's live `overlayRoot`).
- **Action paths and selection decorations:** Paths consume `evaluator.paths()` (`MotionPath.subject` cases `.entity(String)` and `.camera`) without reimplementing core evaluation; RealityKit triangle ribbons (`halfWidth = 0.018`, total width `0.036`) and struts replace Three.js line materials, with selected-lane direction chevrons and `t=X.Xs` time badges at `y = 0.55`.
- **Shot camera representation:** Displayed with light housing/lens (`#f5f5f7`, housing at local origin, lens at `z = -0.28` pitched `+.pi / 2` around X) and `#f5a524` (`defaultActorMarkRGB`) wire pyramid frustum (with `#7dd3fc` `cameraOverlayRGB` used for camera marks, camera path ribbons, and secondary entity selection boxes; camera selection and primary entity selection use `#f5a524`); its materials, lens placement, and wire strut geometry are intentional RealityKit adaptations rather than an exact mesh/material copy.
- **Selection boxes and HUD toggles:** Wireframe selection boxes (`viewport.selectionGroup`) live only in `overlayRoot` and never tint `mapper.root`. AppKit HUD buttons (`ViewportOverlayTogglesRepresentable`) fix `Marks`/`Paths` hit-testing while passive HUD chrome passes clicks through to `ScrollCapturingView`.

## Delivered in D1 (`shots/d-viewport`) & D2 (`shots/d-overlays`)

- **D2 (`shots/d-overlays`, merged as #81):** `ViewportOverlays`, `ViewportOverlayTogglesRepresentable`, `ShotsViewport` playback/selection/overlay sync, `ViewportSnapshotRenderer` clone-only label orientation, `spikeTapeMarksBuildNumberedTGeometryAndRespectShowMarksToggle` in `ViewportDisplayTests`, and `ViewportOverlaysTests` (live session sync without mutating `mapper.root`, hosted AppKit HUD button hit-testing, `twoPersonWalk(small: true)` first/guide/last snapshots, `gait: .sit` side-view snapshot `d2-sign-check-side.png`, raw `"sit-down"` peak keyframe diagnostic snapshot `d2-sign-check-sit-down-peak.png`, and `markNumbersAndPathTimeLabelsFaceCameraAcrossOrbitWithoutMutatingLiveOverlay`).

### D1 (`shots/d-viewport`)

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

### Verification results (macOS Apple silicon, local Xcode / RealityKit, base `139a2e42095fd509241377286b636ff8d3c18cda`)

- **Run and passed:**
  - `ViewportEditorCameraTests|ViewportDisplayTests` (default env): 12 tests in 2 suites — 11 ran and passed (including `verticalAndNearVerticalTrackpadScrollStayInPanModeWhileMouseWheelDollies`, `appKitHitTestingRoutesScrollAndDragEventsThroughViewportOverlay`, `deletingLastShotOrSceneClearsMappedEntitiesFromViewportStage`, `liveViewportAppliesSelectedLookCanonicalBackgroundInLightAndDarkAppearances`, `defaultAndTopSnapshotsDrawEveryEntityAboveBackgroundAndKeepOverlaySeparate`, and `groundGridMatchesBlockoutSixtyMetreReference`), 0 failed, 1 skipped (`writesFullSizeDefaultAndTopSnapshotsWhenSnapshotDirectoryIsSet` when `SHOTS_SNAPSHOT_DIR` is unset).
  - `ViewportEditorCameraTests|ViewportDisplayTests` (with `SHOTS_SNAPSHOT_DIR` set): 12 tests in 2 suites — 12 ran and passed (`1.009s`), 0 failed, 0 skipped, writing `d1-sample-default.png` and `d1-sample-top.png`.
  - Focused Shots & Viewport suites (`--filter 'Shots|Viewport'`): 84 tests in 23 suites — 82 ran and passed (`4.854s`), 0 failed, 2 skipped (`writesTheSampleFrameForReview` and `writesFullSizeDefaultAndTopSnapshotsWhenSnapshotDirectoryIsSet` when snapshot env vars are unset).
  - `PrevisCoreTests`: 148 tests in 20 suites — 144 ran and passed (`1.660s`), 0 failed, 4 skipped (`correctedEvaluatorAgreesWithBlockoutWhereTheCorrectionsDoNotApply`, `everyScenePasses`, `cameraMovesMatchBlockout`, `actionPathsMatchBlockout`, gated on `PREVIS_GOLDENS`/`PREVIS_VECTORS`).
  - `swiftlint lint --strict` (from `app/`): 0 violations, 0 serious across 396 files.
  - `swiftformat --lint` (from `app/`): 0/8 Lane D files require formatting.
- **Not run locally in D1:**
  - Unfiltered full `ConceptStudioTests` suite.
  - Live window interactive walkthrough and signed sandbox UI verification.
- **Run and passed (post-repair final source):**
  - `--filter Viewport` (`SHOTS_SNAPSHOT_DIR` set): 19 tests reported in 3 suites (`ViewportEditorCameraTests`, `ViewportDisplayTests`, `ViewportOverlaysTests`) — 19 executed and passed (`1.819s`), 0 failed, 0 skipped. Includes the label-orbit regression (`markNumbersAndPathTimeLabelsFaceCameraAcrossOrbitWithoutMutatingLiveOverlay`) and the explicit backward-sit diagnostic (`sideViewSignCheckSnapshotReproducesAuthoredSitDownPeakKeyframeDiscrepancy`, which is a reproducer rather than sign-check acceptance).
  - `--filter 'Shots|Viewport'` (`SHOTS_SNAPSHOT_DIR` set): 180 tests reported in 32 suites — 178 executed and passed (`7.837s`), 0 failed, 2 skipped (`everyPresetReadsAsItsName` and `zoomsRollsAndWhipsReadAsBlockoutDescribesThem` when `PREVIS_PRESETS` is unset).
  - Unfiltered `app` (`SHOTS_SNAPSHOT_DIR` set): 951 Swift Testing tests reported in 156 suites — 945 executed and passed (`26.874s`), 0 failed, 6 skipped (`everyPresetReadsAsItsName`, `zoomsRollsAndWhipsReadAsBlockoutDescribesThem`, `renderViewerOverContactSheet`, `renderActualScreens`, `realModelRecognizesTheSameDemoFace`, `nativeModelMatchesPanZoomAndReviewsOneMissingFrame`; XCTest reported 0 tests).
  - `PrevisCore` (`PREVIS_GOLDENS` and `PREVIS_VECTORS` set): 148 tests reported in 20 suites — 148 executed and passed (`1.687s`), 0 failed, 0 skipped.
  - Full-app style (`swiftlint lint --strict` and `swiftformat Sources Tests PrevisCore/Sources PrevisCore/Tests --lint` from `app/`): 0 violations, 0 serious across 413 files; 0/413 files require formatting (4 skipped).
  - Prior head `1141b4d` CI record (`40606900089`): attempt 1 hit the 300s combined compile+test watchdog budget in `ci/swift (app/)` (`122548534088`, `166.57s` compile + `162.843s` test run with 950/950 reported passing and 0 issues; downstream core/style steps skipped); attempt 2 passed all 7 jobs on unchanged `1141b4d` (`app` 950 reported / 942 executed / 8 skipped, `PrevisCore` 148 reported / 144 executed / 4 skipped, style pass).
- **Not run locally:**
  - `CameraLegOracleTests` with `PREVIS_PRESETS` set (`2` tests in `app`) and live interactive window / signed sandbox UI walkthrough.

## Delivered in D3 (`shots/d-picking`)

### Reference files inspected for D3 (`3f2d0564fd575f70fc28e9bfaa7e94b05e3955d9`)
- `src/renderer/viewport/SceneManager.ts:828-958` (`pointerNdc`, `onPointerDown`, placement click, `dropActorMark` / `dropCameraMark` click, entity selection, `groundHit` against `y = 0`).
- `src/renderer/viewport/Viewport.tsx:419-605` (HUD tool state badges, `droppingMarks` toggle button, and `Esc` cancel hints).
- `src/renderer/store.ts:498-586` (`addEntity` duplicate naming `Man`, `Man 2`, `dropActorMark`, `dropCameraMark`).
- `src/engine/schema.ts:92-115` (`createActorMark` defaults `hold: 0, easeIn: 0.25, easeOut: 0.25, gait: "walk"`; `createCameraMark` defaults `hold: 0, easeIn: 0.3, easeOut: 0.3, roll: 0`).

### Preserved Blockout behaviors and intentional Swift/RealityKit deviations in D3
1. **CPU ray picking against `SceneFrame` (`ViewportPicking.swift` ← `LANE-D-VIEWPORT.md` lines 35-37, 107):**
   - Uses `EditorCamera.ray(through:size:)` in top-left pixel coordinates (`CONTRACTS.md` section 4), transforms the ray into each `PosedPart`'s local space via `part.transform.inverse`, tests local `PartShape` bounds (`.box`, `.wedge`, `.sphere`, `.capsule`, `.cylinder`, `.cone`), and returns the nearest forward hit (`t > 0`) rather than Three.js `Raycaster.intersectObjects`.
2. **Ground-plane (`y = 0`) intersection (`ViewportPicking.intersectGround` ← `SceneManager.ts:953-957`):**
   - Intersects `y = 0` from either side whenever the ray is non-parallel (`abs(direction.y) >= 1e-6`) and the intersection is forward (`t = -origin.y / direction.y >= 0`).
3. **Select and shift-click multi-selection (`ViewportPicking.applyEntityClick` ← `LANE-D-VIEWPORT.md` line 108):**
   - Primary click sets `store.selection = .entities([id])` (or `.none` on empty space). Shift-click adds `id` to `.entities` without duplicates (intentional plan deviation from Blockout's `toggleEntitySelected`).
4. **Place tool (`store.tool == .place(assetID:)` ← `SceneManager.ts:905-913`, `store.ts:500-528`, `LANE-D-VIEWPORT.md` lines 109-110):**
   - Ground click adds a `PrevisEntity` at `(groundHit.x, 0, groundHit.z)` with duplicate naming (`Man`, `Man 2`) and selects it; holding `⌥` keeps `.place(assetID:)` active, while an ordinary click or `Esc` returns `store.tool` to `.select`.
5. **Drop-marks tool (`M` / `store.tool == .dropMarks` ← `SceneManager.ts:914-926`, `store.ts:548-571`, `schema.ts:92-115`, `LANE-D-VIEWPORT.md` lines 111-112, 117):**
   - Selected actor/entity drops an `ActorMark` at the playhead time (`FrameGrid.time(ofFrame: store.playhead)`) with `schema.ts:92-104` defaults (`hold: 0, easeIn: 0.25, easeOut: 0.25, gait: .walk`).
   - Selected `.camera` / `.cameraMark` drops a `CameraMark` at the playhead time (`hold: 0, easeIn: 0.3, easeOut: 0.3, roll: 0`) aimed at the shot's subject (`shot.camera.trackIDs` or primary actor at `0.8 * height`), converting to mount-local coordinates when `shot.camera.rig == .carMount` and `shot.camera.mountID != nil`.
6. **Read-only guard (`store.isReadOnly` ← `LANE-D-VIEWPORT.md` lines 56-57):**
   - Disables `.place`, `.dropMarks`, and `M` tool activation while keeping entity click selection and editor-camera orbit/pan/dolly active.
7. **PR #82 Round 1 P2 repair — sub-threshold pointer jitter during click (`ViewportGestures.swift:140-234`, `ViewportPickingTests.swift:389-463`):**
   - Deferred `onDrag?` dispatch in `ScrollCapturingView.mouseDragged(with:)` until pointer movement from `downPoint` (or cumulative delta) reaches `ViewportScrollWheelOverlay.dragThresholdPoints` (`3.0` pt), accumulating sub-threshold deltas in `accumulatedSubThresholdDelta` and flushing them on the first threshold-crossing drag event. This prevents `< 3.0` pt click jitter from orbiting or panning `session.editorCamera` before `mouseUp` commits placement, mark-drop, or selection (`< 1 cm` ground accuracy preserved for `2.0` pt jitter), while real drags (`>= 3.0` pt) still orbit/pan without triggering click actions.

### Verification results for D3 (`shots/d-picking`, base `139a2e4`, PR [#82](https://github.com/RationallyPrime/concept-studio/pull/82))
- `ViewportPickingTests`: 8 tests in 1 suite reported (`0.367s`; 8 executed, 0 skipped, 0 failed), including `subThresholdMouseJitterDoesNotOrbitCameraBeforeClickPlacementWhileTrueDragOrbitsWithoutPlacing`.
- Focused Shots & Viewport suites (`--filter 'Shots|Viewport'`): 181 tests in 32 suites reported (`6.877s`; 177 executed, 4 skipped when preset/snapshot env vars are unset, 0 failed).
- Full unfiltered `app` test suite: 952 tests in 156 suites reported (`26.402s`; 944 executed, 8 skipped, 0 failed).
- `PrevisCoreTests` (no fixture env): 148 tests in 20 suites reported (`1.568s`; 144 executed, 4 skipped, 0 failed).
- `PrevisCoreTests` (with `PREVIS_GOLDENS` and `PREVIS_VECTORS` set): 148 tests in 20 suites reported (`1.584s`; 148 executed, 0 skipped, 0 failed).
- `swiftlint lint --strict` & `swiftformat --lint`: 0 violations across 413 files (`0/413` require formatting).

## Delivered in D4 (`shots/d-handles`, stacked on `shots/d-picking` `fdb33e2`)

### Reference files inspected for D4 (`3f2d0564fd575f70fc28e9bfaa7e94b05e3955d9`)
- `src/renderer/viewport/SceneManager.ts`:
  - `lines 257-266`: `TransformControls` setup, `dragging-changed` listener disabling `OrbitControls` while dragging (`this.controls.enabled = !dragging`), `beginGizmoDrag()` on drag start, and `commitGizmo()` on release.
  - `lines 855-860`: pointer precedence (`if (this.transform.dragging || this.transform.axis) return`) so gizmo interaction takes priority over tool clicks and selection.
  - `lines 960-966`: keyboard mode switching (`G` → translate/move, `R` → rotate) suppressed when focus is inside an input/textarea.
  - `lines 1025-1063`: `setGizmoMode`, `applyGizmoAxisLimits` (upright entity Y-only rotation), and `syncSelection` attaching gizmo in non-deliver/non-lookThrough modes.
  - `lines 1130-1277`: `beginGizmoDrag` and `commitGizmo` for entities and camera marks (Euler `'YXZ'` `pan = e.y`, `tilt = e.x`).
- `src/renderer/viewport/Viewport.tsx:303-327`: `GizmoModeRow` (`Move (G)`, `Rotate (R)`).

### Preserved Blockout behaviors and plan-required Swift/RealityKit adaptations in D4
1. **Constant-screen-size move & rotate gizmo under `overlayRoot` (`ViewportHandles.swift`, `ViewportHandles+Geometry.swift` ← `LANE-D-VIEWPORT.md` lines 48-55, 126-127, 164-165):**
   - Replaces Three.js `TransformControls` (`SceneManager.ts:257-266`) with deterministic ray-plane (`intersectHorizontalPlane`) and ray-axis (`closestAxisScalar`) math plus a RealityKit overlay entity (`viewport.handles`) mounted strictly under `session.overlayRoot` (never `mapper.root`, so clean exports cannot see handle geometry).
   - Computes world radius `targetScreenRadiusPixels * (2 * depth * tan(vFOV / 2)) / height` with `ViewportHandleGizmoGeometry.targetScreenRadiusPixels = 56.0`, verified in `constantScreenSizeGizmoMaintainsPixelRadiusAcrossDistinctCameraDistancesAndStaysInOverlayOnly` across camera distances `3.0 m`, `6.5 m`, and `18.0 m` (projected radius within `0.05` px of `56.0` px; world radius ratio `18.0 / 3.0 == 6.0`).
2. **Entity, actor-mark, and camera-mark move & rotate commands (`ViewportHandles.swift` ← `SceneManager.ts:1025-1063, 1130-1277`, `LANE-D-VIEWPORT.md` lines 121-125, `CONTRACTS.md` section 5):**
   - Preserves Blockout's entity (`setGizmoMode`, `applyGizmoAxisLimits`, `beginGizmoDrag`, `commitGizmo`) and camera-mark (`pan`/`tilt`) manipulation semantics while adapting them to Shots' typed `ShotsCommand` contract (`LANE-D-VIEWPORT.md` lines 48-55, 121-125):
     - Selected `.entities([id])` previews/commits `.setPlacement(id, placement)` (horizontal XZ plane drag by default, `⇧`-constrained dominant horizontal axis or explicit `.axisX`/`.axisY`/`.axisZ` single-axis drag, and Y-axis heading rotation ring).
     - Plan-required actor-mark adaptation: selected `.actorMark(entityID:markID:)` previews/commits `.updateActorMark(shotID, entityID, updated)` preserving `time`, `hold`, `gait`, `action`, `motion`, `speed`, `easeIn`, and `easeOut`; when `arriveHeading == nil`, rotation initializes from the evaluated actor heading at the mark time (falling back to entity placement heading).
     - Selected `.cameraMark(markID)` or `.camera` (active mark at playhead) previews/commits `.updateCameraMark(shotID, updated)` preserving `focalLength`, `framing`, `hold`, `easeIn`, `easeOut`, and `roll`, supporting position move, horizontal pan, vertical tilt (clamped to `±maxTiltRadians` where `maxTiltRadians = .pi / 2.0 - 0.01`), combined pan+tilt, and `.carMount` world-to-mount-local coordinate conversion (`ViewportHandleTarget.MountPose`).
3. **Typed preview/commit transaction & `Esc` cancellation (`ViewportHandles.swift`, `ViewportGestures.swift` ← `SceneManager.ts:257-266, 855-860`, `LANE-D-VIEWPORT.md` lines 49-53, 136-138):**
   - Plan-required `ShotsStore` adaptation: pointer-down + drag updates `store.preview = command` on every drag move while suppressing camera orbit/pan (`ScrollCapturingView`) without mutating `store.document` or undo history; pointer-up clears `store.preview = nil` and commits once via `store.run(command)` (one undo step; no-op release produces zero undo entries; validation error reports via `store.onError` and clears `store.preview`). `Esc` during an active drag clears `store.preview = nil` and abandons the drag with no document edit.
4. **Focused keyboard shortcuts, read-only guard, and testable announcement callback/labels (`ViewportPicking.swift`, `ViewportGestures.swift`, `ShotsViewport.swift` ← `SceneManager.ts:960-966`, `Viewport.tsx:303-327`, `LANE-D-VIEWPORT.md` lines 56-57, 139, 146-148):**
   - `G` activates move handles, `R` activates rotate ring, `V` returns `store.tool` to `.select`, `M` toggles `.dropMarks`, and `Esc` cancels any active handle drag and returns `store.tool` to `.select`. Shortcuts are ignored when `window.firstResponder` is an `NSText` editor or another non-viewport control, and `G`/`R`/`M` are ignored when `store.isReadOnly == true`.
   - `ShotsViewport` exposes handle mode in its accessibility label (`accessibilityDescription(for:)`) and `ViewportLiveSession.postAnnouncement(_:)` updates `session.lastAnnouncement` and invokes the optional injectable `session.announcementPoster?` callback for deterministic headless test verification; no default `NSAccessibility.post` implementation is installed in D4, and actual native `NSAccessibility` / live VoiceOver delivery remains unimplemented/unrun under the full D5 gate.
5. **PR #84 Round 1 P2 repair & D4 lifecycle/geometry/no-op fixes ([issuecomment-6461781450](https://github.com/RationallyPrime/concept-studio/pull/84#issuecomment-6461781450)):**
   - **P2 — Stale handle baseline invalidation on Undo or committed target edit (`ViewportHandles.swift:127-140, 331, 415-429`, `ViewportHandles+Geometry.swift:304-331`, `ViewportHandlesHostedTests.swift:174-233`):** `ViewportHandleDragSession` records `baselineDocument: ShotsDocument` at `beginDrag`, and `ViewportHandles.isDragStillValid(_:in:)` verifies `store.document == drag.baselineDocument`, `drag.target.matchesCommittedTarget(in: store.document, sceneID: drag.sceneID, shotID: drag.shotID)`, and `drag.latestCommand == nil || store.preview != nil`. Invoking `store.undo()` or committing another edit during an active handle preview invalidates and cancels the drag on `session.sync` / `updateDrag` / `endDrag`, preserving the restored document and keeping Redo available.
   - **D4 P3 advisories resolved (`ViewportHandles.swift:555-580`, `ViewportHandles+Geometry.swift:235`, `ViewportGestures.swift:114-188`, `ShotsViewport.swift:274-276, 307-309`, `ViewportHandlesHostedTests.swift:235-320`):**
     - Stationary zero-delta rotation release (`abs(deltaHeading) <= 1e-9`) returns the unchanged `initialPlacement` / `initialMark` so releasing at the initial rotate-ring point on an actor mark with `arriveHeading == nil` does not author `arriveHeading` metadata or create an Undo entry.
     - `ViewportHandles.syncOverlay` uses `Float(max(geometry.worldRadius, 1e-4))` rather than clamping at `0.05` m, keeping the close-zoom (`0.5` m) overlay entity scale matched to `geometry.worldRadius` (`56.0` px projected radius).
     - `ScrollCapturingView` (`dismantleNSView`, `viewDidMoveToWindow`, `viewDidMoveToSuperview`) and `ShotsViewport.onDisappear` cancel any active handle drag on teardown so `store.preview` is cleared to `nil`.

### Verification results for D4 (`shots/d-handles`, stacked on `shots/d-picking` `fdb33e2`, PR [#84](https://github.com/RationallyPrime/concept-studio/pull/84))
- `ViewportHandlesTests|ViewportHandlesHostedTests`: 10 tests in 2 suites reported (`0.415s`; 10 executed, 0 skipped, 0 failed).
- All `Viewport` suites (`--filter 'Viewport'`): 30 tests in 5 suites reported (`1.227s`; 29 executed, 1 skipped when `SHOTS_SNAPSHOT_DIR` is unset, 0 failed).
- Focused Shots & Viewport suites (`--filter 'Shots|Viewport'`): 191 tests in 34 suites reported (`7.157s`; 187 executed, 4 skipped when preset/snapshot env vars are unset, 0 failed).
- Full unfiltered `app` test suite: 962 tests in 158 suites reported (`26.271s`; 954 executed, 8 skipped, 0 failed).
- `PrevisCoreTests` (with `PREVIS_GOLDENS` and `PREVIS_VECTORS` set): 148 tests in 20 suites reported (`1.617s`; 148 executed, 0 skipped, 0 failed; no-env run: 148 reported, 144 executed, 4 skipped).
- `swiftlint lint --strict` & `swiftformat --lint`: 0 violations across 417 files (`0/417` require formatting).
- Not run / remaining: native desktop input, interactive window walkthrough, and actual native `NSAccessibility` / live VoiceOver announcement delivery (tracked under full D5 gate).

## Delivered in D5 Keyboard & Accessibility Continuation (`shots/d-keyboard-a11y`, stacked on `shots/d-handles` `b540cba`)

### Reference files inspected for D5 Keyboard & Accessibility (`3f2d0564fd575f70fc28e9bfaa7e94b05e3955d9`)
- `src/renderer/viewport/SceneManager.ts:960-994` (`onKeyDown` handling `G` translate, `R` rotate, and `Backspace`/`Delete` `deleteSelectedMarks` or `deleteSelection`).
- `src/renderer/viewport/Viewport.tsx:303-327` (`GizmoModeRow` `Move (G)`, `Rotate (R)`).
- `src/renderer/App.tsx:150-206` (global key handler for `M` `setDroppingMarks`, `C` `setLookThrough(!s.lookThrough)`, `Escape`, and `1-9` jumping to `[...shot.camera.marks].sort((a, b) => a.time - b.time)[idx].time`).

### Preserved Blockout behaviors, narrow Lane C integration, and plan-required adaptations (`CONTRACTS.md` section 7, `LANE-D-VIEWPORT.md` D5)
1. **Viewport-focused keyboard commands (`ViewportKeyboard.swift`, `ViewportPicking.swift`):**
   - Preserves Blockout `G` (`.move`), `R` (`.rotate`), `M` (toggle `.dropMarks`), `Esc` (cancel active handle drag and select `.select`), `Delete`/Forward Delete (`.deleteEntities` for `.entities(ids)` and `.deleteMarks` for `.actorMark`/`.cameraMark`; safe no-op for `.camera`/`.none`), `C` (toggle look-through mode), and `1-9` (jump `store.playhead` to `FrameGrid.frame(atTime: sortedMarks[idx].time)` sorted by `mark.time`).
   - Plan-required adaptations (`CONTRACTS.md` section 7 lines 767-777, `LANE-D-VIEWPORT.md` lines 138-146):
     - `V` selects `.select` and cancels any active handle drag.
     - `←`/`↑`/`→`/`↓` nudges `.entities(ids)`, `.actorMark`, and `.cameraMark`/`.camera` (including `.carMount` world-to-mount-local conversion) by `5 cm` (`0.05` m; `⇧` `10×` = `50 cm` / `0.50` m) in world XZ (`-X`, `-Z`, `+X`, `+Z`).
     - `F` frames the selection's evaluated `EntityFrame.bounds` (or mark/camera world position with `0.75` m minimum radius and `1.35×` FOV padding) in `session.editorCamera` without mutating `store.document` or `shot.camera`; returns `false` when `session == nil` or `selection == .none`.
2. **Narrow Lane C owner-approved integration (`ShotsStore.swift`, `ShotsWorkspaceView.swift`):**
   - `ShotsStore` adds `perform(_ commands: [ShotsCommand]) throws` and `run(_ commands: [ShotsCommand])` so multi-entity arrow nudges execute atomically as one Undo/Redo step with a single scene-revision bump and roll back completely if any command fails, while preserving exact ordinary single-command `perform(cmd, coalescing: false)` → `perform(cmd, coalescing: true)` coalescing semantics.
   - `ShotsWorkspaceContent` retains a shared `ViewportLiveSession` across `ShotsViewport` and `ShotCameraView` and wires `C` to its single `showsShotCamera` state with focus preservation across toggles so `F`, `R`/`G`, `1-9`, and `C` operate on the shared editor session in both views.
3. **Focus, modifier, read-only, active-preview, and headless accessibility safeguards:**
   - Suppresses viewport keys when an `NSText` editor or non-viewport responder owns `window.firstResponder`, ignores `.command`/`.control`/`.option` modifiers, cancels active handle previews before executing keys, and in `store.isReadOnly` mode allows `V`, `Esc`, `F`, `C`, and `1-9` while blocking `←`/`↑`/`→`/`↓`, `Delete`, `G`, `R`, and `M`.
   - `ViewportAccessibility.postAnnouncementIfWindowVisible(_:in:)` wires `NSAccessibility.post(element: window, notification: .announcementRequested, userInfo: ...)` behind `announcementPoster == nil && window.isVisible && NSApp?.isActive == true`, remaining a complete no-op in headless/unshown test windows.
4. **PR [#85](https://github.com/RationallyPrime/concept-studio/pull/85) Round 1 P2 repairs (`ViewportKeyboard.swift`, `ShotCameraView.swift`, `ShotsViewport.swift`, `ViewportKeyboardTests.swift`):**
   - **P2-1 — Effective world-space nudge for blocked entities (`ViewportKeyboard.swift:246-310`):** `ViewportKeyboard.entityNudgeCommands(for:by:in:currentShot:)` now builds an atomic `[ShotsCommand]` batch for selected `.entities(ids)` that updates each entity's base `.setPlacement(id, placement)` AND translates all `ActorMark.position` and `ActorMark.via` waypoints in the active `BlockingTake` track via `.updateActorMark(shotID, id, mark)` (preserving `time`, `hold`, `easeIn`, `easeOut`, `gait`, `arriveHeading`, `joints`, and `boardID`). Blocked actors (`Man` at frame 11 in `ShotsSamples.twoPersonWalk`) and static props (`Chair`) now both shift by the exact requested `5 cm` (`⇧` `50 cm`) in evaluated `store.frame` world space and undo/redo in a single atomic step.
   - **P2-2 — Shared selection announcements in look-through mode (`ShotCameraView.swift:23-85`, `ShotsViewport.swift:58-67`, `ViewportKeyboard.swift:494-530`):** Extracted `ViewportLiveSession.syncSelectionAnnouncement(with:)` and wired `ShotCameraView` and `ViewportKeyCaptureOverlay` (`selection`, `onSync`, `onAppear`, `onChange(of: currentSelection)`) to the shared `ViewportLiveSession`, while including the current selection summary in `ShotCameraView`'s accessibility label. Selection changes made while `ShotCameraView` (look-through mode) is active now dispatch `"Selected ..."` once through `session.postAnnouncement(_:)` without duplicating announcements across `C` mode transitions.

### Verification results for D5 Keyboard & Accessibility (`shots/d-keyboard-a11y`, stacked on `shots/d-handles` `b540cba`, PR [#85](https://github.com/RationallyPrime/concept-studio/pull/85))
- `ViewportKeyboardTests`: 9 tests in 1 suite reported (`1.720s`; 9 executed, 0 skipped, 0 failed), including `nudgeMovesEvaluatedBlockedActorAndStaticPropAtMidShotFrameAndUndoesAtomically` and `lookThroughSelectionChangesDispatchSharedAnnouncementCallbackWithoutDuplicates`.
- All `Viewport` suites (`--filter 'Viewport'`): 39 tests in 6 suites reported (`2.596s`; 38 executed, 1 skipped when `SHOTS_SNAPSHOT_DIR` is unset, 0 failed).
- Focused Shots & Viewport suites (`--filter 'Shots|Viewport'`): 200 tests in 35 suites reported (`10.246s`; 196 executed, 4 skipped when preset/snapshot env vars are unset, 0 failed).
- Full unfiltered `app` test suite: 971 tests in 159 suites reported (`33.656s`; 963 executed, 8 skipped, 0 failed).
- `PrevisCoreTests` (with `PREVIS_GOLDENS` and `PREVIS_VECTORS` set): 148 tests in 20 suites reported (`11.462s`; 148 executed, 0 skipped, 0 failed; no-env run: 148 reported, 144 executed, 4 skipped, `1.686s`).
- `swiftlint lint --strict` & `swiftformat --lint`: 0 violations across 419 files (`0/419` require formatting).
- Not run / remaining: physical native VoiceOver speech/navigation and live focus walkthrough (the owner's). The composition of [#83](https://github.com/RationallyPrime/concept-studio/pull/83) with [#85](https://github.com/RationallyPrime/concept-studio/pull/85) is done and merged (`acfd417`).

## Delivered in D5 Look-Through Rendering Slice (`shots/d-look-through`)

### Reference files inspected for D5 (`3f2d0564fd575f70fc28e9bfaa7e94b05e3955d9`)
- `src/renderer/viewport/SceneManager.ts:2099-2112, 2218-2296, 2371-2455` (`applyTime(t)` shot-camera projection, letterboxed look-through viewport `vw`/`vh`/`vx`/`vy`, PiP live shot preview hiding editor chrome, and `renderFrameAt` deterministic export rendering).
- `src/renderer/viewport/Viewport.tsx:331-375, 398-417, 470-531, 540-588` (`viewRect` letterbox state, `"🎥 Look through"` control, PiP preview chrome, and letterbox frame overlay).
- `tests/e2e/smoke.spec.ts:114-130` (deterministic frame rendering across interleaved renders).

### Preserved behaviors and intentional Swift/RealityKit adaptations in D5 (`ShotCameraView.swift`, `ViewportLookThroughTests.swift`)
1. **Shared export renderer and canonical look (`ShotCameraView`, `ShotCameraPreviewSession` ← `LANE-D-VIEWPORT.md` lines 47-49, 136-144, 166; `SHOTS-PLAN.md` section 4):**
   - RealityKit's `RealityView` supports a single active camera, and Blockout's live WebGL viewport applied tone mapping/exposure that differed from its exporter. `ShotCameraView` renders `store.frame` offscreen via `ShotFrameRenderer.image(of: frame, look: PrevisLook(scene: scene))` with no editor overlay (`overlay == nil`), matching `ShotExporter`'s `.clean` pass pixel-for-pixel by construction.
2. **Latest-wins request coalescing & displayed-image metadata identity (`ShotCameraPreviewSession`, `ShotCameraView.activeRenderedRequest`):**
   - Keeps at most one render in flight and at most one newest pending `ShotCameraRenderRequest` (`sceneID`, `sceneRevision`, `shotID`, `shotName`, `frame`, `look`), collapsing intermediate playhead/document updates while preventing stale in-flight completions from overwriting a switched or cleared shot context.
   - `ShotCameraView.activeRenderedRequest` shares the exact displayed-image predicate between `canvasSurface(size:)` and `captionText` / `accessibilityLabelText`: whenever `session.renderedImage` is shown on screen (including while a newer playhead/document render is still in flight), both the HUD pill and the accessibility label identify `rendered.shotName`, `rendered.frame.canvas`, and `rendered.frame.index` of the displayed pixels rather than the unrendered `store.playhead` target (PR [#83](https://github.com/RationallyPrime/concept-studio/pull/83) Round 1 P2 repair). When no rendered image is active, `captionText` falls back to `store.currentShot` / `store.playhead`.
   - Render failures set `session.errorMessage`, clear `renderedImage` (never silently succeeding), report through `store.onError`, and recover on subsequent requests.
3. **Canvas letterboxing (`ShotCameraView.letterboxRect(in:canvas:)` ← `SceneManager.ts:2220-2240`):**
   - Fits the active `ShotCanvas` aspect ratio centered inside the available view bounds while preserving `InstantPrint.ground` contrast and accessibility labeling in both `.aqua` and `.darkAqua` appearances.

### Verification results for D5 rendering slice (`shots/d-look-through`, base `139a2e4`, PR [#83](https://github.com/RationallyPrime/concept-studio/pull/83))
- `ViewportLookThroughTests`: 7 tests in 1 suite reported (`0.622s`; 7 executed, 0 skipped, 0 failed), including `lookThroughFrameElevenMatchesExportedMiddleGuideCleanPNGAsDecodedRGB` (`twoPersonWalk(small: true)`, 22 frames, `320×576`, frame 11 look-through image equals exported `guides/middle-f0011-clean.png` as decoded sRGB bytes) and `retainedImageCaptionAndAccessibilityIdentifyDisplayedFrameWhileNewerRenderIsPending` (Round 1 P2 regression verifying retained Frame 0 pixels report Frame 0 in both `captionText` and `accessibilityLabelText` while Frame 11 is in flight, then advance to Frame 11 once the render completes).
- Focused Shots & Viewport suites (`--filter 'Shots|Viewport'`): 180 tests in 32 suites reported (`7.113s`; 176 executed, 4 skipped when preset/snapshot env vars are unset, 0 failed).
- Full unfiltered `app` test suite: 951 tests in 156 suites reported (`26.997s`; 943 executed, 8 skipped, 0 failed).
- `PrevisCoreTests` (no fixture env): 148 tests in 20 suites reported (`1.370s`; 144 executed, 4 skipped, 0 failed).
- `PrevisCoreTests` (with `PREVIS_GOLDENS` and `PREVIS_VECTORS` set): 148 tests in 20 suites reported (`1.678s`; 148 executed, 0 skipped, 0 failed).
- `swiftlint lint --strict` & `swiftformat --lint`: 0 violations across 412 files (`0/412` require formatting).
- **Not run / separately pending:** the owner's physical desktop, VoiceOver and signed-sandbox walkthroughs. The keyboard and announcement work landed in [#85](https://github.com/RationallyPrime/concept-studio/pull/85); the frame-time measurements are in D6 below.

## Delivered in D6 (`shots/d-integration`)

### Reference files inspected for D6 (`3f2d0564fd575f70fc28e9bfaa7e94b05e3955d9`)
- `src/renderer/viewport/SceneManager.ts:276-299` (store subscriptions: `syncFromStore`, and with it `rebuildOverlay`, only when the document, scene or shot changes; `syncSelection` only when the selection changes; `applyOverlayToggles` only on a toggle).
- `src/renderer/viewport/SceneManager.ts:2119-2137` (the per-frame loop: advance the playhead, `applyTime(t)`, `controls.update()`; nothing rebuilt per frame).
- `src/renderer/viewport/SceneManager.ts:1130-1149, 1171-1270` (`beginGizmoDrag`, `commitGizmo`: the gizmo sits on the drawn body and an entity drag carries the entity's marks; see Open questions).

### What D6 changed
1. **Overlay rebuilds follow Blockout's triggers (`ViewportOverlays.sync`, `ViewportOverlayInputs`, `ViewportLiveSession.sync`).** Every `sync` used to rebuild every spike-tape mark, path ribbon, chevron, time badge and selection box, generating new meshes each time. `sync` runs from `RealityView`'s update closure and from the input view's `updateNSView`, so a playback step or an orbit tick paid for it two or three times. The live session now keeps what the overlay was last drawn from:
   - marks are rebuilt only when the scene or the shot changes;
   - paths when the scene, the shot or the selection changes;
   - selection boxes when the selection or the selected thing's evaluated pose changes.

   The camera body and the label orientation are still re-posed every sync. Called without `previous`, `ViewportOverlays.sync` still rebuilds everything, as before.
2. **Shared meshes.** All marks share one mesh per piece (bar, stem, badge plane), and every strut of a selection box or frustum is one unit box scaled to its length and thickness. Each mark and strut used to generate its own mesh.
3. **Measured before and after** (below). Before the change, the release-build timing test did not finish its 244 frames in minutes; sampling showed `rebuildMarks` → `makeMarkEntity` mesh generation on nearly every stack.

No PrevisCore motion data, rig, Lane C shell file or contract changed.

### IT4 and integration tests (`ViewportIntegrationTests.swift`, `ViewportHostedWorkspace.swift`)
- `scriptedViewportInputProducesTheExpectedDocumentAndLookThroughMatchesExport` (IT4) hosts `ShotsWorkspaceView` with Lane C's split layout in a window and drives the viewport with real `NSEvent`s through its AppKit input view on `twoPersonWalk(small: true)`:
  1. The viewport fills its pane, and picking uses that same size.
  2. With the library's place tool armed, a click places "Woman 2" within 3 cm of the aimed ground point; she is selected and the tool returns to select.
  3. M, then clicks drop actor marks at frame 0 and at frame 15; Esc returns to select.
  4. With the second mark selected, as the mark list does, its move handle drags through three points. While it drags, `store.preview` is set, the document is unchanged and the editor camera doesn't orbit. Release commits once.
  5. Undo restores the pre-drag document and redo the post-drag one.
  6. The final document equals one built independently by `perform` from the scripted pixels: `addEntity`, two `addActorMark`, `updateActorMark`.
  7. C swaps the pane to `ShotCameraView`, and its key view takes focus. The look-through image for frame 11 of the edited shot equals the exported `guides/middle-f0011-clean.png` as decoded RGB. That image comes from a `ShotCameraPreviewSession` given the same request the mounted view builds (`ShotCameraRenderRequest.make(from:)`); the mounted view's own image is private `@State` and isn't read.
  8. C returns to the focused scene view, where Space (Lane C's key) still starts playback.

  Only Lane C's own controls are stood in for by setting the store: the library asset, the playhead and the mark selection.

  How events are delivered:
  - Each press first checks that AppKit's hit-testing of the whole layout lands on the viewport's input view and not on HUD chrome.
  - Mouse events are then handed to that view directly: an unshown window in a test process doesn't route mouse events from `sendEvent`.
  - Keys go through `NSWindow.sendEvent`, so they follow the real responder chain.
- `orbitAndPlaybackReuseTheOverlayWhileAnEditRebuildsIt` checks the new triggers:
  - an orbit and a playback step keep the same mark and path entities;
  - the selected actor's box is rebuilt around the actor's evaluated bounds at the new frame;
  - mark badges face the camera, both kept and rebuilt ones, and hiding marks still applies;
  - an `addActorMark` rebuilds the overlay, and switching shots rebuilds the camera marks for the new shot.

### Frame times (CONTRACTS section 10; `ViewportTimingTests.swift`)
Run from `app/`: `SHOTS_TIMING=1 swift test -c release --filter ViewportTiming`. CI never sets `SHOTS_TIMING`.

**What is measured, exactly.** `swift test` is not a running, active application, so RealityKit never draws a `RealityView` frame there. A probe subscribed to the hosted view's `SceneEvents.Update` and received no events in 3 s idle or during orbit. An on-screen frame rate can't be read headlessly, so each frame is measured as two halves:
- **update:** the main-actor work one input step causes in the hosted workspace. For orbit that is a real `mouseDragged` event through the viewport's input view, the SwiftUI pass it triggers (body, `updateNSView`, `RealityView`'s update closure, which does run headlessly), and one more full `ViewportLiveSession.sync`. For playback it is the playhead step, the SwiftUI pass and one more sync.
- **draw:** a RealityKit render of the same stage with the editor overlay, from the editor camera, at the viewport's size in Retina pixels (twice its points). It goes through `ShotFrameRenderer`, awaited, including the read-back to a `CGImage` that the live view doesn't do.

The frame figure is update + draw, a conservative stand-in for the on-screen frame. Look-through playback is measured as one playhead step plus `ShotCameraPreviewSession`'s render of the 640 × 1152 canvas.

**Scene.** The full two-person walk (124 frames, 640 × 1152) grown to 20 entities: ten people walking tracks of their own and ten props. During orbit an off-centre prop is selected, so its selection box and handles are live. During playback the walking Man is selected. The window is 1280 × 860 pt, which gives the viewport 788 × 451 pt (drawn at 1576 × 902 px).

**Machine.** Apple M4, 10 cores, macOS 27.0.1, local Swift 6.4, release build. Two 1× external displays. No other build or test was running during the recorded runs; macOS storage-management services were using about two cores throughout. (A first run overlapped another worktree's debug `swift test`; its numbers are not recorded.)

| Path, 20 entities | update median / p95 | draw median / p95 | frame median / p95 (max) | Budget |
| --- | --- | --- | --- | --- |
| Orbit, 120 drag steps | 1.05 / 1.14 ms | 9.68 / 11.15 ms | 10.73 / 12.33 ms (13.26) | 16.7 ms (60 fps) |
| Playback in the scene view, 124 frames | 5.98 / 6.48 ms | 10.91 / 14.42 ms | 17.05 / 20.55 ms (22.78) | 41.7 ms (24 fps) |
| Playback in the shot camera view, 124 frames | | | 10.54 / 11.95 ms (13.71) | 41.7 ms (24 fps) |

A second run on the same build gave:
- orbit frame 10.65 / 12.54 ms (max 15.92);
- scene-view playback 16.91 / 20.73 ms;
- look-through playback 10.41 / 12.71 ms.

The test asserts all three p95s against the budgets. Orbit's p95 leaves about 4 ms of headroom. Playback runs with a walking actor selected, so its selection box is rebuilt every frame, the costliest case left after the fix.

An earlier variant, with a static prop selected during playback, measured 15.5 / 16.5 ms. Drawn at 1× (788 × 451 px), it measured orbit 9.5 / 11.5 ms.

**Before the fix.** The test's earlier variant, with the prop selected throughout, was run with the two viewport source files put back to `origin/main` (`acfd417`), on the same idle machine. It did not meet the budget:
- orbit frame median 804 ms, p95 2,166 ms;
- scene-view playback frame median 3,738 ms, p95 9,744 ms;
- look-through playback median 4,013 ms.

The run took 19.4 minutes. Its draw half was 18–32 ms median; nearly all the time was the overlay rebuild in the update half. The look-through figure includes the hosted scene view's own SwiftUI pass, because the test keeps that view mounted. The real app unmounts it in look-through mode, so this inflates both before and after.

### Verification results for D6 (`shots/d-integration`, rebased on `9ff8741`)
- `ViewportIntegrationTests` (IT4 and the rebuild-trigger test): 2 tests in 1 suite, both passed.
- Unfiltered `app` (`swift test`, debug): 996 Swift Testing tests in 166 suites reported, 0 failed, 11 skipped by their gates:
  - `SHOTS_TIMING`: this lane's `ViewportTiming` and Lane B's two timing tests;
  - snapshot directories, `PREVIS_PRESETS`, real-model and screen-render gates.

  XCTest reported 0 tests.
- `PrevisCore` (`swift test --package-path PrevisCore`, no fixture env): 159 tests in 23 suites reported, 0 failed, 5 skipped by the `PREVIS_GOLDENS`, `PREVIS_VECTORS` and `SHOTS_TIMING` gates.
- `swiftlint lint --strict --quiet` and `swiftformat Sources Tests PrevisCore/Sources PrevisCore/Tests --lint`, from `app/` through `mise exec --`: 0 violations; 0/433 files need formatting.
- `SHOTS_TIMING=1 swift test -c release --filter ViewportTiming`: passed twice with the numbers above, on `d8806a6` (this branch before its rebase onto `9ff8741`). The rebase brought only #89's PrevisCore motion-data correction; no viewport code changed.
- Not run here: on-screen M1/M2 frame rate, VoiceOver, physical keyboard and trackpad, signed sandbox. These are the owner's walkthroughs.

## Handle on an actor with marks (`shots/actor-handle-moves-marks`, `[contract]`)

The owner ruled on 2026-11-09 to follow Blockout for the gap D6 found (Open questions). Before this change, the handle of an actor with marks sat at its placement, which the evaluator uses only before the first mark, and a drag edited only that placement.

### What Blockout does (`3f2d0564fd575f70fc28e9bfaa7e94b05e3955d9`)
- **Where the handle sits.** `syncSelection` attaches `TransformControls` to the entity's `visual.root` (`src/renderer/viewport/SceneManager.ts:1045-1063`). `applyTime` poses that root from the evaluator at the playhead (`:1994-2016`), so the gizmo sits on the drawn body, at its evaluated heading. During a drag `applyTime` leaves the dragged root alone (`:2003-2007`).
- **During a drag.** `beginGizmoDrag` snapshots the body's position and `rotation.y` (`:1131-1149`). Only the body (and group members, `:2053-2071`) moves on screen; the document, and so the marks and paths, change on release.
- **On release.** `commitGizmo` (`:1171-1277`) makes one `mutate('move entity')`, so one undo step (`src/renderer/store.ts:417-445`; Blockout merges two same-label mutates less than 800 ms apart, `COALESCE_MS`, `:230`). For each selected entity it:
  - sets `transform.position` to the dragged body position (`y` clamped at 0), `rotationY` to its rotation and keeps the scale;
  - applies the same rigid motion to every mark of the entity's track in **every** take: translate by the drag, and rotate about the body's start position by the change in `rotationY` (`groupTransformed`, `:1152-1169`). Only `mark.position` changes: `via` waypoints and `arriveHeading` are left as they were.
- **Rotate** is about world Y only for entities (`setGizmoMode`, `applyGizmoAxisLimits`, `:1025-1043`).

### What Shots does now
- **Handle** (`ViewportHandles.resolveTarget`, `ViewportHandles.evaluatedBody`): for an entity whose track in the shot's take has marks, `ViewportHandleTarget.entity` carries the evaluated pose at the playhead (`body`), and the handle and rotate ring sit there with its heading. The drawn handle follows the preview. A drag starts from the committed document. An entity without marks keeps the placement handle.
- **Commands** (`ViewportHandles+Commands.swift`): a move or rotate of such an entity builds its commands with the arrow-key nudge's builder, `ViewportKeyboard.entityNudgeCommands`, now given an optional turn: `setPlacement` plus one `updateActorMark` per mark of the entity's track in the shot's take. A move shifts the placement, every mark and every `via` waypoint by the drag. A rotate turns them all about the drawn body by the drag's angle, and turns the placement heading and each `arriveHeading` by the same angle.
- **Preview and commit**: `store.preview` holds that batch while dragging, so the body, the marks and the paths follow live; release runs it once with `run(_ commands:)`, one undo step. A prop without marks still previews and commits a single `setPlacement`, through `run(_:)`, as before.
- **Contract** (CONTRACTS section 7): `ShotsStore.preview` is now `[ShotsCommand]`, applied in order, empty between gestures. The store's existing `perform(_ commands:)` and `run(_ commands:)` are now listed. Lane C's callers (inspector gesture, timeline drag, scene actions, keyboard actions) and the tests now set and compare lists; their behaviour is unchanged.

### Deviations from Blockout
1. **The placement shifts with the drag instead of jumping to the body.** Blockout sets `transform.position` to the dragged body position. Shots moves the placement by the same rigid motion as the marks, as the arrow-key nudge does, so the pose before the first mark keeps its relation to the path.
2. **`via` waypoints move with the marks.** Blockout's drag leaves them behind, which bends the path; Shots moves them as the nudge does.
3. **A rotate also turns each mark's `arriveHeading`.** Blockout rotates only mark positions, so an actor holding a mark with a set facing would not turn at all. Shots applies the rigid motion Blockout's comment describes to facings too; the drawn body then turns by the drag's angle (tested).
4. **Only the shot's take.** Blockout moves the entity's marks in every take; Shots, like the nudge and `updateActorMark`, edits the take the shot uses.
5. **Live preview of the blocking.** Blockout moves only the body until release; Shots previews the whole batch, so marks and paths follow the drag.
6. **No `y` clamp and no coalescing.** Blockout clamps `y` at 0 and may merge two quick same-label drags into one undo step. Shots keeps D4's unclamped Y axis and makes every drag its own undo step.
7. **Anchor only.** As before in Shots, a multi-selection's handle moves only the last-selected entity; Blockout moves the group rigidly (`:2053-2071`). Unchanged by this ruling.
8. **A press on a handle pauses playback.** Blockout keeps playing but freezes the dragged root (`:2003-2007`); Shots pauses, as the timeline's mark drag does, so the body and handle stay under the pointer.
9. **A ring click that does not turn commits nothing.** A rotate with no angle builds the batch without a turn, so it changes nothing and leaves no undo step, as D4's other targets do.

**Known limit (as in Blockout).** For an entity attached to a parent with the playhead before its own first mark, or riding a vehicle after a boarding mark (`boardID`), the body at the playhead follows the parent, not the marks. The handle sits on that body, but a move shifts the placement and marks, so the body at that frame does not follow the pointer. Blockout's married drag edits `attachedLocal` instead (`:1232-1246`); Shots' attachment is a transform in the parent's frame (`EntityAttachment`) and no handle edits it yet. Before this change the drag edited only the unused placement, so this is not a regression.

### Tests (each fails without the change, except the prop regression guard)
- `ViewportBlockedActorHandleTests` (new, `twoPersonWalk(small: true)` at frame 11, a `via` waypoint added to the Man's second mark):
  - `theHandleSitsOnTheBodyDrawnAtThePlayhead`: the target's pivot and heading are the evaluated body's, and the overlay's handle entity sits there (the Man is drawn more than 0.5 m from his placement).
  - `aMoveDragPreviewsTheWholeBlockingAndCommitsOneUndoStep`: through three points the preview holds four commands, the document is unchanged and the evaluated body is under the pointer; release commits once; the body ends at the release point; every mark and `via` waypoint and the placement moved by the drag's delta; the Woman's marks did not; one undo restores the document.
  - `theHandleSitsOnTheBodyDrawnAtThePlayhead` also checks that while another preview moves the Man, the drawn handle follows the preview and a drag still starts from the committed body.
  - `aRotateDragTurnsTheBlockingAboutTheDrawnBody`: a press on the ring pauses playback, and a click that does not turn commits nothing and leaves no undo step; a quarter turn keeps the body where it is drawn and turns its heading by π/2; every mark, waypoint and `arriveHeading`, and the placement's position and heading, turned about the body; one undo.
  - `aPropWithoutMarksStillEditsOnlyItsPlacement`: the chair's target has no body, the drag previews one `setPlacement`, and the blocking is untouched.
- IT4 (`ViewportIntegrationTests`) gains a step after the mark drag: at frame 8 a real click on the placed woman's body selects her; her handle entity sits on that body; a real-event drag through three points previews three commands with the document and the editor camera unchanged; release commits once with her body under the pointer; undo and redo walk that step. The expected document now ends with the same batch built by `perform` from the scripted pixels (placement and both marks shifted by the ground delta).

### Verification results
- `ViewportBlockedActorHandleTests` and `ViewportIntegrationTests` (IT4 and the rebuild-trigger test): 6 tests in 2 suites, all passed.
- Unfiltered `app` (`swift test --skip CloseDecisionTests`, debug): 1,000 Swift Testing tests in 167 suites reported, 0 failed, 11 skipped by the same gates as D6. `CloseDecisionTests` was skipped locally because it can hang reading the keychain on this Mac; CI runs it.
- `PrevisCore` (`swift test --package-path PrevisCore`, no fixture env): 159 tests in 23 suites reported, 0 failed, 5 skipped by their gates.
- `swiftlint lint --strict --quiet` and `swiftformat Sources Tests PrevisCore/Sources PrevisCore/Tests --lint`, from `app/` through `mise exec --`: 0 violations; 0/438 files need formatting.
- An independent adversarial review (Opus) of the diff found one defect, fixed here: a rotate click that did not turn committed an undo step, because turning by 0 is not exact and `normalizeAngle(π)` gives −π. Its nits are acted on: playback pauses on a handle press, the attached and boarded limit is recorded above, and the committed-scene branch and the placement under a rotate are tested.
- Not run here: release timing (`SHOTS_TIMING`), and the owner's on-screen walkthrough of the drag.

## Blockers and dependencies

- None. D0–D5 are merged; D6's dependencies, C3 and B6 (`36b3af9`), are merged.
- The owner's hands: on-screen walkthroughs (VoiceOver, physical keyboard, trackpad feel, signed sandbox, M1/M2 frame rate), which no headless test replaces.

## Open questions

- **Closed — D2 side-view sign check.** The owner ruled on 2026-11-09 that the check means the procedural `Gait.sit`, which passes: `d2-sign-check-side.png` puts the knees `0.409` m ahead of the hips, matching `BodyTests.sittingPutsTheKneesAheadOfTheHips()`. Blockout's seated motions (`sit-down`, `stand-up`, …) author `hipX` with the opposite sign to Blockout's own header (`motions.ts:20-21` against `motions.ts:2590-2595`); the integrator corrected that motion data in PrevisCore as a recorded deviation. The fix is `MotionCorrections`, [#89](https://github.com/RationallyPrime/concept-studio/pull/89), merge `9ff8741`, and CONTRACTS section 4 now records the joint-override signs. `torsoY` keeps the header and rig convention, positive turning counter-clockwise seen from above. Lane D changes no rig or motion data. The `sit-down` peak diagnostic (`d2-sign-check-sit-down-peak.png`, now `sideViewSignCheckSnapshotShowsTheCorrectedSitDownPeakWithKneesAhead`) shows the knees ahead of the hips since #89.
- **Closed — dragging a blocked actor (D4, found in D6).** The owner ruled on 2026-11-09 to follow Blockout. The handle of an actor with marks now sits on the body drawn at the playhead, and a drag moves the actor's placement, marks and `via` waypoints together, previewed live and committed as one undo step. `ShotsStore.preview` holds a command list for it (CONTRACTS section 7). See "Handle on an actor with marks" for the Blockout reading and the deviations.
