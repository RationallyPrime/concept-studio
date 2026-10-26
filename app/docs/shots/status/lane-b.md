# Lane B status

| Checkpoint | State |
|---|---|
| W0 wiring | **Draft PR: [RationallyPrime/concept-studio#51](https://github.com/RationallyPrime/concept-studio/pull/51).** It adds the standalone `app/PrevisCore` package (placeholder source, LICENSE and NOTICE bundled), the app targets `ShotsMedia`, `ShotsExportTool` and `ShotsMediaTests` with placeholders, a CI step for PrevisCore's tests, lint and format paths, the preview script copying PrevisCore, and the bun pin. Still open: CI's complete suite green, the preview-script check, and checkpoint integration approval. |
| B0 API skeleton | Next, as soon as A0 is on `main` |
| B1–B7 | Not started |

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

Lane B lands its own checkpoint PRs, from W0 on, with merge commits once CI is green. It does so under the
owner's standing authorization to this seat to merge green PRs in this repository without asking. That
authorization doesn't extend to other seats. Other lanes' PRs are landed by a seat whose own delegation
allows merging, or by the parent integrator. Lane B merges another lane's PR only when the parent
integrator or the owner asks.

## Notes for other lanes

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
