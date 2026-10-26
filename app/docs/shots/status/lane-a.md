# Lane A status

| Checkpoint | State |
|---|---|
| A0 declarations | **Merged** (`de3947b`; guide frame 61 per CONTRACTS, repaired by the integration owner under a recorded two-line exception). |
| A1 content, catalog, import | **Merged** (PR #59, `93dbb76`; round 1 repaired in `913fd2b`, closed by independent review). |
| A2 evaluator parity and paths | **Merged** (PR #64, `89d9e7d`). Real `ShotEvaluator` (legs, paths, easing, holds, joint blending, boarding and attachments as Blockout's four passes, camera lens, aim lock, mount, rig noise), `EntityFrame.joints` and `speed`, `paths()`, and the parity test. |
| A3 bodies | **Merged** (PR #65, `0bdb09a`; two review rounds: the quadruped gait scale and the outward Z overrides). |
| A4 generators | **Draft PR, targeting `main`** (branch `shots/a-core-a4`, three commits on `0bdb09a`). `CameraMoves` (20 starter moves), `ActionPaths` (14), `Motions.apply` and `overlay`, `Framing` (all ten kinds) and `Attachments`. |
| A5 corrections | **Prepared, not published** (local branch `a5-wip`, on A4's repaired head `5e66777`; no PR until A4 is accepted). Evaluator warnings, `ShotsValidation`, authored turns, vertical heading, one easing and the attachment graph. |
| A6 | Not started |

**A5 tests** (Linux, Swift 6.3.3, debug; `PREVIS_VECTORS` and `PREVIS_GOLDENS` set): 101 run, 101 passed, 0 failed.

**The default evaluator has the corrections on.** `ShotEvaluator`'s public initialiser uses `Corrections.all`; Blockout's behaviour is
reachable only internally (`corrections: []`) as a **legacy baseline**, so the port can still be proved against its oracle. `ParityTests`
is that baseline and is labelled so: all 8 scenes within 1e-9 with the corrections off. It says nothing about the default evaluator, which
is covered by facts (`CorrectionTests`, `AttachmentGraphTests`, `A4ReviewTests`) and by `FeatureParityTests`, which runs the **default**
evaluator against Blockout's output and requires agreement on every channel the corrections do not touch (an entity's heading only where
it has an authored turn or a vertical leg or rides something that does; the camera's orientation and lens only where its marks differ in
them), and pins the exact inventory of intentional deltas:

| Scene | Channels that differ from Blockout, and why |
|---|---|
| `actors-paths-ease-hold` | `ent_001.heading`: an authored turn blends instead of snapping (defect 1) |
| `camera-16:9-handheld`, `camera-9:16-steadicam`, `camera-2.39:1-drone`, `camera-1:1-crane` | `cam.pan`, `tilt`, `roll`, `focal`, `vfov`: one easing instead of easing then smoothstep (defect 6) |
| `track-and-mount` | `cam.focal`, `cam.vfov`: same; pan and tilt are aim-locked and unchanged |
| `mount-no-track` | none: the default evaluator equals Blockout on all 2030 channels |
| `marriage-boarding-alighting` | `ent_041.heading`, `ent_042.heading` (turning parents) and the heading, `x` and `z` of `ent_042` to `ent_045`, which ride or are attached to them |

Every other channel, 17 295 of them in the 8 scenes, agrees within 1e-9. A delta that disappears or a new one that appears fails the test.

**A5 decisions.**
- *Authored turns (defect 1) — the plan maintainer's ruling, PR 67 comment 6424533971.* An authored turn **finishes on arrival**: it blends
  over the leg that arrives at the mark, from the facing the actor has at departure (the end of the previous mark's hold), with that leg's easing.
  The mark's own `hold` keeps the arrived facing, as in Blockout. A leg between two marks on one spot is an in-place turn, a travelling leg into an
  authored facing turns while it travels (from the departure facing, not the travel direction), and a leg into a mark with no authored facing keeps
  facing along travel. "The hold before its mark" meant the actor standing still before reaching the mark, i.e. a leg between marks on one spot;
  it does not mean `Mark.hold`. A turn after arrival is not accepted. The `LANE-A-CORE.md` A5 bullet carries the authorized wording. Example
  (one spot, placement 0, all eases 0): P at t = 1, hold 2, facing 0; M at t = 5, hold 3, facing π/2; N at t = 10, hold 0, facing 0.

  | t (s) | 2 | 3 | 4 | 5 | 6.5 | 8 | 9 | 10 |
  |---|---|---|---|---|---|---|---|---|
  | implemented (the ruling) | 0 | 0 | 0.7854 | 1.5708 | 1.5708 | 1.5708 | 0.7854 | 0 |
  | Blockout, legacy | 0 | 0 | 0 | 0 | 1.5708 | 0 | 0 | 0 |

  `CorrectionTests.theMaintainersTableForTheTurnIntoAMarkHoldsEverywhere` pins both rows. The default evaluator equals Blockout in every hold and
  differs only on the legs that arrive at an authored facing (and vertical legs); `FeatureParityTests` now scopes the heading delta to those legs'
  time intervals and requires an exact match everywhere else (in `actors-paths-ease-hold`, 61 corrected samples where there were 145).
- *Vertical moves (defect 2).* A leg with no horizontal motion keeps the heading it had.
- *Attachment graph (defects 3 and 4).* One graph, parents first, full quaternion transforms: a child's offset is in its parent's full orientation
  and its orientation is the parent's times the attachment's rotation. Boarding is an edge in the same graph, captured from the vehicle's resolved
  pose, so a cart attached to a moving bus carries its rider (Blockout's fixed order left the rider 0.5 m or more behind). A cycle is an
  error at evaluator construction and in `ShotsValidation`. `EntityFrame.heading` is still a yaw, but the drawn geometry carries the whole orientation: `PosedPart.transform`, the world
  keypoints and the bounds are built from the entity's full orientation, so an attachment's pitch or roll tips the body, not just its position
  (`AttachmentGraphTests`: a man attached with a quarter-turn pitch lies along +z with his nose at the feet's height, and his torso part's up
  axis points along +z; a roll tips him to the side). Before this the parts, keypoints and bounds stayed upright whatever the attachment said.
- *Warnings and validation.* Speed, the 180-degree rule, the trained range, marks past the end, and the two kept Blockout behaviours (marks at one
  time teleport; a pan always takes the short way). A gait name the reader does not know is a decode error naming it.

**A4 tests** (Linux, Swift 6.3.3, debug; `PREVIS_VECTORS=<golden-vectors.v1.json> PREVIS_GOLDENS=<goldens.json>`): 64 run, 64 passed, 0 failed.
- Vectors: all 14 action paths and all 20 camera moves match Blockout within 1e-9 (camera moves for a still, a walking and a flying subject, at two
  durations), through the internal entry points that take a subject function.
- Framing, with a mutation check: every `Framing.Kind` keeps its subjects in the canvas on the sample; a wide shot now tilts toward the middle of the
  figure (Blockout's was always 0); a two-shot backs off further on a portrait canvas than a landscape one (reverting to Blockout's full-sensor
  horizontal field of view fails that test).
- Overlaying `wave` on a walk leaves positions, timing, gaits and leg joints unchanged while the arm follows the wave at the marks' times.
- Attachments: an attachment keeps the child where it stands, then it rides the parent; detaching keeps it where it stands; a cycle is an error naming both.

**A4 decisions.**
- `ActionPaths.marks` starts from the entity's placement. With a `speed`, times are scaled so the average speed along the marks is that speed.
- `CameraMoves.marks` runs over the whole shot from its first camera mark; several subjects act as one at their midpoint, as tall as the tallest,
  facing the average of their headings.
- `Motions.apply` plays a motion once at the pose the entity has at `time`, keeping earlier marks; looping is the caller's. `overlay` samples at the
  track's own mark times, so a track needs marks about as often as the gesture changes.
- `Framing` sizes frame the first subject; `overShoulder` frames the far one of the first two. Distances that fit things in the frame use the canvas aspect.
- `Attachments.attachment` yields a yaw-only rotation until A5 resolves attachments with full transforms.

**A4 review round 1** (PR #67, four P2 findings at `9fee26d`; each reproduced before its repair, the regressions are in `A4ReviewTests`):
- r4377817859, negative root displacement. `Motions.apply` clamped every `move.up` at the ground, so `squat-exercise` (−0.35 m) left the body
  0.47 m above the ground. The signed offset is kept; the bent hips and knees put the body back on it (feet at 0 m at the lowest keyframe).
- r4377817868, two-shot elevation. The vertical fit used the tallest height only. It now fits the world extent from the lowest base to the highest
  head, about the aim height 0.55 of it, so two subjects 10 m apart in height are both in a portrait frame. On one ground plane the result is within
  5% of Blockout's distance (the aim is 0.05 of the extent off-centre, so the margin is now measured from the aim).
- r4377817875, mounted cameras. `Framing.cameraMark` and `CameraMoves.marks` worked in world space, but a `carMount` camera's marks are relative to its
  mount. Both now return mount-local marks (position rotated into the mount's frame, `pan` minus its heading) at the mark's own time; the moves also take
  the camera's start from the mount's world frame. `.dutch` on a mounted camera now changes only the roll.
- r4377817829, heading. Every generated mark now carries the facing the entity has at `time` (`arriveHeading`), so an actor who faces elsewhere than his
  placement keeps that facing at the start and end of a motion and after it. **Partly open:** during the motion the evaluator reads a stationary leg's
  facing from the placement, because Blockout's `evaluateTrack` has no heading for a leg that goes nowhere. Honouring `arriveHeading` there changes
  A2's `actors-paths-ease-hold` parity scene (entity `ent_001` after t = 5 s: 2.5 rad against Blockout's 1.15), so it is not done here. It is an
  authored-turn rule, which A5 owns (defect 1), and `whileAMotionPlaysTheFacingHoldsOnceAuthoredTurnsAreResolved` records the end-to-end expectation
  as a known issue for A5 to turn into a plain assertion. Decision needed from the plan maintainer if it should land sooner, with that parity scene excepted.

**A3 tests** (Linux, Swift 6.3.3, debug; with `PREVIS_GOLDENS`): 40 run, 40 passed, 0 failed, no known issues; parity 8 of 8 scenes.
BodyTests: a standing man stands at y ≈ 0 with his head top within 2 cm of 1.78 m × scale (1 and 1.2); at the `jab-cross`
extension the right wrist is ahead of the chest; in `sit` the knees are ahead of the hips; at the top of `wave` the hand is above
the head; at the `front-kick` extension the ankle is ahead of the hips; the Z overrides abduct outward on both sides; at the
`jumping-jacks` open each ankle and wrist is more than 0.1 m outside its hip and shoulder; at the `side-kick` extension the kicking
ankle is more than 0.4 m outside its hip. Quadrupeds stand on the ground facing −Z and cycle their legs at the scaled stride.
`parts.v1.json` equals a fresh `parts.ts` run (`cmp`). macOS CI: pending on the PR.

**The sign mapping (recorded as LANE-A-CORE.md asks).** Before any change, the rig as the lane document specifies it failed three
of the five facts: the jab wrist was 0.47 m *behind* the chest, the seated knees 0.40 m behind the hips, and the kicking ankle
0.77 m behind the hip. Blockout's header says a negative shoulder or hip X raises or swings forward, and a positive torso X leans
forward, but its geometry turns the other way. The fix is in one place, `PersonRig.angles(...)`: the rig keeps one convention
(positive X on a shoulder, elbow or hip swings the limb forward, negative X on the torso or head pitches forward, negative X on a
knee bends it) and maps the data to it there. The gait constants that contradicted the convention changed sign with it: sit (hips
+π/2, knees −π/2), the arm raise in gesture and fall, the slight elbow bend in walk, and the forward lean in stand, run and crouch.
Z follows the same rule: a positive shoulder or hip Z override abducts the limb outward on both sides (Blockout's table
moves it toward the body; at Jumping Jacks' open each ankle ended 0.30 m and each wrist 0.31 m *inside* its hip and shoulder, and
at Side Kick's extension the kicking ankle ended inside its hip). The Y overrides, `torsoZ` and `headZ` keep the table's signs.

**Other A3 decisions.**
- Blockout's standing figure is 0.14 × (H / 1.78) m taller than its catalog height, so the rig is built at H / 1.0787.
- Rigged parts are sized for scale 1 and the transform carries the entity scale, like static parts, so a renderer can cache one
  mesh per shape. Bob and sway amplitudes are therefore proportional to the scale.
- `prop.tree`'s tapered trunk (radius 0.18 to 0.25) is a cylinder of the mean radius, because `PartShape` has no frustum.
- The bird has no rig (out of scope), so it draws as a grey box; `bounds` come from the parts' world extents.

**A2 tests** (Linux, Swift 6.3.3, debug): `PREVIS_GOLDENS=<goldens.json> swift test --package-path app/PrevisCore --filter Parity`
passes all 8 Blockout scenes, 24 360 scalars compared, worst difference 2.8e-14 (limit 1e-9). Without `PREVIS_GOLDENS` the
parity test is skipped; 27 tests in the package pass. A deliberate mutation (dropping the camera `smoothstep`) fails it with
2560 issues. Rebased on `main` `93dbb76` and rerun there with the same result. macOS CI: pending on the PR. The app targets
(`ShotsMedia`, `ConceptStudio`) need macOS to build; the public PrevisCore API is unchanged, so only CI covers them.

**A1 review round 1** (PR #59, three P2 findings at `71ccacd`; repaired additively, each reproduced before the cure):
- r4376421686, height clamp. `LANE-A-CORE.md` says `params.height` is "folded into `placement.scale` (×h)" with no clamp;
  Blockout's 0.8–1.2 clamp is a renderer detail. Before: height 0.6 imported scale 0.8, silently. Now the supplied multiplier is
  kept. A value that cannot be a scale (≤ 0 or not finite) is ignored with a note.
- r4376421700, duration overflow. Before: `duration` 1e308 trapped (`Double value cannot be converted to Int`, Signal 4).
  Now a duration that is not finite, is negative, or exceeds `Int.max / 64` frames throws `ShotsError.importFailed` naming the shot.
- r4376421710, absent fields. Before: removing `hold` from a mark threw `keyNotFound`; 85 of the sample's non-identity key paths
  failed when removed one at a time. Now Blockout's records are read like Shots' own documents (CONTRACTS section 4): absent
  fields default (an absent `duration` gives the default frame count), `id`, `assetId` and `entityId` stay required.
  Limitation: a field present with the wrong type is still an import error.

**A1 behaviour.**
- Tolerant decoding: unknown keys are ignored and absent fields take the `Shot.make` or zero defaults; identity fields
  (`id`, `assetID`, `entityID`, `parentID`) are required and the error names them; unknown joint names are skipped.
  Every field of a fully populated document survives a round trip, so a misspelt key fails a test.
- `ContentCatalog.bundled()` fails with the file or id named when a file is unreadable or the starter set names an id the
  catalog lacks.
- Import: a scene keeps one take (Shots v1), with a note when Blockout had several; entities whose asset Shots lacks are
  dropped with their marks and a note; every dropped feature gets one note.

**Tests, A1 head** (rebased on `main` `1366c35`; Linux x86_64, Swift 6.3.3, debug): `swift test --package-path app/PrevisCore`
14 run, 14 passed, 0 failed. The four content files equal a fresh `extract.ts` run (`cmp`, 4/4). swiftlint 0.65.1 `--strict`
0 violations; swiftformat 0.64.0 `--lint` 0 files in `PrevisCore/Sources` and `PrevisCore/Tests`. The Linux builds skip
SourceKit-only lint rules and indent two non-Lane-A multi-line strings differently from macOS
(`TrainingLossMasks.swift`, `H3TrainingAdapter.swift`), so macOS CI is the reference. macOS CI: pending on the PR.

**What exists.** Every CONTRACTS section 5 declaration; real `Vec3`, `Quat`, `Mat4`, `ShotCanvas`, `FrameGrid`, `PrevisIDs`,
`PrevisScene.make`, `Shot.make`, `CameraFrame`, both samples and attribution; the skeleton evaluator (one grey box per
entity at its placement, camera at the first mark); A1's catalog and importer. Generators and the real evaluator
(`paths()`, `warnings()`, validation) are still skeletons: A2 to A5.

**See it:** `swift test --package-path app/PrevisCore`.

## Blockout reference (for independent review)

Every checkpoint is translated from, and tested against, https://github.com/wassermanproductions/blockout at
`3f2d0564fd575f70fc28e9bfaa7e94b05e3955d9` (a source checkout of that commit; verified identical to a fresh download). Sources and fixtures
used: `src/engine/{evaluate,path,easing,camera,camera-moves,action-presets,motions,gaits,random,sequences}.ts`,
`src/renderer/viewport/{builders,SceneManager}.ts` and `src/renderer/store.ts`; oracle output from `scripts/blockout/{goldens,extract,parts}.ts`;
and Blockout's own tests, ported in `ReferenceFixtureTests` and `ReferenceGeneratorTests` from `tests/unit/{evaluate,tracking,round3,audit-fixes,
camera,action-presets,camera-moves}.test.ts`. Intentional deviations, each recorded where it is made: the person rig's X and Z sign mapping,
a shot-size tilt and canvas-aware distances in `Framing`, signed root moves in `Motions`, authored-turn blending, vertical heading, one easing and
the attachment graph (A5), and the two extra warnings in the implausible-speed case. Blockout has no turn blending (`evaluate.ts` lines 215-219
and 282-285), so the reference does not decide the turn timing above.

## Notes for other lanes

- Sample camera: the sample shot uses a 20 mm lens at z = 6 pushing in to z = 4.5, because a 35 mm lens on a 640 × 1152
  portrait canvas sees only about ±0.9 m at 6 m. Entities stay within ±1.3 m.
- `ShotsDocument(version:scenes:)` and similar take required non-defaulted parameters per CONTRACTS section 1.
- From A2 the evaluator moves entities and the camera. Authored turns still snap (Blockout defect 1, fixed in A5), and
  `arriveHeading` on a shot's last mark is never visible because the clock stops at that mark's arrival, so the sample's
  final turn to face the camera shows only after A5.
- `PrevisScene.make` starts `revision` at 0.

## Open questions

- Closed by the integration owner: the store reads a version header before decoding, so no version-refusal API is added.
- Lane C accepts C2 persistence on the A1 tolerant readers.
- Closed: the Z overrides (plan maintainer's disposition, PR 65 comment 6415969304). A positive `shoulderLZ`, `shoulderRZ`,
  `hipLZ` or `hipRZ` abducts the limb outward on both sides; the lane table transcribed Blockout's renderer, which turns them the
  other way. The four signs are flipped in the same place as the X mapping, and the convention is stated once beside the override
  table in LANE-A-CORE.md. Open and separate: `torsoY` (the table keeps it; header and geometry agree, but most annotated
  keyframes pair a positive value with "twist right").
- `FrameGrid.frame(atTime:)` rounds to the nearest frame (contract does not say floor or nearest).
