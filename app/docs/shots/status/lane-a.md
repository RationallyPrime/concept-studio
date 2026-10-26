# Lane A status

| Checkpoint | State |
|---|---|
| A0 declarations | **Draft PR, stacked on W0 (PR #51, unmerged).** Base `shots/b-media`; rebase on `main` and rerun checks once W0 lands. Replaces W0's two placeholder files. |
| A1–A6 | Not started |

**Tests, A0** (unmerged-W0 verification: W0's own `Package.swift`, `LICENSE` and `NOTICE` at `4782eba`, branch head
`f1c3d51`; Swift 6.3.3 on Linux x86_64, debug build):
`swift test --package-path app/PrevisCore` — 4 tests, 4 passed, 0 failed. macOS CI on the first head reached 769 app tests
and 4 core tests passing, then strict SwiftLint failed on six issues (function length, `String(decoding:)`, four long
lines). Repaired in the next commit. Local, pinned tools run from `app/` (Linux builds of swiftlint 0.65.1 and swiftformat
0.64.0): `swiftlint lint --strict` 0 violations (SourceKit-only rules such as `statement_position` are skipped on
Linux, so CI is still the reference); `swiftformat Sources Tests PrevisCore/Sources PrevisCore/Tests --lint` applied to
the PrevisCore paths, 0 files need formatting.

**What A0 contains.** Every declaration in CONTRACTS section 5 with public memberwise initialisers. Real already:
`Vec3`, `Quat`, `Mat4` (with `inverse`), `PixelSize`, `ShotCanvas`, `FrameGrid`, `PrevisIDs`, `PrevisScene.make`,
`Shot.make`, every `CameraFrame` member, `ShotsSamples.twoPersonWalk(small:)`, `PrevisCoreAttribution`. The evaluator
is a skeleton: one grey box per entity at its placement, camera at the first camera mark. `ContentCatalog.bundled()`
reads `assets.v1.json` (the unchanged `extract.ts` output at Blockout `3f2d056`) and nothing else yet.
Generators, `BlockoutImport` and `blockoutProjectJSON()` throw `notImplemented` or return empty values; validation and
`warnings()` and `paths()` return empty.

**See it:** `swift test --package-path app/PrevisCore`. The integration test evaluates both samples at the first, guide
and last frames, projects every entity inside the canvas and checks that `ray` inverts `project`.

## Notes for other lanes

- Sample camera: the sample shot uses a 20 mm lens at z = 6 pushing in to z = 4.5, because a 35 mm lens on a 640 × 1152
  portrait canvas sees only about ±0.9 m at 6 m. Entities stay within ±1.3 m.
- `ShotsDocument(version:scenes:)` and similar take required non-defaulted parameters per CONTRACTS section 1.
- The skeleton evaluator ignores time: frames differ only in `index` and `time`. Motion arrives with A2.
- `PrevisScene.make` starts `revision` at 0.

## Open questions

- Tolerant decoding ("readers ignore unknown keys and default absent fields", CONTRACTS section 4) is not done for the
  document types in A0; synthesised `Codable` requires every non-optional key. Only `RootMove` defaults. Lane C persists
  the document, so proposal: add it in A1 alongside the importer. Say if it is needed sooner.
- `FrameGrid.frame(atTime:)` rounds to the nearest frame (contract does not say floor or nearest).
