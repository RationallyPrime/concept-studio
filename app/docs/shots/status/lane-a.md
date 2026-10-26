# Lane A status

| Checkpoint | State |
|---|---|
| A0 declarations | **Merged** (`de3947b`; guide frame 61 per CONTRACTS, repaired by the integration owner under a recorded two-line exception). |
| A1 content, catalog, import | **Draft PR, targeting `main`** (branch `shots/a-core-a1`, two commits rebased from `8c7815f` onto `1366c35`; `git range-diff` shows both patches unchanged). Tolerant decoding, the full catalog and `starter.v1.json`, `BlockoutImport` and `blockoutProjectJSON()`. |
| A2–A6 | Not started |

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
- The skeleton evaluator ignores time: frames differ only in `index` and `time`. Motion arrives with A2.
- `PrevisScene.make` starts `revision` at 0.

## Open questions

- Closed by the integration owner: the store reads a version header before decoding, so no version-refusal API is added.
- Lane C accepts C2 persistence on the A1 tolerant readers.
- `FrameGrid.frame(atTime:)` rounds to the nearest frame (contract does not say floor or nearest).
