# Lane D status

Owner: Metis (Gemini). Canonical branch: `shots/d-viewport`. Current base `main`: `89d9e7d579e7ff74bc24b82ac3d418b525493ebe` (includes merged A1 `#59` and A2 `#64`).

## Checkpoints

| Checkpoint | State | Remaining work |
| --- | --- | --- |
| D0: shell and editor camera maths | **Draft PR [RationallyPrime/concept-studio#61](https://github.com/RationallyPrime/concept-studio/pull/61)** (rebased onto `89d9e7d` with additive light/dark contrast repair published on `shots/d-viewport`) | Current-head CI, independent closure review covering the rebased contrast repair, and integrator merge approval. Unblocks C1 hosting. |
| D1: RealityView display, gestures, grid and snapshots | **Implemented and verified locally on `shots/d-viewport-d1`** (rebased onto the published D0 head) | Preserved outside the D0 PR until D0 merges; ready to open the D1 checkpoint PR once D0 lands. |
| D2: overlays and playback | Blocked on A3 | A2 (`89d9e7d`) is now on `main`; D2 still needs merged A3 (posed mannequin bodies and keypoints). |
| D3: picking and tools | Blocked on C2 | Needs merged C2 command implementations (`addEntity`, `addActorMark`, `addCameraMark`). |
| D4: move and rotate handles | After D3 | Entity, actor-mark and camera-mark handles with `store.preview` while dragging and single `store.run` on release. |
| D5: look-through view, keyboard and VoiceOver | Blocked on B3 | Needs merged B3 exported still for look-through pixel parity (`middle-f0011-clean.png` on `twoPersonWalk(small: true)`). |
| D6: integration, performance and IT4 | Blocked on C3 and B6 | Needs merged C3 and B6; scripted IT4 workflow and release-build frame-time measurements. |

## Delivered in D0

- `EditorCamera`: pure value (`target`, `distance`, `yaw`, `pitch`, `focalLength`, `sensor`) built on `PrevisCore`'s `CameraFrame.make`, `CameraFrame.project`, `CameraFrame.ray`, `Vec3`, `Quat` and `Mat4`.
  - Orbit wraps yaw cleanly and clamps pitch away from the poles.
  - Pan shifts `target` in the camera's local right/up plane.
  - Dolly clamps distance to `0.5...200` m for both additive and multiplicative adjustments as well as direct assignment.
  - Produces a `CameraFrame` and picking rays for any positive `PixelSize`.
- `ShotsViewport(store:)` and `ShotCameraView(store:)`: placeholder SwiftUI views conforming to CONTRACTS section 7 (`init(store: ShotsStore)`), displaying scene/shot/frame state, read-only status and canvas aspect framing with VoiceOver labels.
  - Repaired in additive D0 cure commit per PR #61 integration finding `6415450470`: replaces paper-only `InstantPrint.ink` / `inkSecondary` / `rule` with appearance-adaptive `.primary`, `StudioStyle.supportingText`, and `Color.primary.opacity(0.16)` over `InstantPrint.ground` so both light (`.aqua`) and dark (`.darkAqua`) appearances render with high contrast.
- `ViewportEditorCameraTests`: headless Swift Testing suite verifying:
  - 360° orbit returns to the starting orientation, position and `CameraFrame` in both single-step and 72-step increments;
  - dolly clamps between `0.5` m and `200` m;
  - `target` projects to the exact centre of arbitrary `PixelSize` values (`640×1152`, `320×576`, `1920×1080`, `768×768`, `413×271`, `271×917`) and the centre ray passes through `target` at `distance`;
  - `ShotsViewport(store:)` and `ShotCameraView(store:)` initialise against `ShotsStore` on `ShotsSamples.twoPersonWalk(small: true)` and render with >0.45 luminance contrast span in both `.aqua` (light) and `.darkAqua` (dark) offscreen `NSHostingView` captures at `980×680` (minimum) and `1240×820` (default), optionally exporting PNGs when `SHOTS_D0_PREVIEW_DIR` is set.

## Prepared in D1 (`shots/d-viewport-d1`, preserved outside D0 PR)

- `ShotsViewport`: hosts `RealityView` displaying `store.frame` through `PrevisSceneMapper`, with `overlayRoot` attached as a separate root so editor chrome never leaks into exported passes, post-effects disabled (`motionBlur`, `depthOfField`, `cameraGrain`, standard dynamic range), macOS 27 `OcclusionCullingComponent(isEnabled: false)` applied, and appearance-appropriate HUD styling.
- `ViewportGrid`: 1 m ground grid (`-10...10` m) with major axis lines under `overlayRoot`.
- `ViewportCameraGestures` & `ViewportScrollWheelOverlay`: trackpad and mouse orbit drag, `⌥`-drag / two-finger pan, and pinch / scroll dolly.
- `ViewportSnapshotRenderer`: renders offscreen viewport snapshots via `ShotFrameRenderer.image(of:look:camera:overlay:size:)` using `editorCamera.cameraFrame(for:)` and `overlayRoot.clone(recursive: true)`.
- `ViewportDisplayTests`:
  - Regenerates default-view and top-view snapshots of `ShotsSamples.twoPersonWalk(small: true)` and verifies every entity's projected centre pixel is inside the frame, differs from the background colour, and differs from a bare (no-entities) render at that pixel.
  - Verifies the grid overlay renders in viewport snapshots while leaving `overlayRoot.parent == nil` and clean export renders untouched.
  - Regenerates full-size snapshots (`d1-sample-default.png`, `d1-sample-top.png`) when `SHOTS_SNAPSHOT_DIR` is set:
    ```sh
    SHOTS_SNAPSHOT_DIR=<dir> .github/scripts/swift-test-watchdog.sh --package-path app --build-system native \
      --filter 'ViewportDisplayTests/writesFullSizeDefaultAndTopSnapshotsWhenSnapshotDirectoryIsSet'
    ```

## How to verify D0

From the repository root:

```sh
.github/scripts/swift-test-watchdog.sh --package-path app --build-system native \
  --filter 'ViewportEditorCameraTests'
```

To also write the `980×680` and `1240×820` light/dark PNG captures (`d0-viewport-{light,dark}-{minimum,default}.png` and `d0-shot-camera-{light,dark}-{minimum,default}.png`):

```sh
SHOTS_D0_PREVIEW_DIR=<dir> .github/scripts/swift-test-watchdog.sh --package-path app --build-system native \
  --filter 'ViewportEditorCameraTests/viewportAndShotCameraShellsRenderReadablyInLightAndDarkAppearances'
```

And the full CI lint and core gates:

```sh
.github/scripts/swift-test-watchdog.sh --package-path app/PrevisCore --build-system native
cd app && mise exec -- swiftlint lint --strict && \
  mise exec -- swiftformat Sources Tests PrevisCore/Sources PrevisCore/Tests --lint
```

### Verification results (macOS Apple silicon, local Xcode / RealityKit, base `89d9e7d`)

- **D0 rebased + contrast repair (`shots/d-viewport`) — Run and passed:**
  - `ViewportEditorCameraTests`: 4 tests (9 test cases including parameterised `PixelSize` cases and offscreen `.aqua`/`.darkAqua` contrast verification at `980×680` and `1240×820`) ran, 4 passed, 0 failed, 0 skipped.
  - Focused Shots suites (`ShotsCloseTests|ShotsWorkspaceTests|ShotsStoreTests|ShotsDocumentFileTests`): 14 tests ran, 14 passed, 0 failed, 0 skipped.
  - `PrevisCoreTests`: 27 tests in 6 suites — 26 ran and passed, 0 failed, 1 skipped (`everyScenePasses()`, gated on `PREVIS_GOLDENS`/`PREVIS_VECTORS`).
  - `mise exec -- swiftlint lint --strict` (from `app/`): 0 violations, 0 serious across 334 files.
  - `mise exec -- swiftformat Sources Tests PrevisCore/Sources PrevisCore/Tests --lint` (from `app/`): 0/334 files require formatting.
  - *Build-cache note:* An initial compile invocation (`task-131`) timed out during compilation when macOS iCloud file-provider syncing touched in-tree `.build/build.db` and intermediate `.o` files; passing `--scratch-path` outside the synced directory resolved the build-database contention with zero code changes or weakened test checks.
- **D1 (`shots/d-viewport-d1`) — Run and passed:**
  - `ViewportEditorCameraTests|ViewportDisplayTests` (default env): 7 tests in 2 suites — 6 ran and passed (including `defaultAndTopSnapshotsDrawEveryEntityAboveBackgroundAndKeepOverlaySeparate`), 0 failed, 1 skipped (`writesFullSizeDefaultAndTopSnapshotsWhenSnapshotDirectoryIsSet` when `SHOTS_SNAPSHOT_DIR` is unset).
  - `ViewportDisplayTests/writesFullSizeDefaultAndTopSnapshotsWhenSnapshotDirectoryIsSet` (with `SHOTS_SNAPSHOT_DIR` set): 1 ran, 1 passed, writing `d1-sample-default.png` and `d1-sample-top.png`.
  - `swiftlint lint --strict` and `swiftformat --lint` across 338 files: 0 violations, 0 files require formatting.
- **Not run locally:**
  - Full `ConceptStudioTests` suite (existing non-Shots suites hit the pre-existing local login Keychain prompt reported in `lane-b.md`).
  - Live window interactive walkthrough and signed sandbox UI verification.

## Blockers and dependencies

- **D0:** Published on `shots/d-viewport` (Draft PR #61, rebased onto `89d9e7d` with additive light/dark contrast repair); awaiting current-head CI, independent closure review, and integrator merge.
- **D1:** Ready on local branch `shots/d-viewport-d1`; waiting for D0 PR #61 to merge before opening the D1 PR (one checkpoint PR at a time).
- **D2:** A2 (`89d9e7d`) is now merged; D2 remains blocked on merged A3 (mannequin rigs and keypoints).
- **D3–D4:** Blocked on merged C2 (remaining entity and mark commands).
- **D5:** Blocked on merged B3 (exported guide stills for look-through parity).
- **D6:** Blocked on merged C3 and B6.

## Open questions

- None for D0 or D1.
