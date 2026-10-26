# Lane B status

This file travels at the top of each Lane B checkpoint (now B4's `shots/b-media-b4`, with B5 stacked on it), so checkpoints that have passed review keep their exact heads.

| Checkpoint | State |
|---|---|
| W0 wiring | **Landed on `main`** as merge commit `ff2cce2`, by the integration owner, from head `42de04a`, with the branch preserved. Codex cleared `f1c3d51` and `42de04a`, and all seven CI jobs passed at `42de04a`. |
| B0 API skeleton | **Landed on `main`** as merge commit `54c2cfa`, by the integration owner. Lane B rebased B0's three commits onto `main` at A0's merge `de3947b` (range-diff identical, head `d8e39dc`) and retargeted the PR to `main`. Codex found no major issues (receipt comment 6412721881), and CI run 40299557718 passed all seven jobs. |
| B1 scene mapper and frame renderer | **Landed on `main`** as merge commit `f41b245`, by the integration owner. Lane B refreshed it onto C0's merge `84de175` (four patches range-diff identical, head `bf06c59`). Codex's refresh review found no major issues (receipt comment 6413050776), and CI run 40302119860 passed all seven jobs, with the overlap and cancellation regressions. Codex's two earlier P2 findings were fixed in `3bc3a27` and `95b4d27`, both cleared. |
| B2 video writer and self-test | **Landed on `main`** as merge commit `1366c35`, by the integration owner. Lane B refreshed it onto B1's merge `f41b245` (six patches range-diff identical, head `93c24ca`). Codex's refresh review found no major issues (receipt comment 6413289103), and CI run 40303647108 passed all seven jobs, with the sample-video and writer regressions. The signed sandbox `--shots-self-test`, built directly from `93c24ca`, exited 0 with 124 frames at 640 × 1152, avc1, BT.709, in 0.89 s. Codex's P1 and P2 findings were fixed in `0052c3d` and cleared. |
| B3 passes, package and sample CLI | **Landed on `main`** as merge commit `f13b41b`, by the integration owner, from head `a386dd7` ([RationallyPrime/concept-studio#58](https://github.com/RationallyPrime/concept-studio/pull/58)).
- **Refresh `c7490c2`:** B3's nine patches replay range-diff identical onto `main`, where A3 landed as `783d3e4`. CI run 40380453809 passed all seven jobs, and IT1 ran on the runner (107 s).
- **Audit repair `a386dd7`:**
  - mattes render without antialiasing, as this lane's plan says;
  - every video entry carries `frameCount`, per CONTRACTS section 8.3, and the validator reports an entry without it;
  - each part fails its own test when undone.
- **Gates on `a386dd7`:** IT1 checks 99 real keypoints; ShotsMedia passes 20 tests in three runs; the app passes 826; PrevisCore passes 40; the export is valid; lint is clean. CI run 40382518501 passed all seven jobs (`swift test` 208 s).
- **Review:** Codex's clean review of `a5ed194` (6416764322) covers the nine unchanged patches; the integrator accepted `a386dd7`.

**What's built:**
- **Pose:** in DWPose style.
- **Layout:** boxes over each actor.
- **Mattes:** each actor white, everything else black, with no antialiasing.
- **Guide stills:** taken from the video pixels.
- **`shot.json` and the manifest,** plus the validator.
- **Staged export,** with cleanup on error or cancellation.
- **CLI:** `shots-export --sample`.

**Blockout reference:** the comparison is in #58's description and below. |
| B3 media-reader repair | **Landed on `main`** as merge commit `7fce98d`, by the integration owner, from head `609869f` ([RationallyPrime/concept-studio#74](https://github.com/RationallyPrime/concept-studio/pull/74)).
- **The hang:** CI hung in C3's IT3 inside the exporter. `VideoInspector` read samples with `AVAssetReader` on Swift's cooperative threads; with as many concurrent reads as the pool has threads (three on the CI runner), every read held a thread and none returned.
- **The fix:** reads run on their own serial queue, with cancellation, as `MediaEditor` already does for the app's clips. A regression test runs more concurrent reads than the machine has cores.
- **Evidence:** the hang reproduced locally with 12 concurrent reads on a 10-core Mac, and the old reader fails the regression test. The integrator's independent bounded review accepted `609869f` (comment 6427452923); CI run 40400625215 passed. IT3 and reader saturation then passed on fresh C3 and C4 CI. |
| B4 Blockout and document input, IT2 | **Draft PR [RationallyPrime/concept-studio#78](https://github.com/RationallyPrime/concept-studio/pull/78), on `main` at `c23dea8`: code head `70d588a`, with this status commit on top.**
- **Restack:** B4's two commits replay patch-identical onto `main` (range-diff `=`: `ce66dfb` → `35485a6`, `c7b6717` → `a4249ea`). The old status commits are dropped; this file is the one status commit on top.
- **Since the restack:**
  - `dd1fc52`: an export with `--passes clean` validates with the clean pass alone, as the plan's B4 verify list asks.
  - `70d588a`: a test now pins Blockout's default, the first scene's first shot (`src/renderer/store.ts:233-239`). Exporting the last shot used to pass the suite. The test also covers `--scene` by index and by id.
  - `70d588a`: `--canvas` needs exactly two numbers; `640xabcx1152` was accepted as 640 × 1152.

**Built:**
- `--document <shots.json> --shot <id>`;
- `--blockout` with `--scene`, `--shot`, `--frames`, `--canvas` and `--passes`;
- every option checked before anything is read: a usage error exits 2, a failed export exits 1;
- Blockout input keeps the project's own ids, so `--scene` and `--shot` match the ids in the file;
- a shot name that two shots share is refused;
- with no `--shot`, the first shot is exported, as Blockout opens a scene (`src/renderer/store.ts:233-239`).

**IT2 passes.** Blockout's sample goes through `BlockoutImport` and the exporter, and also through `--blockout --frames 22 --canvas 320x576`. Both packages are valid with every pass.

**Blockout reference:** Blockout has no headless export, so only scene and shot choice and ids have an equivalent, and both follow it. **Intentional differences:**
- `--scene <index>` counts from 0, as the error message says, while Blockout shows scenes by number from 1.
- Entities Blockout leaves out of every export (`excludeFromExport`) are exported; see the open questions.

**Author verification on `70d588a`:** ShotsMedia passes 26 tests in three runs; the app passes 852 and PrevisCore 148; both linters are clean; the release build of `shots-export` succeeds, and `--sample` writes a valid package. Eight inverse checks each fail their test: the shared-name refusal, project ids, `--frames`, `--passes`, the first shot, the first scene, the scene index and strict `--canvas`.

**Author review** (not an independent review): three lenses raised 13 candidate findings, some overlapping.
- **Refuted:** the six most severe were each checked adversarially, and all six were refuted as defects:
  - the twin-name test not proving why the export was refused;
  - no test for `--scene` (tested now anyway);
  - `--document` not running document validation, which the app's own export doesn't run either;
  - `excludeFromExport`, an open question;
  - generic decoding errors;
  - `--scene` counting from 0.
- **Fixed in `70d588a`:** of the seven low findings left unchecked, three:
  - the scene and shot test;
  - strict `--canvas`;
  - the by-id export's shot and frame count.
- **Left as they are:**
  - the format-version guard runs after a full decode;
  - no test reads the printed path.

**Open:**
- `excludeFromExport` (see the open questions);
- camera-mark stills as guide frames.

**M1** (owner-run, outside CI): with B4, `swift run -c release shots-export --blockout <file> --out <dir>` exports a Blockout project for ComfyUI. The release build of `shots-export` succeeds on `70d588a`. |
| B5 prompt | **On `shots/b-media-b5`, reworked after the Blockout audit, being restacked onto this B4 head.** Its own draft PR follows, stacked on B4, with its Blockout sources, differences and gates in its row there. |
| B6–B7 | Not started |

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

Ari, the integration owner, lands Shots checkpoints. She lands them in dependency order, with merge commits, after review, green CI and verification after each rebase, under the owner's approval. Lane B does not merge Shots PRs. It rebases its own branches when handed a base, pushes with exact leases, and posts its evidence. Review requests are Ari's.

## Notes for other lanes

- **Turn timing for A5 (plan-maintainer record, 2026-10-26, [#67 comment 6424533971](https://github.com/RationallyPrime/concept-studio/pull/67#issuecomment-6424533971)):** an authored turn finishes on arrival at its mark.
  - It blends over the leg that arrives at the mark, from the facing at departure. The mark's own `hold` keeps the facing it arrived with, as Blockout does.
  - "The hold before its mark" in LANE-A-CORE.md means standing still before the mark (a leg between marks on one spot). It does not mean `Mark.hold`, which is the stay after a mark.
  - The comment has the evidence, from Blockout `3f2d056` and the `actors-paths-ease-hold` fixture, and a discriminating example with numbers. A turn after arrival is not accepted.
  - A5's PR carries the replacement bullet for LANE-A-CORE.md.
- **A4's in-motion facing (plan-maintainer disposition, 2026-10-26, [#67 comment 6424525478](https://github.com/RationallyPrime/concept-studio/pull/67#issuecomment-6424525478)):** A4 can land with the facing during a motion explicitly inherited by A5, as defect 1. Do not front-load the fix.
  - The generator part is fixed at `5e66777`, matching Blockout's `playMotion` (`choreography.ts:213`).
  - The evaluator's fallback on a stationary leg is Blockout's (`evaluate.ts:122-139`, `281-284`, `375-383`).
  - Conditions: the known-issue test stays, `lane-a.md` keeps naming the defect, and A5's acceptance requires a plain assertion.
- **Joint signs ([RationallyPrime/concept-studio#69](https://github.com/RationallyPrime/concept-studio/pull/69), draft `[contract]`, `43aad5a`):** CONTRACTS section 4 lists what a positive stored value of each of the 18 joints does.
  - Sources: Blockout's sign header (`src/engine/motions.ts:13-33`) and A3's measured rig. LANE-A-CORE.md's X sentence is restated in stored values.
  - Additive, with no API change. It follows from the A3 Z-override disposition on #65 (positive Z abducts outward, now landed). `torsoY` follows the header, the geometry and the rig: positive turns counter-clockwise seen from above, toward the character's left. Most of Blockout's keyframe comments call a positive value "twist right"; that question stays open, as `lane-a.md` records.
- **Blockout as the reference (owner's direction, 2026-10-26 18:32 UTC):** before implementing a feature, read the matching Blockout source and tests at `3f2d056` (`scripts/blockout/fetch.sh`), read only. Reuse its behaviour, algorithms, data semantics and interaction design. Differ only where Swift/macOS architecture or an explicit plan decision requires, and record source paths and deviations in checkpoint notes.
  - **B3:** audited; the table is in #58.
  - **B4:** audited. It matches Blockout where Blockout has an equivalent; Blockout has no headless export.
  - **B5:** reworked on its branch; its row and PR record the Blockout sources and differences.
  - **Oracles Blockout offers Lane B:**
    - `tests/unit/camera-moves.test.ts` (B5, after A4);
    - `tests/unit/audit-fixes.test.ts:88-108` (hold truncation);
    - `tests/unit/tracking.test.ts:26-60` (aim lock);
    - `tests/e2e/smoke.spec.ts:114-130` (same frame, same bytes);
    - `tests/e2e/cancel-export.spec.ts:31-71` (cancellation).

- **Refresh rehearsal (2026-10-26):** in a throwaway worktree, all 18 commits from B1 to B3 replay onto B0's `d8e39dc` with range-diff identical patches. The result builds and passes the ShotsMedia and PrevisCore tests, so each refresh should be mechanical.

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

- **`excludeFromExport` (for Lane A and the integrator).**
  - **The gap:** Blockout hides an entity marked `excludeFromExport` in every export pass, while keeping it in the editor (`src/engine/types.ts:101-102`, `SceneManager.ts:2386-2392`). A1's import keeps such entities and drops only the flag, with a note (`BlockoutImport.swift:153`). So a Blockout project's editor-only stand-ins show up in clean, block mattes, and get skeletons and boxes.
  - **Options:**
    - leave them out at import. That is simple, but they vanish from the Shots editor too.
    - an optional entity flag through the `[contract]` route, which the exporter skips. That keeps Blockout's meaning, but expands the API.
  - **Lane B's recommendation:** the flag. The choice is the integrator's and owner's.
- **Shadows (Lane B follow-up or a decision).** Blockout's export casts shadows (`builders.ts:65-73`, `exporter.ts:78-79`). Our renderer has none, so clean guides lose ground contact. No plan line decides this.
- **Top-down still.** Blockout exports a top-down diagram with its stills. It isn't in CONTRACTS section 8.3; the owner decides whether packages should carry one.

- **CI budget (for the integrator).**
  - **The correction:** earlier this file read B2's 89 s clean-video test as about 4 s per frame on CI. That was wrong. Per-test
    times include waiting for the main actor: B2's writer test, which renders nothing, also showed 25.7 s.
  - **Measured with IT1:** across B3's runs, the app's `swift test` step took 224 s, 244 s, 136 s and, on `main` at `c7490c2`,
    228 s of its 300 s watchdog, varying by runner, with about 70 s of that building tests.
  - **What's still coming:** about a minute of headroom remains, and Lane A's real evaluator, IT2 and other lanes' tests are
    ahead.
  - **Options:**
    - run `ShotsMediaTests` as its own CI step, with its own watchdog, skipped from the app step;
    - raise the app step's limit.
    Both change shared CI configuration, so Lane B proposes and doesn't pick.

- Where does Lane D run? It needs macOS with Xcode and RealityKit.
