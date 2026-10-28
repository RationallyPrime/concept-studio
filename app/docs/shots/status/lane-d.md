# Lane D status

Owner: Metis (Gemini). Current D5 look-through branch: `shots/d-look-through` (based on `main` `139a2e42095fd509241377286b636ff8d3c18cda`, which includes merged D0 `#61` and D1 `#72`). Preserved prior branches: D2 `shots/d-overlays` (`cc2fa25e221bcb39a68a79c6bcea98c242cd8c66` on Draft PR [#81](https://github.com/RationallyPrime/concept-studio/pull/81)) and D3 `shots/d-picking` (`fdb33e2996d756ccbeb6193d090b4bbd73784710` on Draft PR [#82](https://github.com/RationallyPrime/concept-studio/pull/82)).
Reference implementation: [Blockout](https://github.com/wassermanproductions/blockout) at `3f2d0564fd575f70fc28e9bfaa7e94b05e3955d9` (`scripts/blockout/fetch.sh`).

## Checkpoints

| Checkpoint | State | Remaining work |
| --- | --- | --- |
| D0: shell and editor camera maths | **Merged** ([RationallyPrime/concept-studio#61](https://github.com/RationallyPrime/concept-studio/pull/61), `42871fbdec650df2f8436febb3d94858b71c9769`) | Complete. |
| D1: RealityView display, gestures, grid and snapshots | **Merged** ([RationallyPrime/concept-studio#72](https://github.com/RationallyPrime/concept-studio/pull/72), `efbe83380dc387100c9059ce62b305de81a069a2`) | Complete. |
| D2: overlays and playback | **Draft PR [#81](https://github.com/RationallyPrime/concept-studio/pull/81) on `shots/d-overlays` (`cc2fa25`)** — all 7 CI jobs green (`40612874202`), Round 1 P2 label-facing closure accepted ([issuecomment-6457931637](https://github.com/RationallyPrime/concept-studio/pull/81#issuecomment-6457931637)) | Held in Draft for raw `"sit-down"` peak keyframe vs `Gait.sit` sign-check contract disposition and Gnomon workspace trust. |
| D3: picking and tools | **Draft PR [#82](https://github.com/RationallyPrime/concept-studio/pull/82) on `shots/d-picking` (`fdb33e2`)** — all 7 CI jobs green (`40625014667`), Round 1 P2 sub-threshold jitter closure accepted ([issuecomment-6459717747](https://github.com/RationallyPrime/concept-studio/pull/82#issuecomment-6459717747)) | All accepted headless D3 checks and CI complete; held in Draft under current coordination no-merge instruction. |
| D4: move and rotate handles | After D3 integration | Entity, actor-mark and camera-mark handles with `store.preview` while dragging and single `store.run` on release. |
| D5: look-through view, keyboard and VoiceOver | **Local rendering-slice verified on `shots/d-look-through`** (`ShotCameraView.swift`, `ViewportLookThroughTests.swift`) | Draft PR publication, initial independent review, exact-head CI, plus remaining focused viewport keys (`CONTRACTS.md` section 7) and VoiceOver selection announcements. |
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
- **Not run locally in D1:**
  - Unfiltered full `ConceptStudioTests` suite.
  - Live window interactive walkthrough and signed sandbox UI verification.

## Delivered in D5 Look-Through Rendering Slice (`shots/d-look-through`)

### Reference files inspected for D5 (`3f2d0564fd575f70fc28e9bfaa7e94b05e3955d9`)
- `src/renderer/viewport/SceneManager.ts:2099-2112, 2218-2296, 2371-2455` (`applyTime(t)` shot-camera projection, letterboxed look-through viewport `vw`/`vh`/`vx`/`vy`, PiP live shot preview hiding editor chrome, and `renderFrameAt` deterministic export rendering).
- `src/renderer/viewport/Viewport.tsx:331-375, 398-417, 470-531, 540-588` (`viewRect` letterbox state, `"🎥 Look through"` control, PiP preview chrome, and letterbox frame overlay).
- `tests/e2e/smoke.spec.ts:114-130` (deterministic frame rendering across interleaved renders).

### Preserved behaviors and intentional Swift/RealityKit adaptations in D5 (`ShotCameraView.swift`, `ViewportLookThroughTests.swift`)
1. **Shared export renderer and canonical look (`ShotCameraView`, `ShotCameraPreviewSession` ← `LANE-D-VIEWPORT.md` lines 47-49, 136-144, 166; `SHOTS-PLAN.md` section 4):**
   - RealityKit's `RealityView` supports a single active camera, and Blockout's live WebGL viewport applied tone mapping/exposure that differed from its exporter. `ShotCameraView` renders `store.frame` offscreen via `ShotFrameRenderer.image(of: frame, look: PrevisLook(scene: scene))` with no editor overlay (`overlay == nil`), matching `ShotExporter`'s `.clean` pass pixel-for-pixel by construction.
2. **Latest-wins request coalescing (`ShotCameraPreviewSession`):**
   - Keeps at most one render in flight and at most one newest pending `ShotCameraRenderRequest` (`sceneID`, `sceneRevision`, `shotID`, `shotName`, `frame`, `look`), collapsing intermediate playhead/document updates while preventing stale in-flight completions from overwriting a switched or cleared shot context.
   - Render failures set `session.errorMessage`, clear `renderedImage` (never silently succeeding), report through `store.onError`, and recover on subsequent requests.
3. **Canvas letterboxing (`ShotCameraView.letterboxRect(in:canvas:)` ← `SceneManager.ts:2220-2240`):**
   - Fits the active `ShotCanvas` aspect ratio centered inside the available view bounds while preserving `InstantPrint.ground` contrast and accessibility labeling in both `.aqua` and `.darkAqua` appearances.

### Verification results for D5 rendering slice (`shots/d-look-through`, base `139a2e4`)
- `ViewportLookThroughTests`: 6 tests in 1 suite reported (`0.572s`; 6 executed, 0 skipped, 0 failed), including `lookThroughFrameElevenMatchesExportedMiddleGuideCleanPNGAsDecodedRGB` (`twoPersonWalk(small: true)`, 22 frames, `320×576`, frame 11 look-through image equals exported `guides/middle-f0011-clean.png` as decoded sRGB bytes).
- Focused Shots & Viewport suites (`--filter 'Shots|Viewport'`): 179 tests in 32 suites reported (`7.329s`; 175 executed, 4 skipped when preset/snapshot env vars are unset, 0 failed).
- Full unfiltered `app` test suite: 950 tests in 156 suites reported (`27.037s`; 942 executed, 8 skipped, 0 failed).
- `PrevisCoreTests` (no fixture env): 148 tests in 20 suites reported (`1.451s`; 144 executed, 4 skipped, 0 failed).
- `PrevisCoreTests` (with `PREVIS_GOLDENS` and `PREVIS_VECTORS` set): 148 tests in 20 suites reported (`1.554s`; 148 executed, 0 skipped, 0 failed).
- `swiftlint lint --strict` & `swiftformat --lint`: 0 violations across 412 files (`0/412` require formatting).
- **Not run / separately pending:**
  - Remaining D5 focused viewport keyboard shortcuts (`CONTRACTS.md` section 7) and VoiceOver selection announcements.
  - Physical native desktop walkthrough, VoiceOver interactive check, M1/M2 release-build frame-time measurements, and signed sandbox verification.

## Blockers and dependencies

- **D2:** Held in Draft PR [#81](https://github.com/RationallyPrime/concept-studio/pull/81) (`cc2fa25` on `shots/d-overlays`, all 7 CI jobs green, Round 1 P2 label-facing closure accepted) pending coordinator disposition on the raw `"sit-down"` peak keyframe vs `Gait.sit` sign-check contract mismatch and Gnomon workspace trust.
- **D3:** Draft PR [#82](https://github.com/RationallyPrime/concept-studio/pull/82) (`fdb33e2` on `shots/d-picking`, all 7 CI jobs green, Round 1 P2 closure accepted); held in Draft under current coordination no-merge instruction.
- **D4:** After D3 integration (`store.preview` move/rotate handles).
- **D5:** Local rendering-slice verified on `shots/d-look-through`; Draft PR publication, initial independent review, exact-head CI, and remaining focused viewport keys/VoiceOver pending.
- **D6:** Blocked on merged B6.

## Open questions

- None for the D5 look-through rendering slice.
