# Lane A: PrevisCore

**Seat:** Gnomon or Theo, one at a time. **Package:** `app/PrevisCore/` (library `PrevisCore`, tests
`PrevisCoreTests`), plus `scripts/blockout/`.

**Mission.** Build the pure Swift engine every other lane builds on. Translate Blockout's engine, extract
its data, add posed geometry, and fix the defects listed below. This lane has an oracle: Blockout's own
TypeScript produces the expected answers, and the seed in `scripts/blockout/seed/` already matches them.

**Machine.** PrevisCore is a standalone, Foundation-only package, so this lane can work on Linux with a
Swift 6 toolchain (CI uses Swift 6.3) or on a Mac. Everything here verifies with
`swift test --package-path app/PrevisCore`, plus bun for the reference scripts. CI checks macOS on every
PR.

**Read first:**
- [CONTRACTS.md](CONTRACTS.md), sections 1–5 and 8–10. Section 5 is your public API.
- [SHOTS-PLAN.md](../SHOTS-PLAN.md) sections 3–4.
- [scripts/blockout/README.md](../../../scripts/blockout/README.md).
- Blockout's `src/engine/`, from `scripts/blockout/fetch.sh`.

**Rules:**
- Foundation only, `Double` throughout, `Sendable` value types.
- The seed caches values in mutable classes (noise lattices, board offsets). Turn those into pure
  functions, or into caches built in initialisers.
- Every translated file starts with:
  ```swift
  // Translated from Blockout (https://github.com/wassermanproductions/blockout) src/engine/<file>.ts at 3f2d0564,
  // Apache-2.0, by Sam Wasserman (wassermanproductions.com). Changes: <one line>. See Resources/NOTICE.
  ```

## Checkpoints

Each checkpoint is one PR, ending in something you can run and someone else can check.

### A0: declarations (first 2–3 hours after W0; every lane waits for it)

**Deliver:**
- Every declaration in CONTRACTS section 5, compiling, with public memberwise initialisers.
- No crashing stubs: unimplemented functions throw `ShotsError.notImplemented` or return empty values.
- These must already be real, because other lanes use them on day 1:
  - `Vec3`, `Quat`, `Mat4` (including `inverse`), `PixelSize` and `ShotCanvas`;
  - `FrameGrid` (including `snapUp`) and `PrevisIDs`;
  - `PrevisScene.make` and `Shot.make`;
  - every `CameraFrame` member: `make`, the matrices, `project`, `ray`, and the field of view with the
    sensor gate;
  - `ShotsSamples.twoPersonWalk(small:)`, both sizes, with fixed ids;
  - `PrevisCoreAttribution`, reading the bundled `NOTICE` and `LICENSE` that W0 commits.
- An evaluator stub that returns a `SceneFrame` in which every entity is one grey box (footprint ×
  height) at its placement, and the camera sits at the first camera mark.
- `ContentCatalog.bundled()` reading a minimal `assets.v1.json`.

**Verify:** `swift test --package-path app/PrevisCore` passes one integration test. It evaluates both
samples at their first, guide and last frames, checks every entity projects inside the canvas, and checks
that `ray` inverts `project`. The PR's CI run is green.

**Unblocks:** B0, C0, D0.

### A1: content, catalog and Blockout import (day 1)

**Deliver:**
- The four `extract.ts` resource files, copied into `Resources/`.
- `starter.v1.json`, with the first set from [README.md](README.md).
- `ContentCatalog.bundled()`, failing loudly on a missing file or id. `RootMove.forward` and `up` default
  to 0 when absent: many keyframes in the data omit one of them.
- `BlockoutImport`:

| Blockout | Shots |
|---|---|
| `duration` d | `frameCount = FrameGrid.snapUp(round(d·24) + 1)` |
| `aspect` 9:16 / 16:9 / 1:1 / 4:3 / 2.39:1 | canvas 640×1152 / 1152×640 / 768×768 / 1024×768 / 1536×640 |
| `params.height` h on a person | folded into `placement.scale` (×h) |
| `transform.rotationY` | `placement.heading` |
| `attachedTo` + `attachedLocal {x,y,z,rotY}` | `EntityAttachment` (offset, rotation = yaw) |
| mark `attachTo` | `boardID` |
| `trackEntityId` / `mountEntityId` | `trackIDs` = [id] / `mountID` |
| sky lighting presets, `club` | nearest non-sky preset |
| drafts, camera banks, scans, references, environment settings, profiles | dropped, one note each |

- `ShotsSamples.blockoutProjectJSON()`, a small Blockout-format project you write: two actors and a camera
  move.

**Verify:**
- Rerunning `extract.ts` into a temp folder and comparing the four resource files with `Resources/` shows
  no difference.
- An integration test decodes the catalog, resolves every starter id, imports `blockoutProjectJSON()`,
  evaluates every shot without error, and finds a note for each dropped feature.
- No tests that count records: the data is the source of truth.

**Unblocks:** A2 (parity decodes through the importer), B4, C3, and the C5 pickers.

### A2: evaluator parity and paths (days 1–2)

**Deliver:**
- Port the evaluator from the seed onto the contract types:
  - legs, paths, easing, holds and joint blending;
  - boarding (`boardID`) and attachments, kept as Blockout's four passes for now;
  - the camera: lens, aim lock (several `trackIDs` aim at their midpoint), mount, rig noise and field of
    view.
- `EntityFrame.joints` and `speed`.
- `paths()`.
- A parity test, enabled only by `PREVIS_GOLDENS`. It decodes each Blockout scene with `BlockoutImport`
  (`keepIDs: true`) and compares every sample per entity id: positions, headings, joints and the
  camera.

**Verify:** `PREVIS_GOLDENS=$TMPDIR/shots-goldens.json swift test --package-path app/PrevisCore --filter Parity`
passes all 8 scenes within 1e-9.

Two differences from Blockout are handled through an internal initialiser reached with `@testable`:
- **Duration.** Compare only samples with 0 ≤ t ≤ the Blockout duration, because import rounds the frame
  count up.
- **Aspect.** Construct with Blockout's exact aspect, because the importer maps aspects onto 32-multiple
  canvases.

**Unblocks:** B3 (real motion), D2 (ribbons).

### A3: bodies (day 2)

**Deliver:**
- **The person rig:** posed parts and COCO-18 keypoints, per the spec below.
- **The quadruped rig:** dog, cat and horse.
- **Static assets:** `parts.v1.json` for the starter static assets, transcribed from Blockout's
  `src/renderer/viewport/builders.ts`, with loops written out. No expression language.
- **Fallbacks:** a grey box for assets without parts.
- **`bounds` and `isActor`.**

**Verify** with numeric behaviour tests on posed bodies. Each is a real-world fact, not a restatement of
data. Pose each test body by putting a motion's peak keyframe joints on a mark.
1. A standing man has his feet at y ≈ 0 and his head top within 2 cm of 1.78 m × scale. Blockout's rig
   overshoots by 0.14 m; scale the rig to the catalog height.
2. At the extension keyframe of `jab-cross`, the punching wrist is ahead of the chest along the facing
   direction.
3. In `sit`, the knees are ahead of the hips.
4. At the top of `wave`, the hand is above the head.
5. At the extension of `front-kick`, the kicking ankle is ahead of the hips.

If 2–5 fail, the motion data and the rig disagree on the sign of X rotations. Blockout's motion header
documents the opposite of what its geometry does. Fix it in one place, the rig's sign mapping, and record
it in your status file.

**Unblocks:** B3 (pose and mattes), D2.

### A4: generators (days 2–3)

**Deliver:**
- **`CameraMoves`:** all 39 moves, or at least the 20 starter moves. Several subjects act as a virtual
  subject at their midpoint, with height the maximum of theirs.
- **`ActionPaths`:** the 14 starter paths, with the speed option.
- **`Motions.apply` and `Motions.overlay`.** Overlay samples the upper-body motion at the travel track's
  times and keeps its legs.
- **`Framing`.** Port Blockout's placement code from `SceneManager.ts` (shot sizes around lines
  1416–1470, the two-shot framer around 1650, `frameSubject` in `camera.ts`). Fix the dead tilt and make
  the distances aware of the canvas aspect.
- **`Attachments`.**

**Verify:**
- `PREVIS_VECTORS=$TMPDIR/shots-content/golden-vectors.v1.json swift test --package-path app/PrevisCore --filter Vectors`:
  generators match within 1e-9 when `speed` is nil.
  - The vectors use analytic subject paths that no document can express.
  - So test them through an internal entry point that takes a subject function, reached with
    `@testable`. The public API wraps it.
- For every `Framing.Kind` on the sample, every subject projects inside the canvas, and the two-shot holds
  both.
- Overlaying `wave` on a walk leaves positions unchanged, while the right arm follows the wave.

**Unblocks:** C5.

### A5: corrections (day 3)

**Deliver:**
- **Turn blending.** An authored turn blends over the hold before its mark, or over the whole leg when
  there is no hold.
- **Vertical moves** keep their heading.
- **One attachment graph,** resolved in dependency order with full transforms. Boarding resolves after
  attachment.
- **`ShotsValidation` and the evaluator's warnings.**
- **Easing.** One easing for position and orientation, documented in the code.

**Verify** with the handful of behaviour tests this lane keeps:
- heading changes monotonically through a blended turn;
- a vertical rise keeps its heading;
- an 8-deep attachment chain in reverse document order lands every child;
- boarding a cart attached to a moving truck follows the truck;
- an attachment cycle is an error naming both entities;
- an unknown gait or asset is an error naming it.

Parity stays green on scenes that don't use the changed features.

**Unblocks:** C5's problem display.

### A6: hardening (day 4)

**Deliver:**
- A timing test gated by `SHOTS_TIMING=1`, for the budgets in CONTRACTS section 10.
- Fixes for whatever B, C and D report.
- Every translated file carries its header.

**Verify:** every lane's integration tests are green. Lane B runs
`SHOTS_TIMING=1 swift test -c release --package-path PrevisCore --filter Timing` on a Mac and records
`init` under 5 ms and `frame` under 2 ms in its status file. CI doesn't run timing tests.

## Porting facts

**The evaluator** (the seed implements all of this; keep it when adapting):
- **Legs.**
  - Sort marks stably by `(time, index)`.
  - `depart = min(from.time + from.hold, max(from.time, to.time − 0.1))` and
    `arrive = max(to.time, depart + 0.001)`.
  - The path runs through `[from] + via + [to]`.
- **Path.** Centripetal Catmull-Rom (alpha 0.5) with reflected phantom end points. Sample 32 times per
  segment; `pointAt` interpolates linearly on cumulative chord length.
  - `headingAt` is a central difference with `eps = max(length·0.001, 0.01)`, giving
    `atan2(−dx, −dz)`.
  - If both differences are below 1e-9 it returns 0 (defect 2).
- **Easing.** `easedProgress(u, a, b)`, where a = the departing mark's `easeOut` and b = the arriving
  mark's `easeIn`.
  - If `a + b > 0.98`, scale both to sum to 0.98. Let `v = 1/(1 − a/2 − b/2)`.
  - Then: `u < a` gives `v·u²/(2a)`; `u > 1 − b` gives `1 − v(1−u)²/(2b)`; otherwise `v·a/2 + v(u − a)`.
  - Orientation and lens additionally apply `smoothstep` (defect 6).
- **Camera.**
  - Field of view: `vfov = 2·atan(min(sensorH, sensorW/aspect) / (2·f))`.
  - Sensors (w × h mm): super16 12.52×7.41, super35 24.89×18.66, fullFrame 36×24, imax65 52.63×23.01.
  - The aim point is `subject.position + (0, 0.8·height, 0)`. Mounted marks are local to the mount, and
    `pan += mount.heading`.
- **Rig noise.**
  - mulberry32 with exact UInt32 arithmetic (`&+`, `&*`).
  - The lattice hash is `ToUint32(seed·2654435761) ^ ToUint32(channel·40503) ^ ToUint32(i·2246822519)`.
    Those products are **Double** multiplications, then JavaScript's ToUint32, as in `seed/Kernels.swift`.
    Integer maths diverges for seeds above about 3.4 million.
  - Rig table (position amplitude, rotation amplitude, Hz, octaves): sticks 0/0/0/1,
    dolly .005/.0005/.4/1, steadicam .03/.004/.5/2, handheld .045/.018/1.8/3, crane .01/.001/.3/1,
    drone .05/.002/.25/2, carMount .02/.006/2.5/3.
- **Gait phase.** `(distanceTravelled / (stride[gait] · max(scale, 0.2))) mod 1`. Strides: walk 1.45,
  jog 2.0, run 3.6, crouch 0.9 metres.

**The person rig** (Blockout `builders.ts` lines 176–421):
- **Proportions.** `H` = asset height × scale and `s = H/1.78`; `legLen = .47H`, `headR = .065H`,
  `torsoLen = H − legLen − 2·headR`, `bodyW = .34·s`.
- **Hierarchy.** Pivots are groups with Euler XYZ rotation; forward is −Z.
  ```
  root                      lie, fall, sit and crouch move this
  └ pelvis   y = legLen        box(bodyW, .18s, .2s) at y .02s
    ├ torso  y = .08s          capsule(r bodyW/2, len .7·torsoLen) at y .5·torsoLen
    │ ├ head  y = torsoLen     neck cylinder r .05s h .08s at y .04s; head sphere r headR at y headR+.06s
    │ ├ shoulderL (−.55·bodyW, .92·torsoLen, 0)   upper arm capsule r .055s, len .7·upper, at y −.5·upper (upper = .5·torsoLen)
    │ │ └ elbowL  y = −upper                       forearm capsule r .9·armR, len .7·lower (lower = .48·torsoLen)
    │ └ shoulderR (+.55·bodyW, …)                  mirror
    ├ hipL (−.28·bodyW, 0, 0)  thigh capsule r .075s, len .7·upperLeg, at y −.5·upperLeg (upperLeg = .52·legLen)
    │ └ kneeL  y = −upperLeg   shin capsule r .85·legR, len .7·lowerLeg (lowerLeg = .48·legLen); foot box(2·legR, .06s, .22s) at (0, −lowerLeg+.03s, −.05s)
    └ hipR (+.28·bodyW, …)     mirror
  ```
- **Joint overrides,** added after the gait pose (`−=` applies the value negated):

| Joint | Group, axis | Applied |
|---|---|---|
| shoulderLX / shoulderRX | shoulder `.x` | `+=` |
| shoulderLZ | shoulderL `.z` | `+=` |
| shoulderRZ | shoulderR `.z` | `−=` |
| elbowL / elbowR | elbow `.x` | `−=` |
| hipLX / hipRX | hip `.x` | `+=` |
| hipLZ / hipRZ | hipL `.z` `+=`, hipR `.z` `−=` | mirror |
| kneeL / kneeR | knee `.x` | `−=` |
| torsoX / torsoY / torsoZ | torso `.x` `+=`, `.y` `+=`, `.z` `−=` | |
| headX / headY / headZ | head `.x` `+=`, `.y` `+=`, `.z` `−=` | |

- **Gait poses.** Let `p` be the phase and `swing = sin(2πp)`.
  - **stand / gesture:** `root.y = sin(1.5t)·.005`. Gesture adds `shoulderR.x −2.3`,
    `elbowR.z sin(2t)·.3` and `elbowR.x −.4`.
  - **walk / jog / run:** amplitude `.5/.8/1.1` and bob `.02/.04/.06`.
    - `hipL.x = swing·amp` and `hipR.x = −hipL.x`.
    - `shoulderL.x = −.8·hipL.x` and `shoulderR.x = +.8·hipL.x`.
    - `kneeL.x = −max(0, −sin 2πp)·.8` and `kneeR.x = −max(0, −sin(2πp+π))·.8`.
    - Elbows at `−.3`, and `root.y = |swing|·bob`. Run adds `torso.x += .15`.
  - **crouch:** `root.y = −.3·legLen`, hips `.9`, knees `−1.4`, torso `+.3`; when moving, the hips add
    `±swing·.25`.
  - **sit:** `root.y = −(legLen − .45s)`, hips `−π/2`, knees `+π/2`.
  - **lie:** `root.x = −π/2`, `root.y = .18s`, `root.z = .5·legLen`.
  - **fall:** `root.x = 1.4`, `root.y = .25s`, `root.z = −.3·legLen`, shoulders `−2.2`, `hipL.x .3`,
    `hipR.x −.2`.
- **Keypoints:**
  - **Joints:** neck at the torso top between the shoulders. The shoulder, elbow, hip and knee
    keypoints sit at their pivots.
  - **Ends:** wrists at the end of the forearm, ankles at the end of the shin.
  - **Face:** nose at the front of the head sphere along the facing direction, eyes and ears on the head
    sphere either side.
  - **Sides:** "right" is the character's right, the `R` joints.

**The defects,** numbered as in [SHOTS-PLAN.md](../SHOTS-PLAN.md) section 4:
- **Fixed in A5:**
  - 1: authored turns snap.
  - 2: vertical moves face −Z.
  - 3: fixed-pass attachments, and boarding resolved before attachment.
  - 4: yaw-only attachment.
  - 5: shallow validation.
  - 6: two easing curves.
- **Kept, with a warning:** 7, coincident marks teleport and pan takes the shortest arc only.
- **Fixed in A4's `Framing`:** 8, the dead tilt, and 9, absolute camera distances.

**Swift traps:**
- Swift's `sort` isn't stable, so sort by `(time, index)`.
- Dictionaries are unordered; outputs follow document order.
- `JSONEncoder` differs byte-wise from Blockout's (`-0`, exponents, slash escaping); aim for semantic round
  trips.
- Seeds are `Double` and can exceed 2^32.

## Out of scope

The choreography scheduler, dance and chase content, environment kits, sky presets, splats, depth, wheel
spin, and the bird rig unless time allows.
