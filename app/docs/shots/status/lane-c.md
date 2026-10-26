# Lane C status

Owner: Ari (Codex). Canonical branch: `shots/c-shell`.

## Checkpoints

| Checkpoint | State | Remaining work |
| --- | --- | --- |
| C0: API skeleton | Accepted and merged, PR #53 (`84de1758`) | Signed quit/window walkthrough remains integration evidence. |
| C1: workspace entry | Implemented; acceptance pending | Current-main CI and independent review closure. |
| C2: commands, persistence and undo | Isolated preparation | Full command/focus/menu coverage and C1 acceptance. |
| C3: lists, import and export | Pending | B3 exporter and real A3 bodies/keypoints; IT3. |
| C4: timeline | Geometry preparation | Timeline UI, playback timer, focus and keyboard handling. |
| C5: inspectors, library and prompt | Pending | A4 generators, A5 corrections, B5 prompt. |
| C6: polish | Proposal only | Integrated previews, glossary/credits and keyboard walkthrough. |

## C0 delivered

The store, evaluator/frame access, selection/tool/command seams, preview/commit, snapshot undo/redo,
coalescing, debounced atomic saving and corruption/future-version handling are integrated. Project
release, quit and window close flush first and veto saving failures. Prompt writes preserve blocking
revision semantics. The real B2 self-test is integrated. W0, A0, B0, C0, B1, B2, A1 and A2 are merged.
C0 independent closure and all seven checks passed before merge; 14 focused local tests passed.

## C1 preparation

- Shots entry beside Cloud GPU, plus Go > Shots (Command-0); existing nine training shortcuts and order
  retained. Returning to Training restores the previous step; explicit training destinations select it.
- Four regions: scene/shot list with starter asset names below, actual `ShotsViewport(store:)` and
  `ShotCameraView(store:)` switched by a picker, read-only shot inspector, and a playhead slider.
- Native scene creation goes through `store.run`. Selection clears preview and entity selection.
- Training viewer/definitions and training navigation remain scoped to the training workspace.
- Actual root previews gain shots-empty and shots-sample in both appearances and sizes.

These are C1 surfaces only. Library placement, full inspectors, timeline playback, export and prompt
writing are later checkpoints. D0 PR #61 merged as `42871fbd`; no C1 acceptance is claimed yet.

## Verification

Initial isolated validation used main `93dbb764` plus published D0 and C1 sources. The current C1
branch has been retargeted to main after D0 PR #61 landed as `42871fbd`. All five C1 patches
rebased unchanged (`=` range proof). No replacement viewport implementation was used.

- **Run and passed:** native SwiftPM `--filter 'Shots|Viewport'` on the actual published D0 base:
  31 tests in nine suites. Includes
  workspace entry/return and explicit training destination coverage, close/save, store and viewport math.
- **Run and passed:** changed-file strict SwiftLint and pinned SwiftFormat, plus whitespace checks.
- **Run and passed:** `CONCEPTSTUDIO_PREVIEW_SCREENS=shots-empty,shots-sample scripts/render-app-preview.sh`
  wrote eight PNGs: empty/sample × light/dark × 980×680/1240×820. One preview test passed.
- **Inspected:** both layouts fit the minimum size. The original dark-mode D0 contrast finding was routed to Metis in PR #61 comment 6415450470.
  A new eight-PNG run with his committed repair confirms readable viewport text in both appearances.
  The shot-list title now explicitly uses semantic primary text; another eight-PNG run confirms
  readable dark-mode titles. Inactive native list-symbol rendering still needs the live/C6 walkthrough.
  D0 publication, independent acceptance and CI remain separate gates.
- **Not run locally:** complete app suite, signed/live interaction and keyboard/VoiceOver walkthrough.
  Offscreen captures do not prove pointer, focus, accessibility or RealityKit live behavior.
- **Pending:** verification repeated against landed D0/current main, C1 independent review and CI.

Isolated C2 command preparation and timeline geometry tests remain outside this checkpoint. They are
not evidence that C2/C4 acceptance is complete.

## Coordination and integration

Gnomon owns A, local Claude owns B, Ari owns C/integration, Metis owns D. Metis's dedicated Antigravity
conversation is active on `shots/d-viewport`; D1 preparation is separate. A2 is merged; A3 remains the
core dependency for B3/D2. Preserve owner branches and worktrees.

The user explicitly approved Shots checkpoint merges after required review/green CI and repeated
verification after rebasing. Use non-squash merges per CONTRACTS and verify authoritative live main,
not stale PR base metadata. This excludes release/deployment and paid infrastructure.

## Product proposal

The existing proposal remains for owner review before editing PRODUCT.md: Shots prepares scene,
motion, virtual camera, guide images/control videos/masks/shot details and an H3 prompt for ComfyUI.
No PRODUCT.md change or C6 acceptance is claimed.
