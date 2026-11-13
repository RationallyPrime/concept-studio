# Blocking over the real location: status

Built on the branch `fable-blocks`, from the brief of 2026-11-13. How to use it: [PLATES.md](../PLATES.md).
What crosses a seam: [CONTRACTS.md](../CONTRACTS.md) sections 5.7 to 5.9, 7, 8.1 and 8.3.

| Requirement | State | Where |
|---|---|---|
| R1 The plate is the set | Built | `ShotCameraView` draws a plate shot over its plate; `PlateFit` never crops or stretches; the plate file is copied byte for byte |
| R2 The camera matches the plate | Built | `PlateSolve`, the match screen with its floor grid and reference figure; one match per plate, followed by every shot on it |
| R3 The set's pieces exist in the shot | Built | Set pieces with their own sizes; they hide what is behind them; people stand on the walkable ones |
| R4 Impossible framing is caught | Built | Staging warnings in the inspector and in `staging.txt` |
| R5 Composition guide | Built | `guides/first-f0000-composition.png`, and `-labelled` |
| R6 Staging in words | Built | Inspector panel with Copy; `staging.txt`, `staging.json` |
| R7 Sizes | Built | Canvas presets 576 × 1024, 864 × 1536, 544 × 960; key size per shot, the plate's by default |
| R13 Control fits plate and key | Built, not rendered through a model | Pose and layout omit what the set hides |
| R14 Control agrees with the key | Built | One evaluation, one camera; tested at frame 0 |
| R8 Scene view | Built | "Compare all shots…" with the framing table |
| R9 Set pieces | Built | Block, plinth, dais with steps, stairs, long table, bench, throne, wall, parapet, arch, column |
| R10 Dragons | Built | Two static bodies, wings folded and spread; sized by standing head height, 10 m at scale 1 |
| R11 Blocking from text | Built | Briefs, the solver, an offline reader and a model-backed reader; in the app and in `shots-export --block` |
| R12 Reuse across shots | Built | Shots share a take until one is given its own; plates of one set share a world through their camera positions |

**To see it:**

    swift run -c release shots-export --plate-sample <any 9:16 image> --out <dir>

writes a package for the built-in throne-room sample over your image. In the app, open a project, switch to
Shots and follow PLATES.md.

**Not done, and why:**
- **The acceptance test of the brief's section 7.** Keys with and without the guide, and the video canary,
  need the image model, a GPU pod with the H3 Fun ControlNet, and the owner's judgement. Nothing here has
  been through either model.
- **The owner's hands-on checks:** keyboard, VoiceOver and the signed sandbox build.
- **The model-backed reader of descriptions** has no test against a live provider; its validator and the
  offline reader are tested.

**Decisions taken here that the owner may want to revisit:**
- Plates and set pieces belong to a scene. A new scene on the same set starts as a duplicate of the first.
- A scene may hold several takes; the old contract said exactly one.
- The document is version 2 and the package format version 2. Older builds refuse both rather than drop
  the new fields.
- Stills use any size from 64 to 4096; video canvases keep multiples of 32 up to 2048.
- A plate's principal point is its centre, so a plate must be a whole image, not an off-centre crop.
- Exports land in the project's `Shots` folder until a scene is given its own export folder (owner's answer
  of 2026-11-13: the scene's folder in the production tree). The app has no knowledge of that tree's layout;
  the user picks the folder, and each shot gets a folder inside it.
- A plate's match can name the floor it shows (`floorLevel`) and keeps its facing in quarter turns, so a
  reverse plate and a plate taken on a dais can share a set with the first plate.

**Open questions:**
- Plates are stills (owner, 2026-11-13). A shot whose camera travels has no plate under its last frame; a
  second still at the end position covers that, with no video plate.
- How does the video graph fit a 9:16 key to a 544 × 960 canvas: crop or stretch? Shots warns about the
  0.7% difference but can't know which.
- Dragon proportions: at scale 1 (a 10 m standing head height) the spread wings are about 32 m across and the
  body about 29 m from nose to tail tip. The owner gave head heights on 2026-11-13; wingspan and length are
  still this build's guess.
