# Lane B status

This file travels at the top of each Lane B checkpoint (now B6's `shots/b-media-b6`), so checkpoints that have passed review keep their exact heads.

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
| B4 Blockout and document input, IT2 | **Landed on `main`** as merge commit `94cdbba`, by the integration owner, from head `dba68f1` ([RationallyPrime/concept-studio#78](https://github.com/RationallyPrime/concept-studio/pull/78)). The integrator's independent review accepted `dba68f1` (comment 6430062402).
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
| B5 prompt | **Landed on `main`** as merge commit `9c6532b`, by the integration owner, from head `60ec148` ([RationallyPrime/concept-studio#79](https://github.com/RationallyPrime/concept-studio/pull/79), `[contract]`). `60ec148` is the integrator's camera-versus-subject repair on top of the owner's `e53c2fd`, recorded under "Integrator repair" below; the integrator's independent closure accepted it. **Before landing: on `main` at `94cdbba`, code head `dfa70ba`, with a status commit on top. Reworked after the Blockout audit (2026-10-26), then closed under the owner's bounded closure (2026-10-27, below).** Its first four code commits are range-diff identical to those gated on B4's code head `70d588a` (`ced5009..981572d`); between the two bases only this file differs. `23cd878` then qualifies two calls CI's Swift 6.3 read as the local constant being declared (`Self.panned`, `Self.riding`), with no change in behaviour; ShotsMedia (80 tests) and both linters were rerun on it. `7c64083` adds the closure fixes recorded below. The merge `6342181` publishes them with the earlier published history; its tree is `5153057`'s. `dfa70ba` makes the bounded-closure fixes.

**Built:**
- **`PromptFacts`:**
  - the picture times and middle guides;
  - camera legs, the subjects the camera aims at or rides with, and the rig's shake;
  - subjects, by catalog noun, appearance and gait marks;
  - props, the lighting in words, the setting, sound and music, and the scene revision.
- **Names:** no entity names or labels reach the facts or the prompt.
- **Format:** the FL2VA picture-alignment header and H3's three sections.
- **`write`:** runs through `StructuredStage` with the bundled `h3-shot-prompt` skill, and tells the model its character budget.
- **Package files:** `prompt.txt` and `prompt.json`. `prompt.json` also records the revision the prompt was written from, and its problems.
  - These two keys are additive. CONTRACTS section 8.3's `prompt.json` line is updated in this branch, so B5's PR goes through the `[contract]` route.

**Camera legs come from the evaluated camera** (`CameraLegs.swift`), as the clean video shows it, with rig noise off:
- **Evaluator handling inherited:** `ShotEvaluator` has already shortened holds that run past the next mark (Blockout `src/engine/evaluate.ts:66-68`), aimed an aim-locked camera, and carried a mounted one (`evaluate.ts:434-475`).
- **Around a travelling subject, read between the camera's marks:** which way the camera goes relative to a subject on the move is judged between two of the camera's own marks, where camera and subject are both where they were put.
  - In between, the camera's easing and the subject's, his snap onto a new heading at a path corner, and the curve of either path make the camera lag and catch up. That isn't a move.
  - The A4 oracle found this. Blockout eases a preset's first and last marks by a quarter of the leg (`src/engine/camera-moves.ts:136-153`), and A4 keeps that. Around a man already walking, the camera fell behind and caught up, so the behind follows read pull, push, track, push, pull, and the leading ones the reverse.
  - Blockout's default marks drift the same way (actor marks ease 0.25, camera marks 0.3: `src/engine/schema.ts:93`, `:107`). A follow round a right-angle corner read as an arc: the man's facing snaps at his mark while the camera swings round between its own.
  - The legs still come from the evaluated, eased camera, so their frames and speeds are the video's. Around a subject standing still, each piece is read on its own, as before.
  - **Standing still is read on its own:** a stretch where the subject does not move at all, as at a hold, is read piece by piece. A stretch where he moves at all is read between the camera's marks around it, whatever his stops and starts in between. A push on a man who stands for 3 s and then sprints off is a push while he stands, not a pull against where he ends up.
  - **A standing stretch holds only frames where he stands:** it starts at the first frame at or after he reaches his mark, and ends at the last frame at or before he leaves it. A hold ending between frames, at 2.9 s, or a stop at 3.1 s, puts no frame of his run in it.
  - **Only a nameable change:** between the camera's marks, an offset or a way round that changes by less than 0.15 m names nothing, so the rounding of mark times to frames does not.
  - **The same threshold around a travelling subject:** a push, pull or crane relative to a subject on the move needs the same 0.15 m as one around a subject standing still, however fast the two travel together. A 3.5 m crane beside a man going 12 m/s is a crane.
  - **Where the camera is placed:** at its own marks and, on a car mount, the car's, whichever subject it aims at. Those cuts fall where the evaluator places them: at each mark's time, and when it leaves, its hold cut short a tenth of a second before the next mark (`evaluate.ts:66-68`). The camera's own are rounded to the nearest frame, and a car's or a subject's inward, as above. A jump to a mark at the same time is a one-frame cut of its own, at the frame where the evaluator crosses it, and it counts in no move's path or orbit. It still counts in how far an aimed push, pull or crane goes (Open, below).
  - **Going round:** the angle round the subject is summed frame by frame, so an orbit of half a turn or more between two marks keeps its way round, and a full turn that ends where it began is still an orbit.
- **Stretches and pieces:** stretches run between the moments the camera's marks, its car's and its reference subjects' marks are reached or left, as the evaluator times them. Each stretch is read in pieces of at most 12 frames, and pieces with the same move merge, so Blockout's many-mark presets read as one move.
- **Travelling or planted, per stretch:** the camera travels where three things hold:
  - its path over the run of moving stretches reaches 0.15 m, so a push keyed with close marks adds up;
  - its path over the stretch is at least a quarter of the subject's travel;
  - for a free camera, that path outweighs its pan and tilt, unless it circles something at least half a metre away.
  Otherwise it is planted, and pans, tilts, zooms or rolls. So drift neither turns a pan into an arc nor hides it.
- **Around an aim-locked subject, or a mounted camera's car,** moves are judged relative to it: orbit, push, pull or crane, or track when the camera keeps its offset.
  - **Frames:** the subject's own frame or the world's, whichever the offset changes less in. A camera kept behind a turning walker tracks him, and Blockout's world-bearing push stays a push. A mount always uses the subject's frame.
  - **Following:** a relative move on a travelling subject also carries track ("pushes in while following the man"). A camera that only creeps beside a walker holds.
  - **Naming:** the prompt names that subject ("arcs counter-clockwise around the man").
- **Overhead:** passing over a subject is a push then a pull, never an arc.
- **Pans when tilted:** a pan swings the view by the cosine of the tilt. Looking straight down or up, a free camera's pan spins the picture and reads as a roll. An aimed camera's pan over a subject below it adds no roll.
- **Brief spans and speed:** a brief hold or small move joins a neighbour; a brief large one (a snap) stays. A move that fills one of the camera's own legs while its subject stands still was put there, and is named however brief. Speed is measured over the frames that actually move.
- **Orbit names follow Blockout:** `orbitLeft` is counter-clockwise seen from above (`src/engine/camera-moves.ts:362-372`). B5 had it reversed.
- **From H3's own camera vocabulary** (MiniMax's prompt guide, motion table): tracking, roll and shake. A zoom or roll riding on a move goes in the leg's `also`, and rig noise is `shake`.

**Reused from Blockout `src/engine/prompt.ts`:**
- the lighting words (lines 15-25);
- the notable-subject rule: whatever moves, carries a label, or is a person, vehicle or animal (40-46);
- each noun once, for props (48-52);
- a 35 mm lens when there are no camera marks (30), through the evaluator's default.

**Intentional differences from Blockout:**
- **Prompt structure:** the prompt follows H3's FL2VA structure, not Blockout's motion-reference prompt (SHOTS-PLAN sections 3 and 7).
- **Same-noun subjects:** subjects that share a noun and appearance are told apart by order ("the first man"), instead of being listed once, because the template narrates each subject.
- **Labels:** no editor labels in prompts (SHOTS-PLAN section 7), where Blockout writes `noun ("label")`.
- **Camera subjects:** whatever the camera aims at or rides with is a subject, even a prop, so the prompt can name it.
- **Setting:** no "Setting:" line from environment kits. Kits are out of scope (LANE-A-CORE), so the setting comes from the shot's notes.
- **Music:** no music writes `N/A`, as H3's guide asks; B5 used to write `None.`

**Guards:** a stored prompt older than the scene, or longer than 1,800 characters, is reported in `prompt.json` and as a CLI note. The 1,800 characters is about 512 Qwen3 tokens, ai-toolkit's cap on H3 captions. Nothing is refused.

**Author-side review** (separate review agents run by the author, not the integrator's independent review): nine rounds, each followed by an adversarial check of its findings, and then closed by the owner (below). The first five confirmed 33 distinct findings, and all are fixed here with a test each:
- **The first review (three lenses), 15 findings:**
  - camera reading: drift, a truck with a slight pan, a turning mount, the overhead check, small moves around a standing subject, and a five-frame shot;
  - the camera's subject left unnamed, and the `prompt.json` contract line;
  - in the tests: a fixture name, a test that restated a table, and unguarded indexing.
- **Four closure rounds, 18 more:** mostly regressions from the fixes. Among them:
  - the frame choice for turning subjects;
  - a close aim-locked orbit read as a pan;
  - a push with a strong zoom splitting;
  - pushes keyed with close marks;
  - free pans lost to drift;
  - pans at steep tilt read as rolls;
  - a pan out and back;
  - drifts around a push;
  - a free close orbit;
  - a spin riding on a crane;
  - a pan with sideways drift read as an orbit.
- **A sixth round, on the later commits** (the A4 oracle, a first fix and the corner and overhead tests): three finders and an adversarial check of each finding. Six findings were confirmed, and five more went unverified for lack of slots; those were a duplicate and claims about text since rewritten.
  - **The first fix was wrong:** it read the camera's marks without their easing. A camera eased like its walker then read as arcs (a steady side track as three of them), and leg frames and speeds left the video's. It was replaced by the reading between the camera's marks.
  - **The oracle checked too little:** it checked only the longest leg, and the refactor had dropped the ordering checks around the flying subject. It now checks whole sequences and the eased walk, and runs the ordering checks around the flying subject again.
  - **Stale claims:** the corner's cause, and the flying subject's leftover legs, are corrected above.
- **A seventh round, a closure review of `1989b9a` and `1f3417f`:** two findings confirmed and four unverified. All six were checked. Five were real and are fixed in `7c64083`, each with its own test:
  - **Following decided over the whole span between two camera marks** (confirmed): a push on a man who stood and then ran off read as a pull. Where he stands still, the camera is now read on its own.
  - **A car mount's own marks not cut** (confirmed): a camera car closing on a runner and stopping read as a pull. The car's marks now place the camera.
  - **The way round taken end to end:** three quarters of a turn between two marks read as a quarter turn the other way. It is now summed frame by frame.
  - **A jump to a mark at the same time** spread over the following leg as a fast push. It is now a one-frame cut of its own.
  - **A hold's written end, past the next mark,** was a cut in the middle of the next leg and brought back the lag. Cuts now fall where the evaluator places them. A two-frame push squeezed out by such a hold would then have been dropped as brief, so a move filling one of the camera's own legs now stays.
  - The sixth, that the vectors oracle required the flying subject's 3 s crane to read as a track, came from the tenth-of-path rule. The check was first relaxed to one leg that follows the subject; the bounded closure drops the rule and the check.
- **An eighth round, on those fixes:** three finders and an adversarial check of each finding. Four findings were confirmed (two of them the same defect), two refuted, and five more went unverified for lack of slots. Every real one is fixed in `7c64083`, each with a test:
  - **The first fix for following brought the lag back** (confirmed): it joined only the stretches where he travelled, so the reading ended at his stops and starts, between two camera marks. Follows around a man who stops or pauses read pulls. A stretch where he moves at all is now read between the camera's own marks again, and only standing still is read on its own.
  - **0.15 m was the wrong test for standing still:** a walker easing into a mark, or covering 12 cm in two frames, counted as standing, which split his follow and let a 5 cm nudge beside him be named a push. Standing still now means not moving at all.
  - **An overhead pass read as a track** (confirmed): the new guard took a symmetric pass over a standing man for no change. It again means the offset held and the camera did not go round.
  - **The jump fix was partial** (confirmed): it held only for the reference span, and only when the jump's time fell on a frame or rounded down. Jumps are now cut at the evaluator's crossing frame and left out of every path.
  - A camera following round a closed loop, and the relaxed flying-subject check, were refuted. A wrong distance in a test comment was corrected.
- **A ninth round, on `7c64083`:** three finders and an adversarial check of each finding. One medium and four lows were confirmed; the wording of a limit was judged a known limit; three more went unverified.
  - **Medium, fixed in `dfa70ba`:** cuts rounded a mark time to the nearest frame. A hold ending between frames, at 2.9 s, left one frame of his run in the standing stretch, so the push read as a pull. Standing stretches now round inward.
  - **Four lows,** recorded as limits under Open: a camera car on a loop whose rider snaps his facing (a regression), a rider with no marks of his own, a subject's own jump, and a camera jump just before a frame.
  - **Wording:** the limit "while the subject stands" also covers A4's own follow presets; it is reworded under Open.
  - **Unverified:** a jump still counting in an aimed push's amount (a probe shows it is real; Open), two stale lines in this row (corrected), and the orbit amount's jump rule having no test (it now has one).
- **Independent review** (the integrator's, on `6342181`): changes requested, P2. An authored crane around a fast subject was left out: the camera rose 3.5 m beside a man going 12 m/s and read as a track, because around a travelling subject a change in height or distance had to reach a tenth of the camera's path. At half the speed it read as a crane.
- **The owner's bounded closure (2026-10-27):** the owner chose bounded closure over a simpler reader that names one move per authored camera leg.
  - **Fixed in `dfa70ba`, each with a CI test:**
    - the crane: the tenth-of-path rule is gone, and the reproducer is a test at both speeds;
    - the off-grid medium: a 2.9 s hold and a 3.1 s stop are a test;
    - the orbit amount's jump rule has its own test.
  - **One listed scene was corrected:** dropping the rule exposed a fault in the eased-walker test's scene. Its camera was keyed 4 m behind where an un-eased walker would be, so at its middle marks it stood 3.7 m behind him, and it read as a 0.3 m push and pull that the rule had hidden. Its marks are now keyed 4 m behind where he is, as the test says, and it reads as one track.
  - **Accepted as a limit:** the flying subject's own bob may read as small crane legs. That is what the rule was added to hide.
  - **The rest are limits,** recorded under Open.
  - **No further author-side review rounds on B5.** A later finding counts against the acceptance bar only if it breaks a listed scene; anything else becomes a follow-up ticket and does not hold the checkpoint. Whether to review again is the integrator's call.
  - **The acceptance bar:**
    - the A4 oracle in CI: the 20 starter moves around a man standing, walking, and walking with Blockout's default easing;
    - Blockout's golden vectors, with `PREVIS_VECTORS` set;
    - the spec's sample export;
    - every listed scene as a CI test: the 58 camera tests, plus the crane at both speeds, the off-grid hold and stop, and the orbit's jump;
    - the app and PrevisCore suites, both linters, and an undo check of each new fix.

**Author verification:**
- **Restack:** first on B4 `a4249ea` over main `c23dea8`, with A4's `CameraMoves` and A5's evaluator (turns blended into the mark, one attachment graph). The two reworked commits came across range-diff identical, every gate was rerun and passed, and the new evaluator needed no change. They were then rebased onto B4's code head `70d588a` with no conflicts.
- **Tests on the code head `dfa70ba`:** ShotsMedia passes 97 tests with `PREVIS_VECTORS` set and without it, 61 of them camera tests. The whole app passes 923, and PrevisCore 148.
- **A4 oracle (runs in CI):** each of A4's 20 starter moves is generated with `CameraMoves.marks`, the fixture of Blockout `tests/unit/camera-moves.test.ts`. It runs around a man standing, walking at 2 m/s, and walking eased by a quarter (Blockout's default actor easing).
  - Each move reads as exactly its name, or a follow move as a track (a hold around someone standing). Whip-pan, side-dolly-past and crash-in are built of parts, and their sequences are spelled out. A crash-in is a hold then a push around someone standing, and a track then a push around someone walking.
  - It found the lag described above.
- **Blockout oracle:** the golden camera-move vectors from Blockout's own engine (all 39 presets × three subjects × two lengths, run with `PREVIS_VECTORS`) read in order and as their names around standing and walking subjects. That includes the whip pan, the snap zooms, the dolly-zoom and the dutch rolls. Passes over a subject never read as arcs. Its ordering checks run around the flying subject too.
- **Undo checks:** 64, each undoing one change in the code at `dfa70ba`, and each failing its own test in one sweep.
  - The five new ones undo the bounded closure: the tenth-of-path rule put back, a subject's departure or arrival rounded to the nearest frame, all of his marks rounded that way, and a jump counted in an orbit.
  - The other 59 are the earlier cases, carried onto the new code; the tenth-of-path case is gone with the rule.
  - The rules a test reached only through Blockout's golden vectors, or no longer reached once moves filling the camera's own legs were kept, each have a CI test of their own: the snap rule, the 0.8 crane rule, the speed trim, keeping the last leg, and the overhead checks.
- **Export and lint:** `shots-export --sample` is valid, and swiftlint and swiftformat are clean.

**Open:**
- **Review:** the owner has stopped author-side review rounds on B5, so `dfa70ba` has had none. A later finding holds the checkpoint only if it breaks a listed scene (the acceptance bar, above).
- **Oracle coverage:** the A4 oracle covers the 20 starter moves, the ones A4 generates. The other 19 Blockout presets are checked only by the vectors oracle, which needs `PREVIS_VECTORS`.
- **The reading is a heuristic,** tuned against Blockout's presets and the review's cases:
  - a straight aim-locked strafe past a subject reads as a push then a pull, not as a truck;
  - **Around Blockout's 12 m/s flying test subject** (accepted by the owner): its own 1 m bob reads as small crane legs. With the tenth-of-path rule gone, 40 of 78 readings have more than one leg, up from 28. Crane-up-reveal, crane-down-intro and the pedestals now read as cranes. The dolly-zoom, crash-in, creep-in-low and orbit-90-right begin with a crane down as the subject rises. Passes over it read push, track, pull, and a planted camera tilts down as it flies off.
  - **A follow keyed from an eased subject's un-eased path** (the same trade as the bob): around a travelling subject, a change in distance or height of 0.15 m between two camera marks is named. A camera keyed 4 m behind where an eased walker would be without easing stands 3.7 m behind him at its middle marks, and reads as a small push and pull. Keyed from where he is, it reads as one track. The tenth-of-path rule used to hide this.
  - **Inside a camera span:** around a subject on the move, a relative move that really changes direction between two camera marks is read as its net move between them, not split.
  - **While the subject stands:** the camera's own motion is named. Whenever one of the camera's marks falls after he stops, before he starts, or past a pause, the camera is still moving between its marks while he stands, and that reads as a small push, pull, truck or arc there. That is real motion relative to him. It includes A4's own follow presets in an ordinary 6 s shot, whose marks are 0.86 s apart, and pedestal-up-slow; around a man who stops, starts or pauses, they gain a 10- to 14-frame leg that the published head folded into the move around it.
- **Ninth-round lows, not fixed:**
  - **A regression against `3679ad7`:** a camera car following a rider round a loop whose facing snaps at each mark (Blockout's horse-gallop-loop) reads alternating arcs left and right. The published head read one track. The car's marks cut the loop into spans, and a span across a snap is summed in the rider's own frame.
  - **A rider with no marks of his own**, attached to a car or boarded onto it, gets no standing cut. A push on him while the car waits and then drives off reads as a pull for the whole shot, as it did before.
  - **A subject's own jump** to a mark at the same time is cut as a one-frame stretch but not as a jump, so the aimed camera's re-aim reads as a one-frame fast pan.
  - **A camera jump just before a frame,** or two marks a fraction of a frame apart, is sampled partway across; that frame counts as a step, and its leg reads as a push.
- **A jump in an aimed push, pull or crane:** how far it goes is still measured end to end, jump included. Pushing 2 m on a man standing still with a 2.5 m jump between reads fast and large, where the same 2 m in one push reads medium. |
| B6 app support and budgets | **Draft PR [RationallyPrime/concept-studio#80](https://github.com/RationallyPrime/concept-studio/pull/80) on `main` at `139a2e4`: code head `c261b67`, with this status commit on top.** Unblocks D6.

**Progress steps Lane C can show.** Lane C's export view (`ShotsExportView`) shows each step as it comes. The steps used to be file paths ("Writing control/pose.mp4"); they are now plain words, after Blockout's `Rendering <pass> pass…` (`src/renderer/export/exporter.ts:295`):
- one step per video, in pass order: "Rendering the clean pass…", "Drawing the pose pass…", "Drawing the layout pass…", then "Rendering the matte of <name>…" for each actor;
- then "Checking the package…", at fraction 1.
- The fraction counts frames across all videos and never goes back. Lane C's IT3 checks only that it ends at 1, so it is unaffected.

**Cancellation.** Cancelling during any step, the check included, throws `CancellationError` and leaves neither a staging folder nor a package.
- **Fixed:** cancelling during the check used to fail as "The exported package isn't valid: … can't be read: … CancellationError", because the validator could no longer read the videos. The staging folder was still removed. The exporter now checks for cancellation before reading the validator's problems.
- **Blockout differs:** it writes straight into the package folder, so a cancelled export leaves a partial package (`exporter.ts:133-137`, `:364-370`). The staged export here was already the plan's (CONTRACTS section 6).
- **Blockout's test** (`tests/e2e/cancel-export.spec.ts:31-72`) cancels once, on a timer, and checks that the result is "cancelled" and no `.mp4` is left. Ours, `cancellingDuringAnyStepLeavesNothingBehind`, cancels during each step in turn, and checks that the destination is empty.

**Budgets** (CONTRACTS section 10). Measured in release builds on this Mac: Apple M4, 10 cores, macOS 27.0.1, local Swift 6.4. CI uses Swift 6.3 and never sets `SHOTS_TIMING`.
- **Lane A,** `SHOTS_TIMING=1 swift test -c release --filter Timing --package-path PrevisCore`, with ten entities:
  - `ShotEvaluator.init` median 0.017 ms (budget 5);
  - `frame` mean 0.052 ms over 372 frames (budget 2).
  - The test is Lane A's draft PR #75 (`9a3ef8e`), run on a copy of `main`'s PrevisCore. It is not part of this branch.
- **Lane B,** `SHOTS_TIMING=1 swift test -c release --filter Timing` in `app/`, on the full sample (124 frames, 640 × 1152, two actors):
  - `ShotFrameRenderer.image`: median 2.0 ms over 21 frames, at most 4.5 ms (budget 40);
  - the standard export: 1.64 s in all (budget 30). Clean 0.30 s, pose 0.25 s, layout 0.26 s, the two mattes 0.29 s and 0.26 s, and the check 0.02 s.
  - The app's `Timing` filter also matches one unrelated test, `eachModelKeepsItsOwnFrameGridAndTiming`, which passes.
- **Lane D's** viewport budget is measured in D6.

**Reports from C and D:** none is open for Lane B. D6 waits on B6. Lane C's note on an Xcode 26.6 CI hang has no reproduction, and `main`'s CI at `139a2e4` passed.

**Gates on `c261b67` with this file:**
- **Tests:** the app passes 948 tests in 157 suites. ShotsMedia passes 102 tests in 13 suites with `PREVIS_VECTORS` set and without it. PrevisCore passes 148.
- **Export and lint:** `shots-export --sample` is valid, and swiftlint and swiftformat are clean.
- **Preimage:** both new tests fail on `139a2e4`.

**Undo checks: six, each failing its own test:**
- the cancellation check moved back after the problems guard, or removed;
- the staging folder kept on error;
- an unnamed matte step;
- file-path steps;
- a fraction that restarts with each video.

**Review:** the Codex review loop on the draft, then the integrator's independent acceptance. Lane B doesn't merge its own work. |
| B7 walkthrough fixes | Not started |

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
    - `tests/unit/camera-moves.test.ts` (B5: ported as the A4 oracle);
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

## Integrator repair: distinguish camera motion from subject motion (2026-10-27)

The owner-published `e53c2fd` restored an authored crane but narrated a level camera as a downward pedestal when
only its subject rose. Ari takes this repair in an isolated branch under the user's explicit authority to land B5;
Claude's committed history and checkout remain preserved. The earlier proposed listed-tests-only acceptance bar
is not a waiver of confirmed material defects.

The repair measures crane direction and amplitude from actual evaluated world camera height, excluding jumps
from amplitude. Horizontal subject separation measures push/pull, so subject height alone cannot invent a dolly.
A camera rising alongside its subject still cranes even if their relative height is constant. A straight-over pass
whose endpoint radii match keeps its existing camera-motion fallback rather than becoming a false track.

Reference: Blockout `3f2d056`, `src/engine/camera-moves.ts:488-518` (Pedestal Up moves from `ctx.camera.y`),
and `422-452` (Crane-Up Reveal authors actual camera positions). Blockout has no equivalent H3 motion classifier;
this is the Swift prompt-facts adaptation, not a new translation or an alteration to the evaluator.

Regression coverage combines camera/subject rises of -3.5, 0 and +3.5 metres at shared forward speeds 0, 6 and
12 m/s: 27 scenarios, checking evaluated camera height, actual crane direction/amplitude, no false pedestal in
text, and stationary/tilt/tracking controls. Existing authored-crane cases at both speeds and Blockout preset
oracles remain active. The preimage fails the new matrix and restored repair passes. Final independent closure,
full exact-head verification and CI remain required; native/M1/M2 acceptance is separate.
