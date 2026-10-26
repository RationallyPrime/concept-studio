# Shots: porting Blockout's previs into ConceptStudio to prepare H3 assets for ComfyUI

Status: **proposal, 2026-10-25.** Nothing here is built. Section 10 lists the decisions that belong to
the owner, and section 11 lists the open questions. Everything else is engineering inside those
decisions.

**Scope.** Shots creates and prepares assets for MiniMax H3 shots that are then generated in ComfyUI.
ConceptStudio does not run ComfyUI or H3, and does not generate video. The user carries each exported
package into their own ComfyUI graphs. Shots is nevertheless designed so that generation could be added
later as a new consumer of the same package, without changing what is built here (section 7).

**Execution.** The build runs as four parallel lanes over five days: see [shots/README.md](shots/README.md),
with every cross-lane interface in [shots/CONTRACTS.md](shots/CONTRACTS.md). That plan supersedes the
phase order and the engineer-day sizes in section 8 below. This document remains the reasoning behind it.

**Reference code.** [Blockout](https://github.com/wassermanproductions/blockout) at `3f2d056`, an
Electron/TypeScript/three.js previs tool by Sam Wasserman, licensed Apache-2.0. ConceptStudio at
`6a24082`.

**Evidence.** Claims about Blockout's code, ComfyUI's H3 nodes, ConceptStudio and Apple's APIs were
checked against source or small probes. Three things are not yet verified: the community keyframe
ControlNets mentioned in section 2, RealityKit on macOS 15, and rendering inside the sandbox. Every size
in section 8 is this plan's own estimate.

## 1. What Shots would be

Shots would be a workspace in which you block a shot in grey-box 3D. You place people and simple set
pieces, drop timed marks for where each one goes, and move a virtual camera with real lens maths. The
app then exports a package for ComfyUI containing:

- guide images for the first, last and key frames, all from one camera path so they agree with each
  other;
- the exact frame index of every guide on H3's frame grid, with a frame count and canvas size that
  match the H3 graph;
- pose and layout videos for H3's Fun ControlNet, plus pose or depth stills for keyframe composition;
- per-actor mattes for masked passes;
- a structured H3 prompt built from the facts of the shot;
- a machine-readable description of the shot (camera path, marks, guide indices).

Blockout already solves the hard parts of authoring a shot. What it lacks is an export that fits H3 and
ComfyUI. This adds a new purpose to ConceptStudio, preparing shots alongside training adapters, which
PRODUCT.md does not cover today (decision 1).

## 2. Which assets matter for H3

An earlier analysis built everything around H3's **Ref2VA** route: render the previs as an RGB movie and
give it to H3 as a motion reference. The evidence points elsewhere.

- **Shots targets a keyframe-first workflow.** Finished first and last frames are made separately with
  an image model. ComfyUI's native H3 nodes then animate between them on the FL2VA checkpoint
  (first/last frame to video and audio), adding guide frames mid-shot where needed.
- **Ref2VA is the loosest route.** SGLang's H3 documentation says Ref2VA "can resynthesize or reorder
  motion and cuts" and has no strength control. It also needs a different checkpoint from the one
  ConceptStudio's adapters are trained on.
- **A control-video route exists.** Alibaba PAI's `MiniMax-H3-Fun-Controlnet-Union` comes in two
  versions: v1 covers canny, depth, HED, MLSD and pose, and v2.0 adds scribble, layout and gray. It has a
  native ComfyUI node built to coexist with FL2VA keyframes, because keyframe rows get zero control. It
  exposes strength and start/end controls, and it stays on the adapters' checkpoint. No published
  example yet combines it with keyframes *and* a likeness adapter.

So the assets worth producing, ranked by expected payoff against risk:

| Rank | Asset | Where it goes in ComfyUI | Risk |
|---|---|---|---|
| 1 | Consistent first/last/key guide stills (pose or depth variants), their exact frame indices, camera and staging facts | Keyframe composition, plus FL2VA with several guide frames | Low on the H3 side. Keyframe composition from pose or depth stills relies on community ControlNets for the image model, which are unverified |
| 2 | Pose or layout **video** from the evaluated skeleton and actor boxes | H3 Fun ControlNet in the same FL2VA graph | Medium: permitted by the code, unmeasured with likeness adapters |
| 3 | RGB previs movie | Ref2VA as a motion reference | High: loose, different checkpoint, adapter transfer unknown |
| — | Normal pass, Blockout's prompt text, Blockout's Comfy JSON | Nothing | Discard |

Grey-box RGB or depth used as strong control fights the real location and the finished keyframes,
because the mannequins and boxes don't match them. Pose and layout carry the blocking without imposing
geometry. Depth helps only when the grey-box set is aligned to the real location. Phase 0 measures this
before anything is ported.

## 3. Keep, defer or discard: the Blockout inventory

Blockout is about 34,900 lines of TypeScript. The pure engine is 16,074 lines, 9,575 of them in one
motion-data file.

| Area | Size | Verdict | Notes |
|---|---|---|---|
| Core: types, evaluator, paths, easing, camera optics, rigs, PRNG/noise, gaits, schema | 1,757 lines | **Port** | About 1,200 lines of Swift. A scratch Swift port already reproduces the TS engine (section 4) |
| Motion library | 194 motions, 156 KB as JSON | **Keep as data** | Pure data: 939 keyframes over 18 joints. Which categories ship first is decision 4 |
| Camera moves | 39 generators, 1,498 lines | **Port as code** | Roughly three subject-relative families (33 moves) plus six fixed-camera or one-off scripts; the grouping is a reading, not verified. About 450–600 Swift lines |
| Action paths (people, vehicles, birds, aircraft) | 33 generators, 1,187 lines | **Port about 14** | Only walk and run are speed-based. Elsewhere speed scales with shot length (a 5 s horse gallop averages 24.5 m/s), so add a speed parameter |
| Choreography (dance, fight, chase) | 1,055 lines | **Defer, then redesign** | Ignores the requested duration: 8 s fights end as late as 9.7 s, any dance lasts at least 4.14 s, and fights of 2 s or less leave one fighter with no marks. Keep the fight vocabulary and pairing tables, but write a new time-budgeted scheduler |
| Older crowd "sequences" | 412 lines | **Discard** | Superseded by choreography |
| Asset catalog | 205 entries | **Keep as data, port about 20** | 183 have no animation. About 60% are plain primitive assemblies, and about 25% need a small generator (repeat, mirror). No creature larger than a horse, and no arches or parapets |
| Mannequin rig | 246 lines | **Port, after a sign check** | Joint hierarchy, proportions and gait poses are fully specified in the source |
| Other asset builders | about 6,000 lines | **Defer** | Rebuild as a small parts format item by item, not line by line |
| Export loop, stills, metadata | about 530 lines | **Port the logic, rewrite for H3 and ComfyUI** | Frame law, endpoint rule, metadata and labels all change (section 4) |
| Store, undo, control handler | about 1,900 lines | **Port the design** | One mutation choke point and an undo snapshot per edit. The 33 control actions become a typed command surface |
| UI panels (inspector, timeline, library, rail) | about 3,700 lines | **Rebuild natively** | Keep the interaction ideas: mark pills, drag to retime, stretch for hold, a take bar, a look-through camera |
| Populate-from-image (one vision call) | 313 lines | **Defer** | Cheap later on ConceptCore's model clients |
| Live puppeteering and camera recording | about 200 lines | **Defer** | Useful once marks work |
| Gaussian splat scans, glTF/Blender handoff, animatic, contact sheet | | **Defer** | Splats are already excluded from Blockout's exports |
| Generator profiles (9), prompt compiler, Comfy exporter, normal pass, FFmpeg, Electron, Windows/Linux packaging | | **Discard** | The Comfy exporter writes neither of ComfyUI's two graph formats. The prompt contradicts MiniMax's official prompt structures. AVFoundation replaces FFmpeg |

## 4. Hard problems borrowed from Blockout, and the corrections they need

### What carries over

- **One pure evaluator.** `state(t)` gives every actor's position, heading, gait, distance travelled
  and joint pose, plus the camera's position, orientation, focal length and field of view. Playback,
  scrubbing, stills and export all call it, and nothing accumulates from frame to frame.
- **Marks as legs.** Each pair of marks is a leg: a hold, then a trapezoidal-velocity ease along a
  centripetal Catmull-Rom path sampled by arc length. Heading follows the path tangent. A hold is
  shortened so that at least 0.1 s of travel remains.
- **Scene, take and shot are separate.** The scene owns actors and blocking, and each shot owns a
  camera. Covering one performance from several angles costs nothing extra.
- **Camera optics.** Real sensor sizes, focal length to vertical field of view, and crop-to-aspect that
  never exceeds the sensor gate (portrait uses the full gate height). Aim lock re-aims every frame at a
  point 0.8 of the subject's height. Seeded rig noise (handheld, steadicam, drone and others) is
  stateless in time.
- **Camera moves read the subject only through `subjectAt(t)`.** A virtual subject therefore needs no
  changes to the generators: for example, the midpoint of two fighters, or a rider on a mount.
- **Motion data.** Each motion keyframe holds a full pose over the joints it touches, so linear
  interpolation is safe. Root motion is a forward/up offset along the heading.
- **Export discipline.** Frames are sampled at exact times, and stills and video come from the same
  evaluation. Blockout hides editor chrome by toggling visibility, which leaks in two places
  (multi-selection boxes, the top-down render). The port should build each pass from a description of
  that pass instead.

**The core reproduces cheaply.** A 379-line scratch Swift port of the evaluator and its kernels was
compared with the TS engine on 8 scenes, covering about 24,700 sampled values plus the kernel tables.
One value differed, by 8.9e-16, from a sin/cos rounding. The real port should agree within 1e-9.

One trap: the noise hash multiplies seeds as IEEE doubles and then applies JavaScript's ToUint32. Swift
must do the same, or handheld shake differs from Blockout for seeds above about 3.4 million.

### Defects to fix deliberately, after a faithful port

1. **Authored turns snap.** A turn authored on a mark is never blended: the figure snaps on arrival,
   and mid-leg it falls back to its original rotation. Proposed behaviour: blend the turn over the hold
   before the mark, or over the leg when there is no hold.
2. **Vertical moves lose their heading.** A purely vertical move forces the heading to face −Z.
3. **Attachment order is wrong.** Attachment chains resolve in a fixed four passes, so chains deeper than
   four, in reverse document order, land in the wrong place. Boarding also resolves before attachment,
   so boarding a vehicle that is itself attached uses the vehicle's stale position. Replace both with
   one validated attachment graph, resolved in dependency order.
4. **Attachments carry position and yaw only.** That is enough for walking and vehicles but not for a
   rider on a banking mount. The Swift attachment type should carry a full transform from the start,
   even if the first UI exposes yaw only.
5. **Validation is shallow.** Documents that pass it can crash the evaluator (unknown rig, sensor or
   gait; missing transform) or produce NaN (unknown aspect). Use typed decoding plus semantic checks:
   every reference resolves, attachments have no cycles, and numbers are finite.
6. **Two easing curves.** Position uses one easing curve, while orientation and lens add a second on
   top, so a "linear" zoom is not linear. Choose one behaviour and document it.
7. **Teleports and short pans.** Marks at the same time teleport within 1 ms, and pan takes the
   shortest arc only, so it can't whip past 180°. Keep both behaviours, but warn in the UI.
8. **Framing never tilts.** Auto-framing computes its tilt from a value that is always zero. That code
   lives in Blockout's viewport layer, which the framing tools port separately.
9. **Camera distances don't scale.** Camera-move distances are absolute metres, unscaled by aspect or
   subject size, which matters for portrait shots and large subjects.

### Corrections in the export and content layers

- **Frames come first.** H3 takes 17k+5 frames at 24 fps. Blockout computes `round(duration × fps)` from
  durations edited in 0.1 s steps, which can never produce 39, 124 or 243 frames. A shot therefore
  stores a frame count, and its duration is derived from it:
  - frame *i* samples t = i/24;
  - the last frame samples (N−1)/24, and the last guide still is exactly that frame;
  - ComfyUI's H3 node calls 124–362 frames the trained range, so warn outside it.
- **Canvas.** The export canvas is the generation canvas, with width and height multiples of 32, set per
  shot. 640 × 1152 and 768 × 1344 are typical portrait sizes. ComfyUI's rule "short edge 768, area at
  most 768 × 1344" applies only when resizing Ref2VA reference videos.
- **Labels off in guide stills.** Blockout keeps label sprites in stills unless labels are switched off,
  and H3 and image models reproduce visible text.
- **Preview equals export.** Blockout's live viewport applies tone mapping and exposure that its
  exporter doesn't, so what the user previews is not what exports. Choose one look and use it for both.
- **Depth, if used.** Record near and far in the metadata. Measure the range on subjects, not every
  visual: a large ground plane flattens the gradient. Offer inverse depth as well as linear, and don't
  antialias the depth pass.
- **Mannequin sign check before porting the motions.** The motion-data header documents the opposite
  X-axis sign from what the rig geometry does when hand-evaluated (arm forward or back, seated knees in
  front or behind). One side-view render of `jab-cross`, `wave` and `sit` settles whether the rig or the
  data is mirrored.
- **Smaller fixes:**
  - wheel spin rotates about the axle and is probably invisible;
  - framing height ignores the clamp on person height;
  - Blockout's agent docs call rotation clockwise, but the engine turns counter-clockwise seen from above;
  - the control handler's delete skips cleanups that the UI's delete performs.
- **Choreography.** Rewrite the scheduler so the last mark never passes the requested duration and no
  track is empty. Add the merge Blockout lacks, a walk path plus an upper-body gesture on one actor,
  which walk-and-talk shots need.

## 5. How Shots fits ConceptStudio

### Placement

The nine training screens are an owner decision, and Shots is not a training step. Decision 2 asks
where Shots lives. The recommended option is a separate workspace beside the training journey. It
leaves the steps, Back/Next and the existing redirects untouched, and a project with no concept and no
photos is already legal.

### Parts

| Part | Responsibility |
|---|---|
| **Previs core** (pure Swift, its own target, Apache-2.0 notice) | Document types, validation, the evaluator, optics, rig noise, the mannequin pose function, camera-move families, action paths, the frame grid and canvas rules. No UI or rendering imports |
| **Content resources** | Motions, asset catalog, camera-move and action-path catalogs and fight tables as versioned JSON, extracted once by a script. Each file records its upstream commit and licence. Loading fails loudly on a missing id |
| **Shots session** | One typed command per edit, used by the UI and later by agents. Undo per user edit through the Edit menu. Selection, playback and persistence |
| **Viewport** | A RealityKit view with orbit, pan and dolly, entity picking, move and rotate handles (macOS has no built-in manipulation component), marks, path ribbons, and a look-through view of the shot camera |
| **Exporter** | Renders evaluator state offscreen at exact frame times. Passes: clean RGB; pose, drawn in 2D from projected mannequin joints with wrist, ankle and head points synthesised; layout boxes; per-actor mattes; and optional depth. Output is frame-exact and verified after writing |
| **Package contract** | A versioned, language-neutral manifest that names every asset by its role (section 7). The exporter produces packages; destinations consume them. The first destination writes a folder for ComfyUI |
| **H3 prompt compiler** | Turns a shot into prompt facts: camera move per leg, arrival times, who is where. A language model writes the prose from those facts with the H3 prompt-writing skill, an Agent Skill in the format ConceptStudio already loads, in MiniMax's official FL2VA structure |

### Persistence

The shot documents are app-only state, so they live in `.conceptstudio/shots.json`. Exported packages
go to a visible folder in the project, for example `Shots/<shot>/<export>/`, because the user carries
them into ComfyUI. Three existing rules stay intact:

- `job.yaml` is a strict shared contract and is not extended.
- Nothing is written into `images/`, where every file counts as training data.
- The Hugging Face publisher uploads only training media, captions, the job file and the skill, so
  shot packages are never published.

### Native-app requirements from PRODUCT.md

Every Shots screen meets the same bar as the rest of the app:

- full keyboard operation, and VoiceOver labels on every control;
- contrast in light and dark appearances;
- a 980 × 680 minimum window;
- screens that explain themselves, with new terms added to the glossary;
- offscreen preview renders of each screen and state;
- the sandbox, credentials in Keychain, and no subprocesses.

A 3D viewport with a timeline and inspectors is the hardest place in the app to meet this bar, and the
estimates include it.

## 6. Rendering on macOS, from the probes

- **`RealityRenderer` works offscreen.** It is available from macOS 15. Probes ran outside the sandbox
  on one recent macOS:
  - repeated renders hashed identically across render orders and separate processes;
  - projected markers landed within 0.4 px of the analytic projection;
  - `AVAssetWriter` produced exact i/24 timestamps.
- **`RealityRenderer` outputs no depth.** If depth earns its place in Phase 0, add a small Metal depth
  pass over the core's own primitive geometry. Xcode now ships the Metal compiler as a separate download,
  so whether shaders compile at build time or at runtime is an implementation choice to make then.
  SceneKit would give depth easily, but Apple has put it in maintenance mode, so it stays a documented
  fallback only.
- **Colour traps found by the probes:**
  - writing into a non-sRGB texture view darkens mid-grey from 128 to 55;
  - with no light in the scene, a lit material renders black;
  - saturated tints drifted from their specified values.

  The preview and the export must share one calibrated look.
- **Untested so far:** none of this has run on macOS 15 or inside the signed, sandboxed app. Phase 1
  starts with that spike.

## 7. The package contract and the ComfyUI handoff

### The package

A package is an immutable folder: a manifest plus the files it lists. The manifest is versioned, is
language-neutral JSON, and names every file by the role it plays in an H3 shot rather than by any
ComfyUI node:

- first endpoint and last endpoint;
- middle guide, with its pixel frame index;
- control video, with its kind (pose, layout or depth);
- matte, with its actor;
- prompt, as its structured sections and as rendered text;
- the frame count, frame rate and canvas;
- the description (camera path, marks, subject screen boxes, depth range).

Each package also records the shot and document revision it came from, so anything made from it later
can be traced back to the exact blocking that produced it.

### Designed so generation can be added later

Shots is closed to modification and open to extension along one seam: **destinations**. A destination
takes a finished package and does something with it. The first release has one destination, which
writes the package folder for the user to carry into ComfyUI. Two possible later destinations would plug
in beside it, and neither changes the core, the editor, the exporter or the package format:

- *Fill a ComfyUI graph template.* This maps package roles onto the user's own API graph and edits JSON
  only.
- *Generate in the app.* This sends a package to a pod service and records the result as a take,
  linked to the package it came from.

Two choices keep that seam real without building anything speculative:

- **The shot document gets an empty list of results.** The persistence format reserves it, so a later
  release can add takes without a schema migration.
- **The prompt compiler keeps sections separate.** It returns structured sections as well as text, so a
  later request can place each section where its consumer expects it.

**What generation would cost if it is added later.** Roughly 8–12 days of app work, plus a pod image
from its maintainer. That covers a ComfyUI-based service behind the pod agent, take records wired into
the app's existing "unsaved result" protection, and the app's money rules (price and budget per take,
an idle rule for a server that keeps the model loaded, storage for a second set of H3 weights). An
earlier draft of this plan worked through those details; they return only if the owner chooses
generation.

### Rules for the ComfyUI handoff

The first destination writes files that map directly onto nodes in an H3 graph. These rules keep the
handoff correct:

- **Endpoints.** The first and last guide images are meant for the image-to-video node's first-frame and
  last-frame inputs. That node shows them to the text encoder as well as anchoring them in the latent.
  Images added only through the separate "add guide" node reach the denoiser alone, so a prompt that
  refers to "Picture 1" and "Picture 2" points at nothing. The package's prompt numbers its pictures in
  the same order.
- **Middle guides.** Each comes with its exact pixel frame index, for the "add guide" node.
- **Control video.** Pose and layout videos have exactly the shot's frame count and canvas. The Fun
  ControlNet node holds a short video's last frame and trims a long one, so a mismatch shifts timing
  silently.
- **Frame count and canvas.** These are written into the metadata and the file names, so they can be
  matched against the graph's length, width and height.
- **Mattes.** One per actor, as stills at the guide frames and as a video, for masked keyframe passes and
  masked H3 resample passes.
- **Prompt.** A text file in MiniMax's FL2VA structure: the picture-alignment header, then
  `integrated_multimodal_description`, `overall_soundscape` and `non_diegetic_music`. It must stay under
  ComfyUI's practical limits and contain no editor labels.
- **Description.** A JSON file with the camera path, the marks, the guide indices, subject screen boxes
  and, when depth is exported, its near and far range.

Filling the user's own ComfyUI graph template is a possible later destination (section 8). It would
edit API JSON; it would not run ComfyUI.

## 8. Phases

Sizes are engineer-day equivalents for focused work, estimated by this plan. AI seats shorten the
calendar, but review time, GPU experiments and Mac-specific checks do not compress.

### Phase 0: is previs worth it? (3–6 days, including owner time; no Swift)

The tool for this phase is a small script that runs Blockout's own engine headlessly, without
Blockout's UI. Blockout's evaluator, plus the mannequin's forward kinematics, gives exact joint positions
for every frame. From those, the script writes four things:

- a pose video, drawn as a COCO-18 skeleton;
- layout boxes;
- guide stills at H3 frame indices, with labels off;
- the reference skeleton used for measurement.

This script is also the first version of the exporter's logic. Shots are blocked in Blockout's app or
written as scene files, and installing Blockout locally is the owner's call. Generation runs in ComfyUI
on one rented 80–96 GB GPU.

- **Shot choice.** One existing shot with approved endpoints, using subjects and set pieces that
  Blockout's catalog can represent. Where it can't, boxes stand in, and that is recorded.
- **Held constant across arms:** endpoints (fed through the image-to-video node), prompt, adapter,
  canvas, steps and seeds.
- **Core arms:** 4 setups × 3 seeds = 12 H3 runs.
  - **A0:** the FL2VA baseline.
  - **A1:** A0 plus Fun ControlNet pose control, at strength 1.0, and at strength 0.6 ending at half the
    steps.
  - **A3:** A0 plus v2.0 layout control. Run it only after confirming that ComfyUI's repack carries the
    block-placement metadata; without that metadata it misbehaves silently.
- **Keyframe arm K:** about 12 image-model runs over 3 shots. Keyframes composed from previs pose or
  depth stills, against prompt-only composition.
- **Optional arms, information only:** 12 more H3 runs.
  - **A2:** depth control, linear and inverse.
  - **B:** Ref2VA with the previs as a video reference, with and without the adapter.
- **Budget.** Per-run time is unmeasured. Time the first A0 run, and price the core arms before running
  them. Cap the core arms at 6 GPU-hours. Add shots or optional arms only within a second, explicit
  budget. Extra downloads: Fun ControlNet v1 2.3 GB, v2.0 4.5 GB, and, for arm B only, the Ref2VA
  checkpoint 21 GB.
- **Measures:**
  - joint error and mark-timing error (in frames) against the reference skeleton;
  - endpoint fidelity (LPIPS at the first and last frames);
  - face-identity similarity against the adapter's training set, measured the same way for every arm;
  - visible grey-box bleed;
  - wall time and VRAM;
  - for K, whether the endpoint pair passes review at the first attempt.

**Pass rules.** A difference counts only if it exceeds the spread between seeds within the same arm.

- **A1 or A3 passes** if three things hold against A0: joint and mark-timing error fall by at least
  30%, identity similarity drops by no more than 0.03, and endpoint LPIPS is unchanged, with no bleed
  visible.
- **K passes** if at least 2 of the 3 shots get an endpoint pair accepted first time where prompt-only
  composition does not.

**Outcomes.**

- **A1 or A3 passes:** build Phases 1–6, with pose or layout video in the package.
- **Only K passes:** the package is guide stills and metadata. Build Phases 1–2, then re-scope Phases
  3–5 before starting them.
- **Nothing passes:** stop. Previs isn't paying for itself on this pipeline.

### Phase 1: previs core, plus the native rendering gate (5–8 days)

- **Spike first (1–2 days).** Inside the signed, sandboxed app, preferably on macOS 15 or a macOS 15 VM:
  - render, encode and verify a 124-frame clip at H3 resolution;
  - build a RealityKit view with orbit, click to select and one drag handle;
  - compare a viewport frame with the exported frame.

  If the spike fails, the renderer choice is revisited before the rest of the phase.
- **Faithful port.** Port types, evaluator, kernels and optics faithfully, and prove agreement within
  1e-9 against the TS engine on a handful of scenes.
- **Deviations.** Apply the section 4 deviations as separate, documented changes.
- **Remaining core:** semantic validation, the frame grid and canvas rules, the mannequin pose function,
  the camera-move families, the 14 action paths with speed, and the content JSON with its extraction
  script.

The parity harness is porting scaffolding. It lives outside the test suite and is removed once the
deviations land. The suite keeps a handful of behaviour tests for the deliberate fixes: turns blend,
attachment cycles are rejected, and choreography stays within its duration.

*Done when:* the core builds with no UI, agrees with Blockout on the unchanged features, and every
deviation has a written reason.

### Phase 2: headless package export, milestone A0 (6–9 days)

Define the versioned package manifest and the destination seam, with the folder destination as its only
implementation. Then build the section 7 package from a scene document, with no editor:

- clean, pose, layout and matte passes, plus depth only if Phase 0 earned it;
- guide stills;
- the prompt;
- the description file.

Export supports cancelling and verification after writing. Scenes come from Blockout project files
through a one-way importer (decision 5), or from the command surface.

*Done when:* a scene blocked in Blockout produces a package that drops straight into the ComfyUI keyframe
and FL2VA graphs. **This is the first point at which Shots is useful**, before any editor exists.

### Phase 3: workspace shell (3–5 days)

Build the workspace entry, the shot list (scenes and shots), persistence, the typed command surface,
undo through the Edit menu, and task cancellation when a project closes.

*Done when:* a project with no concept opens Shots, edits survive quit and reopen, and undo works.

### Phase 4: viewport and staging (12–18 days)

This phase covers:

- the RealityKit viewport, picking, move and rotate handles, and ground snapping;
- the mannequin with gait animation;
- about 20 starter assets in a small parts format;
- label tints;
- the look-through shot camera with letterbox, using the same look as the export;
- accessibility and keyboard operation throughout.

*Done when:* two people and a few set pieces can be placed, posed and framed through the shot camera,
using only the keyboard if needed.

### Phase 5: blocking tools, milestone A (9–14 days)

This phase covers:

- the timeline: lanes, mark pills, drag to retime, stretch for hold, scrubbing;
- mark dropping, and inspectors for shot, entity, camera and mark;
- framing tools, porting Blockout's framing placement with the tilt fix;
- a starter set of camera presets, aim lock, and lens, sensor and rig settings;
- the motion picker and the walk-and-talk merge;
- path ribbons, and speed and 180° warnings.

*Done when:* a two-person shot can be blocked along Blockout's minimum path, then exported to a package
from the app. That path is two people, marks, framing and shot settings (about 14 interactions), plus
motion and camera-move picks.

### Phase 6: verification and release (3–5 days)

Run the whole loop in the signed, notarised app: block, export, carry into ComfyUI, quit, reopen and
export again. Add offscreen previews of every new screen and state, the documentation, the glossary
entries and the credits surface (section 12).

### Later, on demand

| Item | Size |
|---|---|
| Destination: fill the user's ComfyUI API graph template from a package (image names, frame indices, length, canvas, prompt) | 1–2 days |
| Destination: generate in the app (section 7), if the owner changes the scope | 8–12 days, plus a pod image |
| Time-budgeted fight scheduler | 3–5 days |
| Creature support: a rig with wings, neck and tail, full-transform attachment with bank and pitch, mount poses, camera distances scaled to the subject | 6–10 days |
| Depth pass in Metal, if not built in Phase 2 | 2–3 days |
| Populate a scene from a reference image | 2–4 days |
| External agent bridge (MCP) over the command surface | 2–3 days |
| Wider asset catalog | 5–9 weeks for all 205 assets; better done item by item |

### Totals

| Milestone | Phases | Size |
|---|---|---|
| Go/no-go answer | 0 | 3–6 days |
| A0: ComfyUI packages from Blockout-blocked scenes | 0–2 | 14–23 days |
| A: block and export entirely in the app, released | 0–6 | 41–65 days |

The earlier analysis estimated 40–65 days for a release that also generated H3 video inside the app.
This plan reaches a similar total without generation, for two reasons. The native editor and the app's
accessibility bar are sized from the evidence rather than assumed. And the core costs less, since
agreement with Blockout is already shown. Something useful arrives far sooner: milestone A0 lands in
roughly 3–4 weeks.

These ranges assume Phase 0 passes with A1, A3 or K. If only K passes, Phases 3–5 shrink, because the
editor then mainly serves guide stills.

## 9. Risks

- **Previs may not improve shots enough.** Phase 0 answers this for a few days of work and a capped GPU
  budget.
- **Control video, keyframes and a likeness adapter together.** The control branch has its own blocks,
  which the adapter doesn't patch, so identity has to come from the base blocks. That is inference, and
  Phase 0 measures it.
- **Unverified keyframe ControlNets.** The ones arm K relies on are community models whose model cards
  were not read. Arm K is how they get verified.
- **RealityKit on macOS 15 and in the sandbox** is unverified, which is why Phase 1 opens with a spike.
- **Interaction cost.** Handles, timeline and inspectors are where native editors overrun, so Phases 4–5
  carry the widest ranges.
- **Licensing hygiene** (section 12) has to be right from the first ported file.

## 10. Decisions for the owner

**1. Whether to build Shots, and in what form.**
ConceptStudio today turns photos and clips into trained adapters, for people with no machine-learning
background. Shots would add preparing assets for video shots made with those adapters. That is a new
purpose, and PRODUCT.md's description of the app would need to change. There are four options.

- *Run Phase 0, then port natively.* This costs 3–6 days before any commitment, and saves 7–12 weeks if
  previs doesn't help. If previs does help, the result is a native shot-preparation workspace inside
  ConceptStudio, which can later grow generation as a new destination.
- *Run Phase 0, then stop at a headless exporter over Blockout's own engine.* Phase 0 already builds most
  of this exporter. About one more week would produce milestone A0's packages from shots blocked in
  Blockout's app, with no native editor and no changes to ConceptStudio. The costs: the user works across
  two apps, and Blockout's UI and its defects stay as they are.
- *Port now, without Phase 0.* This saves 3–6 days, but stakes 7–12 weeks of work on an untested
  assumption.
- *Don't build it.* The current keyframe workflow continues unchanged.

*Recommendation: run Phase 0, then choose between the native port and the headless exporter on its
results.*

**2. Where Shots lives in the app.**
ConceptStudio's window is a fixed journey of nine training screens, whose names and order are an
earlier owner decision. Shots is not a training step.

- *A separate workspace in the same window,* reached from the sidebar's bottom block and its own menu
  item. The training journey stays as it is, and a project needs no photos or concepts to use Shots. The
  cost is a second navigation mode in the window, which has to stay coherent with the first.
- *A tenth step after Monitor.* This is easy to discover. But it reopens the nine-screen decision and
  places shot preparation at the end of training. Its keyboard shortcut also needs a small fix, because
  the numbered shortcuts stop at nine.
- *Its own window, sharing the project and the app's core.* This is the cleanest separation: neither
  navigation changes the other. The costs are a second window to manage, and a slightly weaker sense of
  one app.

*Recommendation: a separate workspace in the same window.*

**3. Which assets the package centres on.**
Previs can help H3 in three ways.

- *Planning keyframes,* with consistent guide frames and stills and exact guide positions. This is low
  risk, but its effect on the motion between keyframes is indirect.
- *Driving motion with a pose or layout control video.* The control is stronger, it stays on the
  adapters' checkpoint, and its strength is adjustable. It is untested with likeness adapters.
- *Giving H3 the previs as a reference video.* This is closest to Blockout's own idea. But it is the
  loosest control, runs on a different checkpoint, and nobody knows whether adapters transfer to it.

*Recommendation: decide after Phase 0, from its results.* The expected outcome is keyframe planning plus
control video, with the reference video kept as an experiment.

**4. Which content ships first.**
Blockout has 194 motions, 39 camera moves, 33 action paths and 205 assets. Shipping everything means
more to test and a harder picker to use. Shipping a subset means some shots need content added later. A
suggested first set:

- about 68 motions: sparring and weapons, conversation gestures, mounting and landing;
- about 20 camera moves suited to two-person and portrait framing;
- about 14 action paths;
- about 20 assets: people, a horse, basic furniture and primitives.

Dance and chase content would be dropped for now, and the environment kits deferred.

*Recommendation: that first set, with the rest kept in the data files and exposed on request.*

**5. Whether Shots reads Blockout project files.**
A one-way importer would let shots blocked in Blockout feed the headless exporter in Phase 2, before
ConceptStudio has its own editor. The port keeps Blockout's types closely, so the importer is cheap. The
cost is that Blockout's field names and quirks stay a compatibility concern for as long as the importer
exists.

*Recommendation: build the importer for Phase 2, and drop it later if nobody uses it.*

**6. When to support riders on large creatures.**
Blockout has nothing larger than a horse, and its attachments can't bank.

- *In the first release.* This delays milestone A by one to two weeks.
- *Later.* This costs the same 6–10 days of creature work, with no rework, provided the attachment type
  carries a full transform from the start, as proposed.

*Recommendation: later, with the full-transform attachment from day one.*

## 11. Open questions

- How should shots longer than one H3 generation be split? The trained range ends near 15 s, and the
  package could carry several segments with shared guides.
- Should middle guide frames be named as pictures in the prompt? MiniMax's guides cover only first and
  last frames.
- Should a shot record sound notes for the prompt's soundscape and music sections, or should the user
  write those in ComfyUI?
- Which video format does the ComfyUI side load most reliably: MP4 or a PNG sequence?
- Will users align the grey-box set to a real location photo by hand? Whether depth helps depends on
  it.
- What is the lowest macOS version to test on? A macOS 15 virtual machine closes the current gap.
- Which depth convention did the Fun ControlNet train on? Its model card doesn't say.
- What is the licence of MiniMax's H3 prompt-writing skill? It must be checked before the skill is
  bundled.

## 12. Licensing and credit

- **Ported code and converted data** are Apache-2.0 derivative works inside an MIT repository.
  - Keep them in their own target, with Blockout's `LICENSE` and `NOTICE`.
  - Mark every translated file with its upstream file, the commit (`3f2d056`) and a statement that it
    was translated.
  - Record the source commit and licence in each JSON resource.
- **Credit surface.** Blockout's NOTICE requires crediting "Sam Wasserman (wassermanproductions.com)" in
  documentation and in any about or credits surface. ConceptStudio needs that surface.
- **Portable-path check.** This small check came from a downstream Windows port of Blockout (Gumbii
  Digital, per its `MODIFICATIONS.md`). Credit that work if the check is ported, or reimplement it.
