# Blockout reference kit

Tools for the Shots port (`app/docs/shots/`). Nothing here ships in the app.

| File | What it does |
|---|---|
| `fetch.sh` | Clones Blockout at `3f2d056`, the commit PrevisCore is translated from, and prints the path. Use it as `BLOCKOUT_DIR`. |
| `goldens.ts` | Builds deterministic Blockout scenes that cover every evaluator feature and writes Blockout's own `evaluate(t)` output at every frame. This is the parity oracle for the Swift evaluator. |
| `extract.ts` | Writes the content resources (`motions.v1.json`, `assets.v1.json`, the two catalogs) and `golden-vectors.v1.json` (camera-move and action-path outputs for parity). |
| `parts.ts` | Runs Blockout's own builders against a recording stand-in for three.js and writes `parts.v1.json`: the starter static assets as flat `PartSpec` records. Fails on a shape `PartShape` cannot express; a tapered cylinder (the tree trunk) becomes a cylinder of the mean radius and is reported. |
| `seed/` | A scratch Swift translation of the evaluator and its kernels that already matches `goldens.ts` (worst difference 8.9e-16). Lane A starts from it. Not compiled by any target. |

```bash
export BLOCKOUT_DIR=$(scripts/blockout/fetch.sh)
bun run scripts/blockout/goldens.ts "$TMPDIR/shots-goldens.json"
bun run scripts/blockout/extract.ts "$TMPDIR/shots-content"
# parts.v1.json, for the starter static assets listed in app/docs/shots/README.md:
bun run scripts/blockout/parts.ts "$TMPDIR/parts.v1.json" vehicle.sedan vehicle.bus furniture.bed furniture.couch \
  furniture.chair furniture.diningTable furniture.desk furniture.door furniture.window prim.cube prim.cylinder \
  prim.wall prim.stairs prim.ramp prop.tree
```

The Blockout checkout is reference material. Read it and import its engine modules by path. Never run `npm`,
its package scripts or its app from it.

The four content files (`motions.v1.json`, `assets.v1.json`, `camera-moves.catalog.v1.json`,
`action-presets.catalog.v1.json`) are copied unchanged into `app/PrevisCore/Sources/PrevisCore/Resources/`.
`golden-vectors.v1.json` and the goldens are test inputs and are not committed. The parity tests read them
from the paths in `PREVIS_GOLDENS` and `PREVIS_VECTORS`, and skip when those are unset. They reach
PrevisCore's internal Blockout-shaped entry points with `@testable import`.

Licensing: the seed and the extracted data are Apache-2.0 derivatives of Blockout. See `LICENSE` and
`NOTICE` (Sam Wasserman).
