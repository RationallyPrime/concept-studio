# Lane B status

| Checkpoint | State |
|---|---|
| W0 wiring | **Draft PR [RationallyPrime/concept-studio#51](https://github.com/RationallyPrime/concept-studio/pull/51)**, head `f1c3d51`. All seven CI jobs pass. **Independent clearance:** Codex reviewed the current head `f1c3d51` and found no major issues (it had earlier reviewed `4782eba` with no findings). Lane B's own checks are author verification. Still open: checkpoint integration approval. |
| B0 API skeleton | **Draft PR [RationallyPrime/concept-studio#54](https://github.com/RationallyPrime/concept-studio/pull/54), stacked on A0 (#52).** Every CONTRACTS section 6 declaration and the section 8.3 package types compile against A0's real PrevisCore. `ShotsCommandLine` prints usage, and `shots-export` exits with code 2. `ShotsSelfTest.run()` prints a JSON report and returns 1 until B2. `PackageValidator` reports "not implemented" rather than "valid". Unimplemented work throws `ShotsError.notImplemented`. Build and both linters are clean (author verification). All seven CI jobs pass on `41199e5`. Lane C's C0 builds on this head; that is consumer integration, not code review. No independent code review yet. |
| B1 scene mapper and frame renderer | **Draft PR [RationallyPrime/concept-studio#55](https://github.com/RationallyPrime/concept-studio/pull/55), stacked on B0 (#54).** `PrevisSceneMapper` gives one container per entity, parts keyed by id, meshes cached by shape (capsules are a cylinder plus two spheres; wedges are a flat-shaded custom mesh), materials cached by colour, and a ground plane with a three-light rig per preset. `ShotFrameRenderer` renders offscreen with `RealityRenderer`, zero time step, 4× multisampling and no tone mapping, into IOSurface buffers through `.bgra8Unorm_srgb`. It takes the `size` and `overlay` options. Render tests on the small sample pass locally: every entity is drawn where it projects, markers land within 0.5 px of `CameraFrame.project`, a wedge shows its outside faces, and a frame renders identical bytes after other frames and looks. Those local passes are author verification. Lane C reran the four render tests at `69a814d`: package test verification, not code-review clearance. No independent code review yet. **Lane B's open gate:** the macOS CI log must show the render suite executed, not skipped. |
| B2 video writer and self-test | In progress on `shots/b-media-b2`. |
| B3–B7 | Not started |

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

## Open questions

- Where does Lane D run? It needs macOS with Xcode and RealityKit.
