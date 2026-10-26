# Lane D status

Owner: Metis (Gemini). Canonical branch: `shots/d-viewport`. Base `main`: `1366c3540f9ca41736039806549fd489d4c52822`.

## Checkpoints

| Checkpoint | State | Remaining work |
| --- | --- | --- |
| D0: shell and editor camera maths | Implemented and tested locally; draft PR opened | Current-head CI, independent review closure, and integrator merge approval. Unblocks C1 hosting. |
| D1: RealityView display, gestures, grid and snapshots | Next (dependencies W0, A0, B0, C0, B1 merged on `main`) | Preserved separately from the D0 checkpoint PR so D0 can land cleanly. |
| D2: overlays and playback | Blocked on A2 and A3 | Needs merged A2 (`paths()` and motion evaluation) and A3 (posed mannequin bodies and keypoints). |
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
- `ViewportEditorCameraTests`: headless Swift Testing suite verifying:
  - 360° orbit returns to the starting orientation, position and `CameraFrame` in both single-step and 72-step increments;
  - dolly clamps between `0.5` m and `200` m;
  - `target` projects to the exact centre of arbitrary `PixelSize` values (`640×1152`, `320×576`, `1920×1080`, `768×768`, `413×271`, `271×917`) and the centre ray passes through `target` at `distance`;
  - `ShotsViewport(store:)` and `ShotCameraView(store:)` initialise against `ShotsStore` on `ShotsSamples.twoPersonWalk(small: true)`.

## How to verify D0

From the repository root:

```sh
.github/scripts/swift-test-watchdog.sh --package-path app --build-system native \
  --filter 'ViewportEditorCameraTests'
```

And the full CI lint and core gates:

```sh
.github/scripts/swift-test-watchdog.sh --package-path app/PrevisCore --build-system native
cd app && mise exec -- swiftlint lint --strict && \
  mise exec -- swiftformat Sources Tests PrevisCore/Sources PrevisCore/Tests --lint
```

### Verification results (macOS Apple silicon, local Xcode / RealityKit)

- **Run and passed:**
  - `ViewportEditorCameraTests`: 4 tests (9 test cases including parameterised `PixelSize` cases) ran, 4 passed, 0 failed, 0 skipped.
  - Focused Shots suites (`ShotsCloseTests|ShotsWorkspaceTests|ShotsStoreTests|ShotsDocumentFileTests`): 14 tests ran, 14 passed, 0 failed, 0 skipped.
  - `PrevisCoreTests`: 4 tests ran, 4 passed, 0 failed, 0 skipped.
  - `mise exec -- swiftlint lint --strict` (from `app/`): 0 violations, 0 serious across 324 files.
  - `mise exec -- swiftformat Sources Tests PrevisCore/Sources PrevisCore/Tests --lint` (from `app/`): 0/324 files require formatting.
- **Not run in D0:**
  - Full `ConceptStudioTests` suite (existing non-Shots suites hit the pre-existing local login Keychain prompt reported in `lane-b.md`).
  - Live window interaction, offscreen `RealityView` / `ShotFrameRenderer` viewport snapshots (scheduled for D1), and signed sandbox UI checks. D0 is a placeholder and pure camera-math checkpoint, not visual viewport acceptance.

## Blockers and dependencies

- **D0:** No code blockers. Ready for CI, independent review and integrator merge to unblock C1.
- **D2:** Blocked on merged A2 (motion paths and time evaluation) and A3 (mannequin rigs and keypoints).
- **D3–D4:** Blocked on merged C2 (remaining entity and mark commands).
- **D5:** Blocked on merged B3 (exported guide stills for look-through parity).
- **D6:** Blocked on merged C3 and B6.

## Open questions

- None for D0.
