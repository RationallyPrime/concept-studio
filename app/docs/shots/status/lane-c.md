# Lane C status

Owner: Ari (Codex). Canonical branch: `shots/c-shell`.

## Checkpoints

| Checkpoint | State | Remaining work |
| --- | --- | --- |
| C0: API skeleton | Partial, compiled and tested | B0 supplies `ShotsSelfTest`; wire and verify `--shots-self-test` before C0 is complete. |
| C1: workspace entry | Pending | C0 and D0; sidebar/menu entry and hosting both viewport views. |
| C2: commands, persistence and undo | Partial | Remaining command implementations, focused menu undo, tolerant decoding from A1, full acceptance. |
| C3: lists, import and export | Pending | A1 importer and B3 exporter; IT3. |
| C4: timeline | Pending | Timeline UI, playback timer, focus and keyboard handling. |
| C5: inspectors, library and prompt | Pending | A1 catalog, A4 generators, A5 corrections and B5 prompt. |
| C6: polish | Pending | Integrated C/D workspace, glossary/credits, previews and keyboard walkthrough. |

## Delivered in this branch

- Independent `StudioWorkspace` state defaults to training and preserves the training step.
- Contract command, selection and tool types; the observable store starts at the first scene/shot.
- Evaluator caching and frame access, preview-then-commit behavior, error routing and read-only mode.
- Scene/entity/shot/mark edits, revision changes, snapshot undo/redo (200 entries), explicit slider
  coalescing and debounced atomic saving. Unsupported commands report `ShotsError.notImplemented`.
- Project/demo opening creates or loads the store. The demo starts with the sample.
- Project release flushes before access ends and releases the store. A failed flush keeps the project
  and edits open. App termination receives a flush hook; signed quit behavior is not yet verified.
- Corrupt files are renamed aside with their bytes preserved; newer versions remain untouched/read-only.
- Prompt writes do not bump the blocking revision or immediately make their own prompt stale.

No Shots UI, export action, prompt-writing action or self-test launch flag is claimed yet.

## Dependencies and coordination

The branch is stacked on published A0 draft PR #52 (`8c7815f`), which is stacked on W0 PR #51
(`f1c3d51`). Those are actual owner artifacts, not replacement implementations. Neither dependency is
assumed merged. Rebase onto main and rerun the affected checks after the dependency stack lands.

- Gnomon is the single A owner. His existing native session acknowledged the handoff, replaced his
  temporary scaffold with W0's real files, reran four Linux package tests and pushed draft PR #52.
- W0's latest head has green CI. The owner reports an inherited local Keychain hang separately; that
  partial local run is not a full-suite pass. Current-head review and preview evidence remain gates.
- A0's first macOS CI ran 769 app tests and four core tests successfully, then failed six core lint
  violations. Gnomon repaired those at `8c7815f`; C rebased onto that head and reran its focused tests
  (11 passed) and the complete app strict lint gate (passed). A0 macOS CI on the repair is pending.
- The B owner will prepare B0 after A0's dependency is resolved. C needs its real self-test API.
- Metis's project/conversation target remains with the parent/user. C has not sent to an ambiguous target.

## Verification

From the repository root:

```sh
.github/scripts/swift-test-watchdog.sh --package-path app --build-system native \
  --filter 'ShotsWorkspaceTests|ShotsStoreTests|ShotsDocumentFileTests'
```

Passed on local Swift 6.4 against the actual W0/A0 sources: **11 tests in three suites**. The navigation
case covers all three legal steps of a concept-free project. Coverage includes:

- opening an empty project, switching workspace, accessing frame 61, saving, releasing and reopening;
- refusing project release when a Shots save fails, retaining edits, then saving successfully on retry;
- preview, commit, undo and redo, including observable undo availability;
- explicit coalescing versus ordinary separate undo steps;
- prompt/blocking revision behavior;
- corruption preservation, future versions and sample round trips; no writes to training files.

The earlier isolated consumer harness passed eight tests against Gnomon's initial `876dfae` draft.
Those harness results are superseded by the real-app focused run above. An initial store draft crashed
because an observable playhead observer called itself; clamping now uses a separate backing value and
all tests passed on rerun.

Passed: changed-file SwiftFormat and SwiftLint with the repository's pinned versions, plus whitespace
checks. The combined app strict lint gate also passed after rebasing onto Gnomon's A0 repair.
Not run for this branch: complete app suite, CI, preview renders, media export and signed sandbox checks.

Draft PR: https://github.com/RationallyPrime/concept-studio/pull/53 (incomplete C0, stacked on A0).

## Merge boundary

CONTRACTS section 1 requires one checkpoint PR, green CI on the current main base, and rebase/merge
commits rather than squash. Lane B reports standing owner authorization for its own PRs; it does not
transfer to C. Parent is seeking explicit checkpoint integration permission. C has merged nothing.

## Product paragraph proposal

For owner review before editing PRODUCT.md:

> ConceptStudio also prepares assets for video shots made in ComfyUI. In the Shots workspace, the user
> places people and simple set pieces, marks their movement, and frames a virtual camera. It exports
> guide images, pose and layout control videos, actor masks, shot details and an H3 prompt as a folder
> the user carries into their ComfyUI graph.

This proposal does not change PRODUCT.md or claim approval.
