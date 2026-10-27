# Lane C status

Owner: Ari (Codex). Integration preparation: `shots/c6-b5-integration` (C5 preserved on `shots/c5-b5-integration`); published C5/C6 drafts #76/#77 remain preserved.

## Checkpoints

| Checkpoint | State | Remaining work |
| --- | --- | --- |
| C0: API skeleton | Accepted and merged, PR #53 (`84de1758`) | Signed quit/window walkthrough remains integration evidence. |
| C1: workspace entry | Accepted and merged, PR #66 (`08cfd92`) | Live/signed keyboard and VoiceOver remain integration evidence. |
| C2: commands, persistence and undo | Accepted and merged, PR #68 (`bf9ab74`) | Live keyboard/VoiceOver remains manual integration coverage. |
| C3: lists, import and export | Accepted and merged, PR #70 (`427d185`) | Native walkthrough remains integration evidence. |
| C4: timeline | Accepted and merged, PR #71 (`ec2cb5a`) | Native focus/keyboard walkthrough remains integration evidence. |
| C5: inspectors, library and prompt | Draft PR #76; real B5 endpoint integration locally verified | B5 repair/acceptance, fresh final composition review/CI and native acceptance. |
| C6: polish | Draft PR #77, stacked on C5 | Accepted dependencies, final composition and native keyboard/VoiceOver walkthrough. |

### C5/B5 integration preparation (2026-10-27)

Composed C5 `4fda2b5` with published B5 #79 `3679ad7` in an isolated worktree. The prompt boundary test now uses
the actual `ShotPromptCompiler.facts` and `write` through `ResolvedEndpoint` and a fake `ModelClient`; no provider
is contacted. It checks the facts received by the client, exact FL2VA header/sections, stored revision/model,
unchanged scene revision and a single Undo. Stale-result and cancellation checks also use the real facts path.

Local verification: four inspector boundary tests pass; full app suite reports 918 tests/153 suites passing;
PrevisCore reports 148/20 passing; strict lint and full formatting pass. Optional model/preview and Blockout
vector tests skip without their opt-in inputs; no known-issue result is accepted. Existing source-aligned C5
previews are unchanged. This is preparation against an explicitly unaccepted B5 draft: its open camera-reading
findings remain with Lane B, and this evidence must be refreshed on the eventual accepted composition.
Native UI, keyboard/VoiceOver, M1 ComfyUI and M2 walkthrough acceptance are not established by these tests.

## C0 delivered

The store, evaluator/frame access, selection/tool/command seams, preview/commit, snapshot undo/redo,
coalescing, debounced atomic saving and corruption/future-version handling are integrated. Project
release, quit and window close flush first and veto saving failures. Prompt writes preserve blocking
revision semantics. The real B2 self-test is integrated. W0, A0, B0, C0, B1, B2, A1 and A2 are merged.
C0 independent closure and all seven checks passed before merge; 14 focused local tests passed.

## C1 delivered

- Shots entry beside Cloud GPU, plus Go > Shots (Command-0); existing nine training shortcuts and order
  retained. Returning to Training restores the previous step; explicit training destinations select it.
- Four regions: scene/shot list with starter asset names below, actual `ShotsViewport(store:)` and
  `ShotCameraView(store:)` switched by a picker, read-only shot inspector, and a playhead slider.
- Native scene creation goes through `store.run`. Selection clears preview and entity selection.
- Training viewer/definitions and training navigation remain scoped to the training workspace.
- Actual root previews gain shots-empty and shots-sample in both appearances and sizes.

These are C1 surfaces only. Library placement, full inspectors, timeline playback, export and prompt
writing are later checkpoints. D0 PR #61 merged as `42871fbd`; A3 merged as `0bdb09a`.
C1 PR #66 merged as `08cfd92` after exact-head green CI and supplemental independent acceptance
[6418110709](https://github.com/RationallyPrime/concept-studio/pull/66#issuecomment-6418110709).
The old external closure remains untouched; its terminal result was not claimed.

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
  D0 subsequently passed independent acceptance/CI and landed separately.
- **Not run locally:** complete app suite, signed/live interaction and keyboard/VoiceOver walkthrough.
  Offscreen captures do not prove pointer, focus, accessibility or RealityKit live behavior.
- **Run and passed after landed A3/D0:** native 31 tests/nine suites; exact-head C1 CI
  `40331000428`, all seven jobs. Separate independent reviewer inspected actual code/tests/captures,
  ran fresh 12 tests/three suites and 21 tests/six suites, and accepted the frame-label/compiler cures.
  No specific-provider terminal requirement was found; the original provider status stayed disclosed.

Isolated C2 command preparation and timeline geometry tests remain outside this checkpoint. They are
not evidence that C2/C4 acceptance is complete.

## Coordination and integration

Gnomon owns A, local Claude owns B, Ari owns C/integration, Metis owns D. Metis's dedicated Antigravity
conversation is bound to `shots/d-viewport`; D1 preparation is separate. A3 is merged; B3/D1 owner
refresh requests remain unacknowledged. A4 has a separate heading hold. Preserve owner branches/worktrees.

The user explicitly approved Shots checkpoint merges after required review/green CI and repeated
verification after rebasing. Use non-squash merges per CONTRACTS and verify authoritative live main,
not stale PR base metadata. This excludes release/deployment and paid infrastructure.

## Product proposal

The existing proposal remains for owner review before editing PRODUCT.md: Shots prepares scene,
motion, virtual camera, guide images/control videos/masks/shot details and an H3 prompt for ComfyUI.
No PRODUCT.md change or C6 acceptance is claimed.

## C2 review preparation (`shots/c-commands`)

Based on actually merged C1 PR #66, main `08cfd92d432492a048b75c39f14ea46675b9d5d5`.
Both C2 preparation commits replay unchanged (`=` range-diff). C2 subsequently passed independent acceptance and exact-head CI and merged; see the landing record below.

- Extends the single document command entry with duplicate/import, camera settings, mark deletion and
  entity-reference cleanup. Duplicate camera-mark identifiers derive deterministically from the supplied
  new shot identifier; duplicates are refused before mutation.
- Generator commands call actual PrevisCore declarations. Until A4 lands, their errors propagate without
  committing document/history changes; no Lane A math is reimplemented.
- Adds a removable native responder for standard Edit-menu Undo/Redo while the workspace is mounted.
  Text editing uses its own UndoManager; the bridge restores the previous chain when dismantled and
  handles overlapping SwiftUI view replacement. It does not replace the app's Edit commands.
- Adds command, history-cap, debounced-save, invalid-preview and native routing tests.

**Run and passed:** post-C1-main native SwiftPM `--filter 'Shots|Viewport'`: 45 tests in 12 suites.
Includes the actual StudioSession scenario: scene, two entities, three actor marks, camera mark,
undo twice/redo once, release/reopen, equal document. Pinned formatting and strict lint passed
on all seven changed Swift files. The four native
routing tests include real SwiftUI background mounting, document actions, text-editing priority and
responder cleanup. These are headless in-process tests, not a live Cmd-Z/VoiceOver walkthrough.

**CI:** first Swift 6.3 run `40337781017` failed during build: identifier collection was too complex
for that compiler to type-check. The repair uses explicit collection steps with unchanged ordering.
The compiler repair built successfully in CI `40338602319`, but its 816-test app run failed
the debounce persistence test. Under main-actor contention the test's three-second wall-clock
deadline expired before the saver could resume. A controlled 3.2-second actor stall reproduced
the missing-file/empty-document failure; polling opportunities instead of wall time passed
under the same stall. The injected stall is not committed, production debounce/save code and
CI watchdog are unchanged, and file existence plus full document equality remain required.
Post-repair: 45 focused tests/12 suites passed; core run passed with oracle parity explicitly
skipped; full strict lint and pinned formatting passed. Fresh CI `40367485595` passed all seven jobs, including the complete app/core, lint and formatting gates.

**Not run:** complete local app suite, live menu/keyboard/VoiceOver and signed integration.
The foreground walkthrough is deferred while the user works on a time-sensitive grant form.
The live walkthrough remains manual integration coverage; the actual C2 Verify section does not
make it a separate checkpoint gate. No live keyboard/VoiceOver or M1/M2 claim is made.


## C2 accepted and C3 preparation

C2 PR #68 head `1c46f1932b22051cf6f05196ae1a14f40ed181d1` merged with a merge commit as
`bf9ab743e61bf8bdae19f2c58b619e0b73879701`. All seven CI jobs passed in run `40367485595`;
separate independent acceptance is recorded at
[6422841587](https://github.com/RationallyPrime/concept-studio/pull/68#issuecomment-6422841587),
with landing receipt 6423024829. The original slow provider job remains untouched.

C3 preparation starts from that accepted main in the existing owned worktree, with the C2 branch
preserved. Scene copies allocate new identifiers and remap internal attachment, blocking, camera and
character-note references. Shot/scene creation, copying and actual Blockout import use the existing
command boundary, select the created content and preserve undo. Invalid imports leave the document,
preview and selection intact. These are model actions, not completed C3 surfaces.

**Run and passed:** native SwiftPM `--filter 'Shots|Viewport'`: 50 tests in 13 suites. Five new scene
and import tests cover graph identity/references, source preservation, selection, undo, real sample
import notes and failed-import atomicity. Four changed Swift files pass strict lint and pinned format.
An initial test fixture assumed the wrong sample entity index; the fixture now records the appended
entity's actual index. The corrected test passes. No production behavior was changed for that fixture.

**Not yet delivered/verified:** complete scene/shot controls and settings, file picker, export progress,
Cancel/reveal, and IT3. B3 must be refreshed and accepted on current main before real export acceptance.
The existing B3 owner request 6417151440 remains unacknowledged; no Lane B exporter is duplicated.


### C3 visible controls and export preparation

Scene menus and shot context menus now offer add, rename, copy and delete. The JSON file picker calls
real Blockout import, scopes file access for the read, and displays import counts and notes. Shot
settings offer frame-grid stepping and seconds/trained-range guidance, canvas presets or custom
32-pixel steps, and lighting. All edits use existing commands. Read-only documents remain navigable.

The export control captures committed scene/shot values (not transient previews or subsequent edits),
flushes pending saves and calls Lane B's declared exporter with `<project>/Shots`, progress, Cancel,
and Finder reveal. The exporter on main is still B0's stub: **working export and IT3 are not claimed**.
No Lane B implementation or contract was replaced.

**Run and passed:** native focused run: 51 tests in 13 suites, including the committed export-snapshot
regression; strict lint on six changed Swift files; pinned formatting. Offscreen preview script passed
one test and produced eight PNGs: empty/sample × light/dark × minimum/default sizes. Minimum-size
light/dark sample captures inspected: the four regions and settings fit. Offscreen RealityKit remains
blank by design; these captures do not prove live keyboard/VoiceOver or native picker interaction.

**Pending:** B3 refresh and acceptance, real export/validator IT3, independent C3 review and exact-head
CI. C2's original provider summary 6418233026 subsequently completed cleanly at `1c46f19` at 17:28 UTC;
the supplemental independent record is retained.


### Reference-first audit and C3 export unblock

Applied Hákon's direction to inspect the original source/tests before further implementation.
Reference remote and full pin verified: `wassermanproductions/blockout` at
`3f2d0564fd575f70fc28e9bfaa7e94b05e3955d9`, checkout `/tmp/shots-blockout-reference-3f2d056`.
Read `src/renderer/panels/ProjectRail.tsx` (shot cloning, rename/delete),
`src/renderer/store.ts` (selection, creation), `src/renderer/panels/Inspector.tsx` (shot settings),
`src/renderer/export/exporter.ts`, and existing interaction/cancellation tests.

- Shot cloning follows ProjectRail's fresh shot/camera-mark IDs, shared blocking and selection of the copy.
- Found a reachable mismatch: selecting a shot retained frame61; `store.ts:330-341` resets time to0.
  The added regression failed on our preimage, the store helper now resets the playhead, and the full
  focused run passes **52 tests/13 suites**. Strict lint and pinned formatting pass on both changed files.
- Intentional plan/architecture adaptations: native menus/alert/file picker instead of React controls;
  empty scenes/projects remain allowed by C0/CONTRACTS instead of Blockout's last-scene/shot refusal;
  scene/shot names use the Shots schema (which has no Blockout scene-number field);
  full scene graph duplication remaps IDs because C3 requires scene duplication;
  H3's explicit frame-grid/canvas rules replace Blockout's duration/aspect controls;
  package rendering stays entirely in Lane B, not an extra export implementation in C.
- Blockout export snapshots and locks its mutable renderer state; C3 captures committed scene/shot
  values for the immutable native export pipeline. Independent later edits cannot change the snapshot.

B3 PR58 is now accepted/merged as `f13b41b7bfefd7ac701923507adf347e180079df` at head`a386dd7`.
Independent bounded acceptance6425352368 covers the audit repairs; all7CI40382518501passed,
including826app/40core and actual matte/manifest/package regressions. B3 export is unblocked for C3.
Next: refresh C3 onto accepted main, run real IT3, independent C3 review and exact-head CI.
No M1/M2, live keyboard/VoiceOver or ComfyUI handoff claim.


### C3 integration candidate on accepted B3

Rebased our three C3 commits onto accepted main`f13b41b7`. Every row of
`git range-diff bf9ab74..shots/c-scenes-pre-b3 origin/main..HEAD` is identical (`=`).
The pre-refresh branch is retained; no owner branch or worktree was discarded.

**IT3 run and passed:** a real temporary concept-free StudioProject opens a ShotsStore, imports the
actual Blockout sample, commits shot edits ending in22frames/320×576/guide11, saves and releases,
reopens with equal document, exports the committed store snapshot via actual ShotExporter into
`<project>/Shots`, and gets zero PackageValidator problems. It also checks output metadata and terminal
progress. The first build caught a missing `try` in the new assertion; that test-only compile error was
corrected before execution. No acceptance condition or production save/export path was weakened.

**Post-rebase run and passed:** native `--filter 'Shots|Viewport'`:63tests/17suites, including real IT3,
B3's full sample package and pixel tests, store/history/save and viewport coverage. Changed8Swift files
pass strict lint and pinned format. Existing8C3PNGs remain applicable: all visible C3 view sources are
unchanged by the rebase/B3 export-only delta and IT3 addition; minimum light/dark sample already inspected.

**Not run/claimed:** complete local app suite, live native menu/picker/keyboard/VoiceOver, ComfyUI graph
handoff, signed app walkthrough, M1/M2. Current-head CI and independent C3 review remain required.

### C4 source-aligned preparation; C3 acceptance still blocked

C3 PR70 head`972060e` has terminal independent clean review6425635875. CI40388637232
built successfully, then its full app test hit the300s watchdog. The process sample shows C3 IT3
and two B3 package tests concurrently blocked at `VideoInspector.swift:49` in AVAssetReader sample
reading. Six other jobs passed; standalone core/full lint/full format were skipped. This is not a
complete suite pass or a presumed flake. Media-owner evidence/handoff:6425833845. No CI rerun or
merge requested without diagnosis. Focused63tests/17suites previously passed remains separate evidence.

C4 is isolated on `shots/c-timeline`, based on the frozen C3 draft head. Read pinned Blockout
`src/renderer/panels/Timeline.tsx` first: ruler/scrub mapping, retime clamp preserving hold, hold
stretch clamp preserving mark time, camera-first lanes and local drag preview/single release commit.
Only the pure geometry preparation is implemented: time-to-position, clamped position-to-frame,
retime and hold stretch. Intentional Shots adaptation:24fps snapping and explicit frame-count end;
shared blocking beyond a short shot remains in the document. Source pin3f2d0564 is recorded in code.

Run/passed:3geometry tests/1suite cover every124frame round trip, edges, rounding, zero width,
retime/hold endpoints and a shared mark beyond the shot. Strict lint passed; formatter initially
reported declaration-comment/property-layout style, automatically formatted, then pinned format passed.
No production timeline UI, focus routing, playback, drag gesture, visual/accessibility acceptance or
C4 checkpoint completion is claimed. No desktop UI automation used.

C4 follow-up preparation: `ShotsTimelineDrag` captures an actor or camera mark and returns one typed
update command from the original drag value, as Blockout Timeline.tsx beginDrag/onMove/onUp does.
It uses the existing transient store preview and existing perform/undo path, preserving all non-time
channels. Five geometry/transaction tests in two suites passed: repeated preview leaves committed
document/history untouched, hold stretch commits one undo step, camera retime preserves channels,
cancel leaves no history. Strict lint passed. No gesture wiring or C4 UI acceptance is claimed.

Media diagnosis remains with Lane B: strict Swift cooperative-pool filter passed11tests/4suites on
local Swift6.4; no reproduction or cure claim for the Xcode26.6 full-suite CI hang. Native build-system
selection avoided a local generated-test-bundle code-sign failure without changing attributes/settings.

C4 navigation preparation now also has pure store actions for focused timeline arrows/Home/End/Delete,
24-frame Shift steps, text-edit protection, playback toggle/restart and idempotent guide insertion.
Reference: Blockout App.tsx useKeyboard and store.ts setPlaying; CONTRACTS section7 intentionally
narrows arrows/Delete to timeline focus and suppresses all actions in text editors. Seven tests in
three suites passed, including unchanged playhead/selection/document/history when another region or
text editor owns focus, boundary clamping, guide deduplication/one undo and restart at shot end.
Strict lint and pinned format passed. Actual focus/event wiring and24fps transport loop remain to do.
No native/global keyboard monitor is installed by this preparation.

### C4 native UI candidate (stacked on unmerged C3; not accepted)

The native timeline now has camera-first and tracked-entity lanes, frame/second ruler, guide markers
and an Add guide action, scrubbing, mark selection, retime and hold-edge gestures. Gestures capture the
original mark, use transient preview, follow a retimed mark with the playhead and commit one existing
typed update on release; Escape/disappearance/shot change cancels preview. Read-only disables edits.
Space routes at the Shots workspace; arrows/Home/End/Delete route only within the focused timeline,
with Shift stepping24frames and text-edit/modifier protection. These are ordinary SwiftUI focus handlers,
not global/local NSEvent monitors, CGEvent taps, CUA bindings or synthetic input. The elapsed-clock
playback loop presents discrete24fps frames and includes the last frame before looping.

Reference inspected: pinned3f2d0564 Timeline.tsx (lanes/ruler/capture-preview-single-commit and clamp
after translation), App.tsx useKeyboard, store.ts setPlaying, SceneManager.ts playback loop. Existing
evaluate.test.ts hold-window and audit-fixes.test.ts overlapping-hold fixtures remain evaluator behavior;
C4 does not rewrite or clamp shared blocking when a shot changes. The e2e interaction.spec.ts was
inspected as reference, not run (it launches Electron and injects real mouse input). Adaptations: explicit
24fps frame grid, CONTRACTS focus ownership/single-mark selection, native controls/semantic colours.

Verification run/passed:843full local app tests/145suites at the UI candidate (prior to only an equivalent
transport-label local binding refactor/format); final frozen source then passed10tests/5suites in the
isolated preview snapshot, including all9timeline tests and8actual empty/sample captures at both
sizes/appearances. Full app strict lint and pinned format passed. Script render-app-preview.sh created
the original source-hashed isolated snapshot; after visual repairs it was refreshed with all current
source/test bytes, every hash rechecked, and rebuilt using explicit native SwiftPM. A temporary command
wrapper selected native build system; no package/tool/security configuration changed.

Visual inspection of minimum light/dark sample found short-label truncation and final-frame clipping
in the first capture; fixed with numeric frame pills (gait remains in help/VoiceOver) and right gutter.
Both corrected minimum sample images inspected; all8corrected PNGs and source manifest retained.
The clamp-after-delta geometry regression covers a shared mark beyond the shot; playback tests cover
delayed callbacks and presenting the last frame before wrap.

Not run/claimed: actual native key/VoiceOver/pointer walkthrough, current-head remote C4CI or independent
C4acceptance. C3 PR70 remains draft after two AVAssetReader watchdog failures; its media owner has been
notified and parent provided manual delivery. C4 acceptance/landing waits for real C3 completion and its
own review/CI/focus validation; no M1/M2, ComfyUI or release/deployment claim.

### C4 review round1 repair (same PR71)

Independent review atc1b3d3a found two P2s: Escape cancellation restarted on the next pointer callback,
and Add guide persisted automatic endpoint frames. The repair uses an explicit idle/active/cancelled
transaction whose cancelled phase lasts to pointer release. SwiftUI GestureState cleanup resets an
abandoned gesture without committing; ordinary release performs one command. Guide insertion now
guards the declared1..N-2extra-guide domain and deduplicates at the action boundary; the button uses
the same eligibility. No LaneB/Core contract or validation file was changed.

Run/passed:12timeline tests/5suites, including Escape→moremovement→release (no document/history
change), following gesture recovery, abandoned gesture reset, both automatic endpoint no-ops and one
interior guide undo. Controlled mutations reintroducing each old mechanism make the two corresponding
regressions fail; fixed source restored byte-for-byte. An earlier control attempt failed to compile
because the compiler reported a timestamp change in an unchanged source file; no tests ran in that
attempt. The temporary mutation was restored. The isolated source-hashed snapshot control executed
both regressions and failed as expected.

Full repaired frozen app run:846tests/146suites passed. Its first attempt had4missing-fixture errors
because the preview-only snapshot omitted3shared repo fixture files; exact immutable HEAD bytes
were supplied without overwriting different data, then the full run passed. No assertion was weakened.
Final snapshot run:13tests/6suites passed including all12timeline tests and8offscreencaptures.
Native keyboard/VoiceOver/pointer walkthrough remains unrun. Independent bounded closure and fresh
CI remain required; no accepted C4 claim.

A4 acceptedmainc501e7be and the independently reviewed media-reader repairPR74/7fce98d4 have now
landed. Next refreshC3 thenC4 onto real repaired main, preserving reviewed commits, and run actual
current-head tests/review/CI including formerly skipped gates. Earlier C3/C4 AVAssetReader failures
remain failed historical evidence; no unchanged rerun hides them.

## C5 preparation after C4 — not an accepted checkpoint

On accepted main `ec2cb5a`, the library now arms a starter asset for Lane D's place tool,
changes the armed asset, and cancels by choosing it again. Search matches names and categories.
Reference: Blockout `src/renderer/panels/Library.tsx:658–690` at
`3f2d0564fd575f70fc28e9bfaa7e94b05e3955d9`. Its arm/toggle semantics are retained;
custom models/scans/sequences are outside this plan's starter content set. SwiftUI native buttons
and fields adapt the reference to the existing workspace. Document edits remain Lane D commands;
choosing a library tool changes neither document nor undo history.

Three library boundary tests passed in a frozen source snapshot, covering arm/switch/cancel,
read-only/missing-shot/unknown-asset guards, starter membership and case-insensitive filtering.
The first in-place build failed because the compiler reported a Yams dependency source changed
while compiling; it is not counted as a passing run. The isolated source build compiled the app
and passed all three tests. Strict lint and full format checks passed. No native pointer,
keyboard or VoiceOver walkthrough has been run.

Still outstanding for C5: selection inspectors, continuous field preview/commit, prompt UI and
fake-endpoint integration, every-inspector command/undo tests and previews. Acceptance waits for
A5 and B5 merged. Prompt facts/write are still stubs on main; this preparation does not implement
Lane B's compiler or claim that C5/M2 is complete.

## C5 inspectors and prompt integration preparation

Draft implementation now includes selection-driven shot/entity/camera/actor-mark/camera-mark
inspectors, an Inspect menu for keyboard-accessible selection, and starter library search/arming.
Blockout reference: `Inspector.tsx:65–120,397ff,567ff,1461ff,1671ff` and
`Library.tsx:658–690` at the pinned commit above. Preserved: context-driven fields, radians in
stored values/degrees in controls, captured mark channels, and generator actions through existing
engine APIs. Adaptations: per-shot notes/H3 prompt and explicit ShotsCommand edits/undo, native
SwiftUI forms, the contracted starter content set, and a single-entity inspector when several
entities are selected (the panel names the entity it edits). Source swatch colours are retained.

Continuous rig-intensity changes preview while dragging and commit one coalesced command on
release; Escape latches cancellation through release. Other fields commit native field/picker
edits through commands. Read-only files retain selection and library search but disable edits.

The prompt action calls Lane B's facts/template/write seam; demo/no model uses template, otherwise
it resolves the session endpoint. It captures the shot/revision before awaiting, checks cancellation
before committing, preserves stale revision after concurrent edits, and routes errors through the
store's session failure path. This is preparation: **B5 facts/write still throw notImplemented on
accepted main**, so no real compiler/fake-endpoint acceptance is claimed. Integration will be
reverified against B5's actual implementation; no alternate compiler is introduced here.

Verification so far: seven focused tests pass, including sixteen inspector-bound command kinds
individually undone, slider preview/cancel/recovery, and prompt revision/undo/cancellation boundary
checks with injected synthetic facts/writer. Full app suite: 854 registered tests/148 suites passed;
five optional preview/model functions skipped, not counted as executed. Initial test compile
failed on mutating calls inside #require/#expect; locals fixed those tests before passing.
Strict app lint and full format checks pass. All five inspectors rendered through the existing
preview script in light/dark at minimum/default sizes (20 PNGs); minimum entity/light and camera/dark
were visually checked. Native pointer/keyboard/VoiceOver walkthrough remains not run.

A frozen non-offloaded source snapshot is used for tests. Files in the original Documents worktree
became compressed/dataless and some reads stalled; that worktree and its uncommitted bytes remain
preserved. Active C5 preparation moved to an isolated /tmp worktree from its saved Git objects and
frozen source. No sync/security settings or apps/helpers were changed.

Remaining C5 gates: B5 merged; actual compiler/fake ModelClient integration test; fresh full CI and
independent exact-head review; refreshed final offscreen captures after the last read-only/idle-Escape
safeguards; native interaction acceptance later. C5 and M2 are not complete.

### C5 independent review R1 repairs (PR76)

Initial review at5c88b0e found two P2s, preserved as r4383158847 (entity-name typing lacks a
coalescing key) and r4383158863 (Undo/Redo clears a preview but stale slider release still commits).
The additive repair gives entity-name and rig edits their command-kind/target coalescing keys.
The slider now uses the shared store-facing gesture lifecycle for preview, invalidation, cancel
and commit: every update notices lost preview ownership, cancellation latches through release,
and commit requires the exact owned preview. Observing a foreign/history-cleared preview cancels
without clearing another owner's preview. The view uses these same methods, rather than a test-only path.

Five new store-level regression tests cover 240 typed characters without evicting an earlier edit,
separate targets/non-coalescing controls, Undo with/without subsequent movement, Redo, replacement
preview custody, normal one-step commit, Escape and the next drag. All12focused tests pass.
Restoring the old mechanisms in the isolated snapshot makes the review regressions fail with13issues;
fixed bytes were restored in finally. Fresh full app verification and closure/CI are tracked in PR76.
Old-head green CI40411243246 and its20captures are not treated as acceptance of this repair.
B5 real prompt integration and native acceptance remain outstanding as above.

## C6 preparation: glossary, credits and keyboard action model

Stacked on C5 PR76 at4fda2b5; C5 is not accepted until B5's actual compiler integration is verified.
Thirteen required Shots terms now live under using-conceptstudio, with plain/technical readings and
related links. The Help window gains Credits containing the required Blockout acknowledgment and
PrevisCoreAttribution.notice(). PRODUCT.md is unchanged; its proposed paragraph is in this PR description
for owner approval.

The source accessibility audit found no non-pointer route to add a library asset or its first mark.
Separate Add-to-scene buttons now create a selected entity at the stage centre, leaving the existing
arm-click-place behavior intact. Add mark here in the entity inspector captures its committed evaluated
position/facing at the playhead. Both use existing ShotsCommand edits and reject read-only or transient
preview states; they do not edit Lane D picking/placement code.

References at Blockout3f2d0564: types.ts (scene/shot/mark/gait semantics), store.ts:498–558
(asset naming/selection and mark construction), and NOTICE. Destination-mark gait semantics are retained.
Intentional adaptation: keyboard insertion at stage origin and exact playhead timing from the settled
D3 plan, instead of Blockout's first-at-zero/next-at-least-two-second pointer spacing.

Verification:8focused tests pass (including existing glossary invariants), and the full app suite reports
863registered tests/150suites passed;5optional preview/model functions skipped, not counted as executed.
The new headless action integration adds a person, moves it, adds a mark, undoes/redoes and exports a
valid22frame320×576package. Lint and full format checks pass. Preview/independent review/CI results are
tracked on this draft; old C5 captures are not presented as C6 output.

Planned native walkthrough (NOT RUN): open Shots and a scene; keyboard-focus the library's Add person
button; select the entity inspector; edit X/Y/Z; activate Add mark here; undo/redo; export and inspect the
package. Verify focus traversal, field editing vs playback shortcuts, Escape, and VoiceOver labels for
library actions, Inspect menu, mark pills, fields and export progress/error. No native input was injected.
C6 completion still needs that actual keyboard/VoiceOver pass, final full preview set and C5 acceptance;
M1/M2 and D-lane integration remain separate. No release, deployment or owner PRODUCT approval claimed.

C6 visual follow-up: minimum Help capture exposed the three topic segments reaching the window edge.
The title and full-width topic picker now occupy separate rows, retaining the existing topic wording;
the new website link uses the established ink tint. Captures and full verification are refreshed after
this source change. This changes Help layout only, not any training screen or shortcut.
