# Lane A status

| Checkpoint | State |
|---|---|
| A0 declarations | **Merged** (`de3947b`; guide frame 61 per CONTRACTS, repaired by the integration owner under a recorded two-line exception). |
| A1 content, catalog, import | **Merged** (PR #59, `93dbb76`; round 1 repaired in `913fd2b`, closed by independent review). |
| A2 evaluator parity and paths | **Merged** (PR #64, `89d9e7d`). Real `ShotEvaluator` (legs, paths, easing, holds, joint blending, boarding and attachments as Blockout's four passes, camera lens, aim lock, mount, rig noise), `EntityFrame.joints` and `speed`, `paths()`, and the parity test. |
| A3 bodies | **Draft PR, targeting `main`** (branch `shots/a-core-a3`, rebased onto A2's merge `89d9e7d`). The person rig with COCO-18 keypoints, the dog, cat and horse rig, `parts.v1.json` for the 15 starter static assets (made by `scripts/blockout/parts.ts`), the grey-box fallback, `bounds` and `isActor`. |
| A4–A6 | Not started |

**A3 tests** (Linux, Swift 6.3.3, debug; with `PREVIS_GOLDENS`): 37 run, 37 passed (one known issue, the Z-override question below), 0 failed (parity still 8 of 8 scenes). BodyTests: a
standing man stands at y ≈ 0 with his head top within 2 cm of 1.78 m × scale (1 and 1.2); at the `jab-cross` extension the right
wrist is ahead of the chest; in `sit` the knees are ahead of the hips; at the top of `wave` the hand is above the head; at the
`front-kick` extension the ankle is ahead of the hips. Quadrupeds stand on the ground facing −Z. `parts.v1.json` equals a fresh
`parts.ts` run (`cmp`). macOS CI: pending on the PR.

**The sign mapping (recorded as LANE-A-CORE.md asks).** Before any change, the rig as the lane document specifies it failed three
of the five facts: the jab wrist was 0.47 m *behind* the chest, the seated knees 0.40 m behind the hips, and the kicking ankle
0.77 m behind the hip. Blockout's header says a negative shoulder or hip X raises or swings forward, and a positive torso X leans
forward, but its geometry turns the other way. The fix is in one place, `PersonRig.angles(...)`: the rig keeps one convention
(positive X on a shoulder, elbow or hip swings the limb forward, negative X on the torso or head pitches forward, negative X on a
knee bends it) and maps the data to it there. The gait constants that contradicted the convention changed sign with it: sit (hips
+π/2, knees −π/2), the arm raise in gesture and fall, the slight elbow bend in walk, and the forward lean in stand, run and crouch.
The Y and Z overrides keep the signs of the lane document's table; no test exercises them, and Blockout's own header says "positive =
outward" for the Z overrides where its table moves the limb inward. That is an open question below.

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
- Z overrides (needs the owner or plan maintainer). The contract text is LANE-A-CORE.md, "Joint overrides": `shoulderLZ` adds to
  shoulderL `.z`, `shoulderRZ` subtracts from shoulderR `.z`, `hipLZ` adds to hipL `.z` and `hipRZ` subtracts from hipR `.z`. A3
  follows it exactly, as Blockout's `animatePerson` does. With Euler XYZ a positive Z on a hanging limb moves its end toward +X, so
  the table moves the left limbs and the right limbs toward the body, while Blockout's header for these overrides says "positive =
  outward" (`builders.ts`, `AnimInput.overrides`). Observed: with all four set to 0.5, each wrist ends 0.31 m and each ankle 0.37 m
  *inside* its own shoulder or hip. `BodyTests.zOverridesMoveLimbsOutwardAsBlockoutsHeaderSays` asserts the header's expectation
  under `withKnownIssue`: it passes today as a known issue and reports an unexpected pass once the sign is changed. Options: keep
  the table (current), or flip the four signs in `PersonRig.angles` and amend the table in a `[contract]` PR. No data or test
  depends on it today (`wave` swings `shoulderRZ` symmetrically).
- `FrameGrid.frame(atTime:)` rounds to the nearest frame (contract does not say floor or nearest).
