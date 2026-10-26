# Lane B: ShotsMedia

**Seat:** Claude (the plan's author). **Targets:** `ShotsMedia`, `ShotsExportTool` (`shots-export`),
`ShotsMediaTests`, plus the one-time W0 wiring.

**Mission.** Turn `SceneFrame`s into pixels and packages. This lane builds:
- the shared build wiring;
- one canonical look and scene mapping, shared by the viewport and export;
- the offscreen frame renderer, used by the exporter and the look-through view;
- frame-exact video, the four passes, and the package format with its validator;
- the CLI and the H3 prompt compiler.

It also maintains README.md and the lane documents.

**Read first:**
- [CONTRACTS.md](CONTRACTS.md) sections 1–4, 6, 8.3, 9 and 10.
- [SHOTS-PLAN.md](../SHOTS-PLAN.md) sections 2, 6 and 7.

## Checkpoints

### W0: wiring (first, about an hour; A0 starts on top of it)

**Deliver** everything in CONTRACTS section 2 under "W0":
- The `app/PrevisCore` package skeleton, with its resources folder holding `LICENSE` (Apache-2.0) and
  `NOTICE`.
- The `app/Package.swift` dependency and targets.
- A placeholder file in every new source and resources folder.
- A CI step for PrevisCore's tests, right after the app's test step.
- Lint and format paths for `PrevisCore/Sources` and `PrevisCore/Tests`, never the whole `PrevisCore`
  folder, whose `.build` holds generated files.
- `scripts/render-app-preview.sh` copying PrevisCore's `Package.swift`, `Sources` and `Tests` into its
  snapshot.
- The `bun` pin.

**Verify:**
- Locally, in `app/`: `swift build`, `swift test` and `swift test --package-path PrevisCore` pass.
- From `app/`: `mise exec -- swiftlint lint --strict` and
  `mise exec -- swiftformat Sources Tests PrevisCore/Sources PrevisCore/Tests --lint` are clean, even after
  PrevisCore's tests have run.
- `scripts/render-app-preview.sh` still renders.
- The PR's CI run is green.

**Unblocks:** A0.

### B0: API skeleton (day 1, after A0)

**Deliver:**
- Every declaration in CONTRACTS section 6 and the package types in section 8.3, compiling, with public
  initialisers and no crashing stubs.
- `ShotsCommandLine.run` printing usage.
- The executable calling it, and `ShotsSelfTest.run` returning a failure code until B2.

**Verify:** the build passes, and `swift run shots-export` prints usage and exits with code 2.

**Unblocks:** C0 (it wires `--shots-self-test`), D0.

### B1: scene mapper and frame renderer (day 1)

**Deliver:**
- `PrevisSceneMapper`:
  - shapes become meshes, cached by shape;
  - capsules are built from a cylinder and two spheres, and the wedge from a custom mesh;
  - colours become materials;
  - each `LightingPreset` becomes directional lights and a background;
  - posed transforms become entity transforms.
- `ShotFrameRenderer` on RealityKit's offscreen `RealityRenderer`, with the `size` and `overlay` options.

**Verify** with render tests on `twoPersonWalk(small: true)`:
- The pixel at each projected keypoint and box centre isn't background.
- Markers at known world points land within 0.5 px of `CameraFrame.project`.
- Two renders of one frame give identical bytes.
- The PR's CI log shows the render tests ran on the macOS runner. If RealityKit can't render there, set
  `SHOTS_SKIP_RENDER: 1` on the swift job and record why (CONTRACTS section 9).

**Unblocks:** D1.

### B2: video, verification and the sandbox self-test (days 1–2)

**Deliver:**
- A frame-exact `AVAssetWriter` path fed straight from the renderer's buffers.
- A reader that checks frame count, size and presentation times. It is the core of the validator.
- The clean reference video.
- `ShotsSelfTest.run`: it renders and encodes the 124-frame sample into the app's temporary folder, then
  prints a JSON report to stdout (frames, presentation times, size, timing).

**Verify:**
- A test exports the small sample's clean video and finds exactly 22 frames at 320 × 576, presentation
  times i/24 at the first, middle and last frames, and BT.709 tags.
- After `scripts/build-app.sh`, `dist/ConceptStudio.app/Contents/MacOS/ConceptStudio --shots-self-test`
  prints a report with 124 frames, from the signed, sandboxed build. This needs C0's launch flag.

### B3: passes, package and the sample CLI, plus IT1 (day 2)

**Deliver:**
- **Passes:**
  - **pose:** drawn in 2D from projected keypoints;
  - **layout:** boxes;
  - **mattes:** visible silhouettes, rendered unlit with other entities black and the actor white;
  - **guide stills** in their variants.
- **Package files:** `shot.json`, the manifest with its `passes`, `FolderDestination` (including its
  staging folder), and `PackageValidator`, which checks only the passes the manifest lists.
- **Staging:** export builds in the staging folder, validates, then delivers.
- **CLI:** `shots-export --sample --out <dir>`, through `ShotsCommandLine`.

**Verify:**
- **IT1:** the full 124-frame sample → export → the validator reports nothing. This is the suite's one
  full-length export.
- The pose stills carry OpenPose colours at the keypoint pixels.
- In each matte, only the actor's region is white.
- One test confirms the validator does fail: delete one file from a valid package, and the validator
  names it.
- `swift run shots-export --sample --out <dir>` prints the package path and exits with code 0.

**Unblocks:** C3 (export), D5 (the exported still the look-through is compared with).

### B4: Blockout and document input, plus IT2 (days 2–3)

**Deliver:** two more input modes for `ShotsCommandLine`, plus options for Blockout input:
```
shots-export --blockout <project.json> [--scene <id|index>] [--shot <id|name>] --out <dir>
shots-export --document <shots.json> --shot <id> --out <dir>
             [--frames N] [--canvas WxH] [--passes clean,pose,layout,matte]   (Blockout input only)
```
Each writes the package, runs the validator, prints the path, and exits with a non-zero code on any
problem.

**Verify:**
- **IT2:** write `ShotsSamples.blockoutProjectJSON()` to a temp file. Import → set the shot to 22 frames
  at 320 × 576 → export → validator clean. The same through `ShotsCommandLine.run(arguments:)` in-process,
  with `--frames 22 --canvas 320x576`.
- An export with `--passes clean` validates, because the validator checks only the listed passes.
- **Milestone M1, headless packages.** Owner-run, outside CI: export a Blockout project with
  `swift run -c release shots-export --blockout <file> --out <dir>` and take it into ComfyUI. Ready means:
  - the validator passes;
  - frame count, width and height match the graph's length, width and height;
  - guide frames line up with the guide nodes' frame indices.

### B5: prompt (day 3)

**Deliver:**
- `PromptFacts`:
  - frame count, duration, and the Picture 1 and Picture 2 times;
  - middle guides;
  - camera legs classified by move (push or pull, orbit left or right, crane, pan or tilt, zoom, static)
    and speed (slow, medium, fast);
  - subjects with their marks, gaits and appearance notes;
  - setting, sound, music and lens;
  - the scene revision.
- `template`, following CONTRACTS 8.3.
- `write`: runs `StructuredStage` on the app's `ResolvedEndpoint`. It asks for
  `integrated_multimodal_description`, `overall_soundscape` and `non_diegetic_music` under a bundled skill.
  - The skill lives at `Resources/Skills/h3-shot-prompt/SKILL.md` and is **written by us** from MiniMax's
    published prompt structure; MiniMax's skill isn't bundled.
  - Code writes the header, so the picture times are always exact.
- Export writes `prompt.txt` and `prompt.json` when the shot has a prompt.

**Verify:**
- A test with a fake `ModelClient` returning fixed sections. The text matches the format exactly: header
  times from the frame count, then the three sections in order.
- Facts for the sample classify its move as a push-in.
- The template for a shot without notes still has all three sections.

**Unblocks:** C5 ("Write H3 prompt").

### B6: app support and budgets (days 3–4)

**Deliver:** the budgets from CONTRACTS section 10, export progress steps C can show, a tested
cancellation, and fixes for whatever C and D report.

**Verify:**
- On a Mac, `SHOTS_TIMING=1 swift test -c release --filter Timing` in `app/`, and the same with
  `--package-path PrevisCore` for Lane A's budgets. Record every number in this status file.
- Cancelling mid-export leaves neither a staging folder nor a package.

**Unblocks:** D6 (performance).

### B7: walkthrough fixes (day 5)

## Technical facts from the probes

These were measured on Apple silicon; the probes ran outside the sandbox.
- **Driving the renderer.**
  - `RealityRenderer` (macOS 15+) renders into an `MTLTexture` from a process with no window.
  - Set every transform yourself and call `updateAndRender(deltaTime: 0, …)`.
  - No `AnimationResource`, no physics.
  - Await completion before touching the buffer.
- **Render targets.** Render into an IOSurface-backed `CVPixelBuffer` from the writer adaptor's pool,
  through a texture-cache view in `.bgra8Unorm_srgb`. Plain `.bgra8Unorm` darkens mid-grey from 128 to
  55.
- **No depth.** `RealityRenderer` outputs colour only; depth stays reserved.
- **Lighting.** With no light a lit material is black, and there's no ambient term. Build presets from
  directional lights; use `UnlitMaterial` for mattes and layout.
- **Colour.** Saturated tints drifted in one probe, (1, .25, 0) coming out as (235, 81, 40). Calibrate
  label tints, or keep them muted.
- **Camera.** `PerspectiveCameraComponent` with a vertical field of view matched the pinhole within
  0.4 px. A matrix on `ProjectiveTransformCameraComponent` must be reverse-Z with an infinite far plane;
  a forward-Z finite matrix renders nothing.
- **Antialiasing.** Off or 4× multisampling only, both deterministic on one machine. Use 4× for clean,
  and off for mattes.
- **Video writing.**
  - `AVAssetWriter` with `expectsMediaDataInRealTime = false`, frames appended at
    `CMTime(value: i, timescale: 24)`, and `endSession(atSourceTime: N/24)` gives exact timestamps.
  - Odd sizes are cropped silently.
  - ProRes with a bitrate key crashes with an exception Swift can't catch, so don't use ProRes.
- **Reading video back.** An `AVAssetReader` passthrough returns empty marker buffers; count only buffers
  with a sample count above 0.
- **Concurrency.** `CVPixelBuffer` isn't `Sendable`. Keep creation, rendering and appending in one
  main-actor pipeline.
- **No subprocesses** (a PRODUCT rule).
- **No `.metal` files:** Xcode installs the Metal compiler only as a separate download.

## Out of scope

Depth, filling ComfyUI graph templates (a later destination), generation, sky rendering, and labels in any
exported pixel.
