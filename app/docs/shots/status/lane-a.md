# Lane A status

| Checkpoint | State |
|---|---|
| A0 declarations | **Merged** (`de3947b`; guide frame 61 per CONTRACTS, repaired by the integration owner under a recorded two-line exception). |
| A1 content, catalog, import | **Merged** (PR #59, `93dbb76`; round 1 repaired in `913fd2b`, closed by independent review). |
| A2 evaluator parity and paths | **Merged** (PR #64, `89d9e7d`). Real `ShotEvaluator` (legs, paths, easing, holds, joint blending, boarding and attachments as Blockout's four passes, camera lens, aim lock, mount, rig noise), `EntityFrame.joints` and `speed`, `paths()`, and the parity test. |
| A3 bodies | **Merged** (PR #65, `0bdb09a`; two review rounds: the quadruped gait scale and the outward Z overrides). |
| A4 generators | **Draft PR, targeting `main`** (branch `shots/a-core-a4`, three commits on `0bdb09a`). `CameraMoves` (20 starter moves), `ActionPaths` (14), `Motions.apply` and `overlay`, `Framing` (all ten kinds) and `Attachments`. |
| A5–A6 | Not started |

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
