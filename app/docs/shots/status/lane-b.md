# Lane B status

This file travels at the top of Lane B's stack (now `shots/b-media-b3`), so checkpoints that have passed review keep their exact heads.

| Checkpoint | State |
|---|---|
| W0 wiring | **Landed on `main`** as merge commit `ff2cce2`, by the integration owner, from head `42de04a`, with the branch preserved. Codex cleared `f1c3d51` and `42de04a`, and all seven CI jobs passed at `42de04a`. |
| B0 API skeleton | **Draft PR [RationallyPrime/concept-studio#54](https://github.com/RationallyPrime/concept-studio/pull/54), stacked on A0 (#52).** Every CONTRACTS section 6 declaration and the section 8.3 package types compile against A0's real PrevisCore. `ShotsCommandLine` prints usage, and `shots-export` exits with code 2. `ShotsSelfTest.run()` prints a JSON report and returns 1 until B2. `PackageValidator` reports "not implemented" rather than "valid". Unimplemented work throws `ShotsError.notImplemented`. Build and both linters are clean (author verification). All seven CI jobs pass on `41199e5`. Lane C's C0 builds on this head; that is consumer integration, not code review. No independent code review yet. |
| B1 scene mapper and frame renderer | **Draft PR [RationallyPrime/concept-studio#55](https://github.com/RationallyPrime/concept-studio/pull/55), stacked on B0 (#54), repair head `95b4d27`.** `PrevisSceneMapper` gives one container per entity, parts keyed by id, meshes cached by shape (capsules are a cylinder plus two spheres; wedges are a flat-shaded custom mesh), materials cached by colour, and a ground plane with a three-light rig per preset. `ShotFrameRenderer` renders offscreen with `RealityRenderer`, zero time step, 4× multisampling and no tone mapping, into IOSurface buffers through `.bgra8Unorm_srgb`, with the `size` and `overlay` options. Overlapping calls render one at a time, a cancelled call throws without holding up the queue, and on macOS 27 occlusion culling is off, so a frame never depends on an earlier render. **Author verification:** six render tests pass locally in five consecutive runs (projection, 0.5 px marker parity, wedge winding, identical bytes after other frames and looks, an overlapping render without an overlay staying clean, and cancelled renders throwing while a later one still renders clean). **Package test verification:** Lane C reran the four render tests at `69a814d`. **CI execution:** run 40277594522 at `69a814d` executed and passed all four render tests on the macOS runner; only the optional snapshot test skipped. Run 40279486059 at `3bc3a27` executed and passed all five render tests, and its `swift test` step took 158 s. **Independent review:** Codex reviewed `69a814d` and raised one P2, overlapping renders sharing an overlay. It is fixed in `3bc3a27`, together with a macOS 27 culling defect found while verifying it: right after a camera cut, a whole entity could be missing. The closure review of `3bc3a27` raised a second P2, cancelled renders still rendering, fixed in `95b4d27`. **Closure:** Codex's bounded closure review of `95b4d27` reports no unresolved findings, and all seven CI jobs pass there. CI ran the overlap and cancellation tests (35 s and 40 s on the runner). Still open: checkpoint integration approval. |
| B2 video writer and self-test | **Draft PR [RationallyPrime/concept-studio#57](https://github.com/RationallyPrime/concept-studio/pull/57), stacked on B1 (#55).** `VideoWriter` encodes H.264 straight from the renderer's IOSurface buffers: frame i at exactly i/24 s, the file ending at N/24 s, BT.709 tags. `writeCleanVideo` produces the clean reference video, `VideoInspector` reads videos back for the validator, and `ShotsSelfTest.run()` renders the full sample and prints a JSON report. **Author verification:** the small sample's clean video has 22 frames at 320 × 576, presentation times 0/24, 11/24 and 21/24, and BT.709 tags, and its decoded middle frame matches the renderer (mean 0.49 levels; unrendered buffers give 97 and fail). From the signed, sandboxed debug build, with C0 merged locally for verification only, `--shots-self-test` exits 0 and reports 124 frames at 640 × 1152, avc1, BT.709, times 0/24, 62/24 and 123/24, in 0.82 s, writing inside the app's container. ffprobe reads the same full-size video as h264 High with bt709 tags, 24/1 fps, 124 decoded frames and 124/24 s. **Lane C** read the saved self-test report and local suite logs: consistent with the result above, not an independent rerun. **CI at `06b771a`:** all seven jobs pass; the clean-video test executed in 89 s on the runner, and the `swift test` step took 200 s of the 300 s watchdog. **Independent review:** Codex reviewed `06b771a` and raised two findings. The P1: a writer that had stopped left `append` waiting forever. The P2: an export cancelled during finalization returned success and kept its file. Both are fixed in `0052c3d`, on B1's `95b4d27`, with regressions that fail before the fixes. A full disk on this Mac fails the writer with readiness still true, so that case threw rather than hung; a cancelled writer reproduces the hang. The earlier signed self-test success predates these error paths and doesn't cover them. A rerun on the repaired bytes passes: local verification merge `92cffe8`, of B2 `2286487` and C0 `86bee46`, built signed and sandboxed. `--shots-self-test` exits 0 with 124 frames at 640 × 1152, avc1, BT.709, times 0/24, 62/24 and 123/24, in 0.60 s. It covers the success path; the writer tests cover the error paths. **Closure:** Codex's bounded closure review of `2286487` found no major issues and left none unresolved (receipt comment 6410036481). All seven CI jobs pass there (run 40281892066): both writer tests and the clean-video test, 779 app tests in 127 suites, the four PrevisCore tests, and formatting. The `swift test` step took 127 s. Still open: checkpoint integration approval. |
| B3 passes, package and sample CLI | **Draft PR [RationallyPrime/concept-studio#58](https://github.com/RationallyPrime/concept-studio/pull/58), stacked on B2 (#57).** **What's built:**
- **Pose:** drawn the way ComfyUI's DWPose preprocessor draws: limbs at 60 %, then joints in exact OpenPose COCO-18 colours on top, unantialiased, on black.
- **Layout:** label-coloured or palette boxes over each actor's projected bounds, on white.
- **Mattes:** the actor unlit white, everything else black, so other entities occlude it.
- **Guide stills** come from the same pixels as the videos.
- **Package:** `shot.json`, the manifest and the validator, per CONTRACTS section 8.3.
- **`ShotExporter`** builds in staging, validates, then delivers, and removes the staging folder on any error or cancellation.
- **CLI:** `shots-export --sample --out <dir>`.

**Author verification:** 16 ShotsMedia tests pass in three runs: 15 run, and the snapshot test skips.
- **IT1:** the full sample through the CLI; the validator is clean, and 21 files carry the expected roles.
- **Pose:** OpenPose colours at the keypoint pixels, and the 60 % limb colour.
- **Layout:** label and palette colours.
- **Mattes:** each is white only over its own actor.
- **Validator:** it names a deleted file.
- **Cancellation:** a cancelled export leaves nothing behind.
- **Inverse checks:** three deliberate breaks each fail their test: joints drawn under limbs, white non-actors in a matte, and no staging cleanup.
- **CLI run:** `shots-export --sample --out <dir>` exits 0 in 3 s and prints the package path.

**Waiting on Lane A:** A0's evaluator gives one grey box per entity and no keypoints. Until A3, pose videos are black and mattes are boxes. IT1's keypoint-pixel check joins then.

**Not yet built:** prompt files, which arrive with B5. |
| B4–B7 | Not started |

## W0 verification (2026-10-26, Apple silicon, Swift 6.4 locally; CI runs Swift 6.3)

- `swift build` passes, with both the default and the native build system.
- **App suite:** run under `.github/scripts/swift-test-watchdog.sh` with
  `--build-system native --skip CloseDecisionTests`. **759 passed, 0 failed, then a 900 s watchdog
  timeout.** That is not a full-suite pass.
  - The run stopped inside the suites "project contract and app-only state" and "studio offline actions".
  - `CloseDecisionTests` was skipped, because an earlier unbounded run hung there for over 90 minutes.
  - The logs and samples are kept on the Lane B machine.
  - **Cause:** existing tests read the real login Keychain. Default `ChatGPTAccounts` credential loading,
    and `closeProject` reaching the stored Hugging Face token through `KeychainStore.read`, both do this.
  - For a test binary built from a new worktree path, macOS blocks that read behind an access prompt. The
    samples show both reads waiting in `SecItemCopyMatching`.
  - CI has no Keychain items, so CI runs the complete suite.
  - W0 changes no app code. It's a pre-existing test-isolation gap, and worth a separate fix: tests should
    inject a memory secret store.
- `swift test --package-path PrevisCore` passes; the package has no tests yet.
- `swift run shots-export` prints "not implemented yet" and exits with code 2, until B0.
- From `app/`: `mise exec -- swiftlint lint --strict` and
  `mise exec -- swiftformat Sources Tests PrevisCore/Sources PrevisCore/Tests --lint` are clean.

## Merging

**During the four-lane build, every checkpoint merge, Lane B's included, waits for the parent integrator's approval.** Green CI and review receipts make a PR ready to land; they don't approve it.

Lane B lands its own checkpoint PRs, from W0 on, with merge commits once CI is green. It does so under the
owner's standing authorization to this seat to merge green PRs in this repository without asking. That
authorization doesn't extend to other seats. Other lanes' PRs are landed by a seat whose own delegation
allows merging, or by the parent integrator. Lane B merges another lane's PR only when the parent
integrator or the owner asks.

## Notes for other lanes

- **Ownership grant (2026-10-26):** Lane C owns the Shots save seam in `AppLifetime.swift`. That is: flush before approving quit and window close, where a failed save vetoes it; propagate a `releaseProject` save failure through `carryOut`; and keep the GPU and caption confirmations. No other lane owns that file. Recorded in CONTRACTS sections 2 and 8.1.

- **One-time exception (2026-10-26), A0 #52, sample guide frames.** The integration owner (Ari) may add one commit to A0 #52, with these two lines and nothing else:
  - `ShotsSamples.twoPersonWalk` sets `guideFrames = [small ? 11 : 61]`, as CONTRACTS section 5 already specifies;
  - `SampleEvaluationTests.samplesProjectInsideTheCanvas` gains the matching expectation.

  **Why:** review r4375506737 found the code gave `[62]` for the full sample. Lane A's owner can't act, and the contract is right, so the code moves to it, not the contract to the code.

  **Verified by Lane B on A0's head `505064c`:** the patch applies cleanly. The expectation alone fails for the full sample (62 against 61), and with the fix all four core tests pass.

  **Limits:** Gnomon's commits stay as they are. Lane A keeps ownership of both files. The exception covers only these two lines, and the merge still needs independent current-head review and fresh CI.
- **Lane A:** your package is `app/PrevisCore`. Replace `Sources/PrevisCore/PrevisCore.swift` and
  `Tests/PrevisCoreTests/PrevisCoreTests.swift` freely, and add your resources beside `LICENSE` and
  `NOTICE` in `Sources/PrevisCore/Resources/`.
- **Lane A's owner** is Gnomon, the single owner, per lane coordination on 2026-10-26.
- **Lane A's machine** is agent-cx53: Ubuntu 24.04 on x86_64, with Bun 1.3.14 and, since 2026-10-26, the
  official **Swift 6.3.3** toolchain. Swift is installed for the hive user and called by its explicit path;
  it isn't on the default path. It matches CI's Swift 6.3. The compiler blocker is resolved.
- **Lane D's machine.** The viewport lane needs macOS with Xcode and RealityKit. Lane B doesn't know
  Metis's project or conversation target.
- **C0** needs W0, A0 and B0, in that order.
- **Lane D, RealityKit on macOS 27:** RealityKit there culls entities that an earlier render found hidden, so right after a camera cut
  an entity can be missing for a frame. `ShotFrameRenderer` turns culling off, so export and the look-through image are unaffected. A
  live `RealityView` that shares `PrevisSceneMapper` can show a one-frame pop after a cut; set
  `OcclusionCullingComponent(isEnabled: false)` on its root if that matters. The component exists only in the macOS 27 SDK.

## Open questions

- **IT1's CI cost (Lane B, B3): a correction.** Earlier this file read B2's 89 s clean-video test as about 4 s per frame on CI.
  - That was wrong. Per-test times in the CI log include waiting for the main actor behind other suites: B2's writer test, which
    renders nothing, also showed 25.7 s.
  - At `2286487`, the whole app test run, every render test included, took 67 s, and the `swift test` step took 127 s of the
    300 s watchdog.
  - B3's first CI run is the first with IT1 (a full 124-frame export, kept as specified) and gives its real cost.

- Where does Lane D run? It needs macOS with Xcode and RealityKit.
