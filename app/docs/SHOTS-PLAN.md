# Shots: porting Blockout's previs into ConceptStudio (MiniMax H3 only)

Status: **proposal, 2026-10-25.** Nothing here is built. Section 10 lists the decisions that belong to
the owner. Section 11 lists the open questions. Everything else is engineering inside those decisions.

Reference code: [Blockout](https://github.com/wassermanproductions/blockout) at `3f2d056`, an
Electron/TypeScript/three.js previs tool by Sam Wasserman, licensed Apache-2.0. ConceptStudio at
`6a24082`.

Evidence: claims about Blockout's code, ComfyUI's H3 nodes, ConceptStudio and Apple's APIs were checked
against source or small probes. The community keyframe ControlNets mentioned in section 2, RealityKit on
macOS 15, and sandboxed rendering are **not** verified yet. Every size in section 8 is this plan's own
estimate.

## 1. What Shots would be

Shots would be a workspace where you block a shot in grey-box 3D and turn it into inputs for an H3
video. You place people and simple set pieces, drop timed marks for where each one goes, and move a
virtual camera with real lens maths. The app then produces what an H3 shot needs:

- guide images for the first, last and key frames, all from one camera path so they agree with each
  other;
- the exact frame index of every guide on H3's frame grid;
- pose, layout and per-actor matte passes for keyframe control and for H3 control video;
- a structured H3 prompt built from the facts of the shot;
- later, an H3 take generated on a rented pod with the user's own trained adapters.

Blockout already solves the hard parts of the authoring side. ConceptStudio already solves pods,
uploads, downloads, credentials and pending outputs. Shots joins the two. It also widens
ConceptStudio from *training* adapters to *using* them, which PRODUCT.md does not cover today
(decision 1).

## 2. Which H3 route previs should serve

An earlier analysis built the integration around H3's **Ref2VA** route: render the previs as an RGB
movie and give it to H3 as a motion reference. The evidence points elsewhere.

- **Shots targets a keyframe-first workflow.** Finished first and last frames are made separately with
  an image model. ComfyUI's native H3 nodes then animate between them on the FL2VA checkpoint
  (first/last frame to video and audio), adding guide frames mid-shot where needed.
- **Ref2VA is the loosest route.** SGLang's H3 documentation says Ref2VA "can resynthesize or reorder
  motion and cuts" and exposes no strength control. It also needs a different checkpoint. Every
  adapter ConceptStudio trains targets the FL2VA partition, and nothing tests whether a likeness
  survives the switch. Both partitions share key names, so a mismatched adapter loads without error.
- **A control-video route exists.** Alibaba PAI publishes `MiniMax-H3-Fun-Controlnet-Union`: v1 covers
  canny, depth, HED, MLSD and pose, and v2.0 adds scribble, layout and gray. ComfyUI has a native node
  for it. The node is built to coexist with FL2VA keyframes, because keyframe rows get zero control. It
  exposes strength and start/end controls. It stays on the checkpoint the adapters were trained on. No
  published example yet combines it with keyframes *and* a likeness adapter.

Ranked by expected payoff against risk:

| Rank | What previs supplies | Consumer | Risk |
|---|---|---|---|
| 1 | Camera and staging data, consistent first/last/key guide stills (pose or depth variants) and their exact frame indices | Keyframe composition, plus FL2VA with several guide frames | Low on the H3 side. Using pose or depth stills for keyframe composition relies on community ControlNets for the image model, which are unverified |
| 2 | Pose or layout **video** from the evaluated skeleton and actor boxes | H3 Fun ControlNet in the same FL2VA graph | Medium: permitted by the code, unmeasured with likeness adapters |
| 3 | RGB previs movie | Ref2VA as a motion reference | High: loose, different checkpoint, adapter transfer unknown |
| — | Normal pass, Blockout's prompt text, Blockout's Comfy JSON | Nobody | Discard |

Grey-box RGB or depth used as strong control fights the real location and the finished keyframes,
because the mannequins and boxes don't match them. Pose and layout carry the blocking without imposing
geometry. Depth helps only when the grey-box set is aligned to the real location. Phase 0 measures the
routes before anything is ported.

## 3. Keep, defer or discard: the Blockout inventory

Blockout is about 34,900 lines of TypeScript. The pure engine is 16,074 lines, 9,575 of them in one
motion-data file.

| Area | Size | Verdict | Notes |
|---|---|---|---|
| Core: types, evaluator, paths, easing, camera optics, rigs, PRNG/noise, gaits, schema | 1,757 lines | **Port** | About 1,200 lines of Swift. A scratch Swift port already reproduces the TS engine (section 4) |
| Motion library | 194 motions, 156 KB as JSON | **Keep as data** | Pure data: 939 keyframes over 18 joints. Which categories ship first is decision 6 |
| Camera moves | 39 generators, 1,498 lines | **Port as code** | Roughly three subject-relative families (33 moves) plus six fixed-camera or one-off scripts; that grouping is a reading, not verified. About 450–600 Swift lines |
| Action paths (people, vehicles, birds, aircraft) | 33 generators, 1,187 lines | **Port about 14** | Only walk and run are speed-based. For the rest, speed scales with shot length (a 5 s horse gallop averages 24.5 m/s), so add a speed parameter |
| Choreography (dance, fight, chase) | 1,055 lines | **Defer, then redesign** | Ignores the requested duration: 8 s fights end as late as 9.7 s, any dance lasts at least 4.14 s, and fights of 2 s or less leave one fighter with no marks. Keep the fight vocabulary and pairing tables; write a new time-budgeted scheduler |
| Older crowd "sequences" | 412 lines | **Discard** | Superseded by choreography |
| Asset catalog | 205 entries | **Keep as data, port about 20** | 183 have no animation. About 60% are plain primitive assemblies, and about 25% need a small generator (repeat, mirror). No creature larger than a horse, and no arches or parapets |
| Mannequin rig | 246 lines | **Port, after a sign check** | Joint hierarchy, proportions and gait poses are fully specified in the source |
| Other asset builders | about 6,000 lines | **Defer** | Rebuild as a small parts format item by item, not line by line |
| Export loop, stills, metadata | about 530 lines | **Port the logic, rewrite for H3** | Frame law, endpoint rule, metadata and labels all change (section 4) |
| Store, undo, control handler | about 1,900 lines | **Port the design** | One mutation choke point and an undo snapshot per edit. The 33 control actions become a typed command surface |
| UI panels (inspector, timeline, library, rail) | about 3,700 lines | **Rebuild natively** | Keep the interaction ideas: mark pills, drag to retime, stretch for hold, a take bar, look-through camera |
| Populate-from-image (one vision call) | 313 lines | **Defer** | Cheap later on ConceptCore's model clients |
| Live puppeteering and camera recording | about 200 lines | **Defer** | Useful once marks work |
| Gaussian splat scans, glTF/Blender handoff, animatic, contact sheet | | **Defer** | Splats are already excluded from Blockout's exports |
| Generator profiles (9), prompt compiler, Comfy exporter, normal pass, FFmpeg, Electron, Windows/Linux packaging | | **Discard** | The Comfy exporter is not valid Comfy JSON. The prompt contradicts MiniMax's official prompt structures. AVFoundation replaces FFmpeg |

## 4. Hard problems borrowed from Blockout, and the corrections they need

### What carries over

- **One pure evaluator.** `state(t)` gives every actor's position, heading, gait, distance travelled
  and joint pose, plus the camera's position, orientation, focal length and field of view. Playback,
  scrubbing, stills and export all call it. Nothing accumulates from frame to frame.
- **Marks as legs.** Each pair of marks is a leg: a hold, then a trapezoidal-velocity ease along a
  centripetal Catmull-Rom path sampled by arc length. Heading follows the path tangent, and a hold is
  shortened so that at least 0.1 s of travel remains.
- **Scene, take and shot are separate.** The scene owns actors and blocking; each shot owns a camera.
  Covering one performance from several angles is free.
- **Camera optics.** Real sensor sizes, focal length converted to vertical field of view, and
  crop-to-aspect that never exceeds the sensor gate (portrait uses the full gate height). Aim lock
  re-aims every frame at a point 0.8 of the subject's height. Seeded rig noise (handheld, steadicam,
  drone and others) is stateless in time.
- **Camera moves read the subject only through `subjectAt(t)`,** so a virtual subject needs no changes
  to the generators. Examples: the midpoint of two fighters, or a rider on a mount.
- **Motion data.** Each motion keyframe holds a full pose over the joints it touches, so linear
  interpolation is safe. Root motion is a forward/up offset along the heading.
- **Export discipline.** Frames are sampled at exact times, and stills and video come from the same
  evaluation. Blockout hides editor chrome by toggling visibility, and it leaks in two places
  (multi-selection boxes and the top-down render). The port should build each pass from a description of
  that pass instead.

**The core reproduces cheaply.** A 379-line scratch Swift port of the evaluator and its kernels was
compared with the TS engine on 8 scenes, about 24,700 sampled values plus the kernel tables. One value
differed, by 8.9e-16 (a sin/cos rounding). The bar for the real port is agreement within 1e-9. One trap:
the noise hash multiplies seeds as IEEE doubles and then applies JavaScript's ToUint32. Swift must do the
same, or handheld shake differs from Blockout for seeds above about 3.4 million.

### Defects to fix deliberately, after a faithful port

1. An authored turn on a mark is never blended. The figure snaps on arrival, and mid-leg it falls back
   to its original rotation. Proposed behaviour: blend the turn over the hold before the mark, or over
   the leg when there is no hold.
2. A purely vertical move forces the heading to face −Z.
3. Attachment chains resolve in a fixed four passes, so chains deeper than four, in reverse document
   order, land in the wrong place. Boarding resolves before attachment, so boarding a vehicle that is
   itself attached uses its stale position. Replace both with one validated attachment graph, resolved
   in dependency order.
4. Attachments carry position and yaw only. That is enough for walking and vehicles but not for a rider
   on a banking mount, so the Swift attachment type should carry a full transform from the start, even
   if the first UI exposes yaw only.
5. Validation is shallow. Documents that pass it crash the evaluator (unknown rig, sensor or gait;
   missing transform) or produce NaN (unknown aspect). Use typed decoding plus semantic checks: every
   reference resolves, attachments have no cycles, numbers are finite.
6. Position uses one easing curve, while orientation and lens add a second on top, so a "linear" zoom
   is not linear. Choose one behaviour and document it.
7. Coincident mark times teleport within 1 ms, and pan takes the shortest arc only (no whip beyond
   180°). Keep both, but warn in the UI.
8. Auto-framing computes its tilt from a value that is always zero, so framing never tilts. That code
   lives in Blockout's viewport layer, which the framing tools port separately.
9. Camera-move distances are absolute metres. Nothing scales them by aspect or subject size, which
   matters for portrait shots and large subjects.

### Corrections in the export and content layers

- **Frames come first.** H3 takes 17k+5 frames at 24 fps. Blockout computes `round(duration × fps)`
  from durations edited in 0.1 s steps, and that can never produce 39, 124 or 243 frames. A shot stores a
  frame count, and its duration is derived from it. Frame *i* samples t = i/24, the last frame samples
  (N−1)/24, and the last guide still is exactly that frame. ComfyUI's H3 node describes 124–362 frames
  as the trained range, so warn outside it.
- **Canvas.** The export canvas is the generation canvas, with width and height multiples of 32, set per
  shot. 640 × 1152 and 768 × 1344 are typical portrait sizes. The "short edge 768, area at most
  768 × 1344" rule in ComfyUI applies only to resizing Ref2VA reference videos.
- **Labels off in conditioning stills.** Blockout keeps label sprites in stills unless labels are
  switched off. H3 and image models reproduce visible text.
- **Preview equals export.** Blockout's live viewport applies tone mapping and exposure that its
  exporter doesn't, so what the user previews is not what exports. Choose one look and use it for both.
- **Depth, if used.** Record near and far in the metadata. Measure the range on subjects, not every
  visual: a big ground plane flattens the gradient. Offer inverse depth as well as linear, and don't
  antialias the depth pass.
- **Mannequin sign check before porting the motions.** The motion-data header documents the opposite
  X-axis sign from what the rig geometry does when hand-evaluated: arm forward or back, seated knees in
  front or behind. One side-view render of `jab-cross`, `wave` and `sit` settles whether the rig or the
  data is mirrored.
- **Smaller fixes:**
  - wheel spin rotates about the axle and is probably invisible;
  - framing height ignores the clamp on person height;
  - Blockout's agent docs call rotation clockwise, but the engine turns counter-clockwise seen from above;
  - the control handler's delete skips cleanups that the UI's delete performs.
- **Choreography.** Rewrite the scheduler so that the last mark never passes the requested duration and
  no track is empty. Add the merge Blockout lacks: a walk path plus an upper-body gesture on one actor,
  which is what walk-and-talk shots need.

## 5. How Shots fits ConceptStudio

### Placement

The nine training screens are an owner decision, and Shots is not a training step. Decision 2 asks
where Shots lives. The recommended option is a separate workspace beside the training journey. It
leaves the steps, Back/Next and the existing redirects untouched. A project with no concept and no
photos is already legal, and the GPU footer (spend, Stop everything) is shared.

### Parts

| Part | Responsibility |
|---|---|
| **Previs core** (pure Swift, its own target, Apache-2.0 notice) | Document types, validation, the evaluator, optics, rig noise, the mannequin pose function, camera-move families, action paths, the frame grid and canvas rules. No UI or rendering imports |
| **Content resources** | Motions, the asset catalog, camera-move and action-path catalogs, and fight tables as versioned JSON, extracted once by a script. Each file records its upstream commit and licence. Loading fails loudly on a missing id |
| **Shots session** | One typed command per edit, used by the UI and later by agents. Undo per user edit through the Edit menu. Selection, playback and persistence |
| **Viewport** | RealityKit view with orbit, pan and dolly, entity picking, move and rotate handles (macOS has no built-in manipulation component), marks, path ribbons and a look-through view of the shot camera |
| **Exporter** | Renders evaluator state at exact frame times offscreen. Passes: clean RGB; pose, drawn in 2D from projected mannequin joints with wrist, ankle and head points synthesised; layout boxes; per-actor mattes; optional depth. Output is frame-exact and verified after writing |
| **H3 shot compiler** | Turns a shot into guide frame indices, still selections and prompt facts (camera move per leg, arrival times, who is where). A language model writes the prompt prose from those facts with the H3 prompt-writing skill, an Agent Skill in the format ConceptStudio already loads, in MiniMax's official FL2VA structure |
| **Shot generation** | A new pod action plus Swift take records (section 7) |

### Persistence

App-only state lives in `.conceptstudio/shots.json`, and staged inputs live under
`.conceptstudio/shots/<shot>/`. Downloaded takes go to `results/<take-id>/`, so the existing hashing and
path confinement apply. `job.yaml` is a strict shared contract and is not extended. Generated takes never
land in `images/`, where every file counts as training data; promoting a take to training data is an
explicit import.

### Native-app requirements from PRODUCT.md

Every Shots screen must meet the same bar as the rest of the app:

- full keyboard operation and VoiceOver labels on every control;
- contrast in light and dark appearances;
- a 980 × 680 minimum window;
- screens that explain themselves, with new terms in the glossary;
- offscreen preview renders of each screen and state;
- the sandbox, credentials in Keychain, and no subprocesses.

A 3D viewport with a timeline and inspectors is the hardest place in the app to meet this bar. The
estimates include it.

## 6. Rendering on macOS, from the probes

- `RealityRenderer` is available from macOS 15. In probes, run outside the sandbox on one recent macOS:
  - repeated renders hashed identically across render orders and separate processes;
  - projected markers landed within 0.4 px of the analytic projection;
  - `AVAssetWriter` produced exact i/24 timestamps.
- `RealityRenderer` outputs **no depth**. If depth earns its place in Phase 0, add a small Metal depth pass
  over the core's own primitive geometry. Xcode now ships the Metal compiler as a separate download, so
  the build approach (shaders compiled at build time or at runtime) is an implementation choice to make
  then. SceneKit would provide depth easily, but Apple has put it in maintenance mode, so it remains a
  documented fallback only.
- Colour traps found by the probes:
  - writing into a non-sRGB texture view darkens mid-grey from 128 to 55;
  - with no light, a lit material renders black;
  - saturated tints drifted from their specified values.
  The preview and the export must share one calibrated look.
- None of this has run on macOS 15 or inside the signed, sandboxed app. Phase 1 starts with that spike.

## 7. In-app H3 generation

The current H3 generator can't express a production shot:

- it always renders a base arm and a LoRA arm;
- it sends text only (the pinned sampler supports a first frame, but no last frame, guides or control);
- it requires a training run inside the project;
- the Swift client sends square sizes;
- it reloads the model on every request.

The recommendation (decision 4) is a **ComfyUI-based shot service** behind the pod agent:

- a pinned ComfyUI core with the native H3 nodes and the Fun ControlNet node, with graphs kept as API JSON
  templates that the pod fills in;
- **one arm per take**;
- first and last frames passed through the image-to-video node, so both the text encoder and the
  denoiser see them. Frames added only as guides reach only the denoiser, so a prompt that refers to
  them ("Picture 1") points at nothing;
- middle guides at exact frame indices, an optional pose or layout control video with strength and end
  point, adapters with strengths, the compiled prompt, seed, steps, canvas and frame count;
- take records of their own, wired into the existing checks that block an ordinary Stop and the idle
  stop while a result is unsaved. As with comparisons, a budget stop or an explicit "stop anyway" still
  overrides them;
- **money before spending**, as everywhere else in the app: an estimated price per take, a budget per
  take and per session, an idle rule that suits a server keeping the model loaded, and the separately
  billed storage for a second set of H3 weights in ComfyUI's format, all shown before renting.

The pod's ai-toolkit saves H3 adapters with ComfyUI key prefixes, and ai-toolkit-trained H3 adapters
have loaded in ComfyUI H3 graphs through the stock model-only LoRA loader. No adapter has yet gone
through the new service. A check that an adapter targets the right partition belongs in the request
path, because a mismatch loads silently.

A new service needs a new pod image. That image belongs to the pod-image maintainer. A brief for it
gets written after Phase 0 and decision 4, and the image has to be released before Phase 6 starts.
For prototyping before then, a developer-only path can queue the same graph templates on an existing
ComfyUI H3 pod. That path skips the pod agent's budget and custody rules, so it never ships.

## 8. Phases

Sizes are engineer-day equivalents for focused work, estimated by this plan. AI seats shorten the
calendar, but review time, GPU experiments and Mac-specific checks do not compress.

### Phase 0: is previs worth it? (3–6 days, including owner time; no Swift)

The tool for this phase is a small script that runs Blockout's own engine headlessly. It does not need
Blockout's UI. Blockout's evaluator, plus the mannequin's forward kinematics, gives exact joint positions
for every frame. From those the script writes:

- a pose video, drawn as a COCO-18 skeleton;
- layout boxes;
- guide stills at H3 frame indices, with labels off;
- the reference skeleton used for measurement.

The script is also the first version of the exporter's logic. Shots are blocked in Blockout's app, or
written as scene files. Installing Blockout locally is the owner's call.

- **Shot choice.** Pick one existing shot with approved endpoints, using subjects and set pieces that
  Blockout's catalog can represent. If a subject or set piece can't be represented, use boxes as
  stand-ins and record that.
- **Fixed for every arm.** The same endpoints (fed to the text encoder as well as the denoiser), prompt,
  adapter, canvas, steps and seeds.
- **Core arms, 4 setups × 3 seeds = 12 H3 runs:**
  - **A0:** the FL2VA baseline;
  - **A1:** A0 plus Fun ControlNet pose control, at strength 1.0, and at strength 0.6 ending at half
    the steps;
  - **A3:** A0 plus v2.0 layout control. Run it only after confirming that ComfyUI's repack carries the
    block-placement metadata; without it the model misbehaves silently.
- **Keyframe arm K:** about 12 image-model runs over 3 shots. Compose keyframes from previs pose or depth
  stills, and compare against prompt-only composition.
- **Optional arms, information only, 12 more H3 runs:**
  - **A2:** depth control, linear and inverse;
  - **B:** Ref2VA with the previs as a video reference, with and without the adapter.
- **Budget.** One rented 80–96 GB GPU. Per-run time is unmeasured, so time the first A0 run, and price
  the core arms before running them. Cap the core arms at 6 GPU-hours; add shots or optional arms only
  within a second, explicit budget. Extra downloads: Fun ControlNet v1 2.3 GB, v2.0 4.5 GB, and the
  Ref2VA checkpoint 21 GB, needed only for arm B.
- **Measures:**
  - joint error and mark-timing error (in frames) against the reference skeleton;
  - endpoint fidelity (LPIPS at the first and last frames);
  - face-identity similarity against the adapter's training set, measured the same way for every arm;
  - visible grey-box bleed;
  - wall time and VRAM;
  - for K, whether the endpoint pair passes review on the first attempt.

**Pass rules.** A difference counts only if it exceeds the spread between seeds within the same arm.

- A1 or A3 passes if joint and mark-timing error fall by at least 30% against A0, identity similarity
  drops by no more than 0.03, endpoint LPIPS is unchanged, and no bleed is visible.
- K passes if at least 2 of the 3 shots get an endpoint pair accepted on the first attempt where
  prompt-only composition does not.

**Outcomes.**

- If A1 or A3 passes: build Phases 1–7 with control video in Phase 6.
- If only K passes: the deliverable is guide stills and metadata for an external keyframe workflow.
  Build Phases 1–2, then re-scope Phases 3–6 before starting them.
- If nothing passes: stop. Previs isn't paying for itself on this pipeline.

### Phase 1: previs core, plus the native rendering gate (5–8 days)

- **Spike first (1–2 days).** Inside the signed, sandboxed app, preferably on macOS 15 or a macOS 15 VM:
  - render, encode and verify a 124-frame clip at H3 resolution;
  - build a RealityKit view with orbit, click to select and one drag handle;
  - compare a viewport frame with the exported frame.
  If this fails, the renderer choice is revisited before the rest of the phase starts.
- **Core.** Port the types, evaluator, kernels and optics faithfully, and prove agreement within 1e-9
  against the TS engine on a handful of scenes. Then apply the section 4 deviations as separate,
  documented changes.
- **Rest of the core:**
  - semantic validation;
  - the frame grid and canvas rules;
  - the mannequin pose function;
  - the camera-move families;
  - the 14 action paths with speed;
  - the content JSON and its extraction script.

The parity harness is porting scaffolding. It lives outside the test suite and is removed once the
deviations land. The suite keeps a handful of behaviour tests for the deliberate fixes: turns blend,
attachment cycles are rejected, and choreography stays within its duration.

*Done when:* the core builds with no UI, agrees with Blockout on the unchanged features, and every
deviation has a written reason.

### Phase 2: headless shot-package export, milestone A0 (5–8 days)

Render the clean, pose, layout and matte passes (depth only if Phase 0 earned it), plus guide stills at
exact frame indices, from a scene document with no editor. Write metadata (frame count, canvas, camera
path, guide indices, subject screen boxes, depth range) and the compiled H3 prompt. Support cancel and
verification after writing. Scenes come from Blockout project files through a one-way importer
(decision 7) or from the command surface.

*Done when:* a scene blocked in Blockout produces a package that drops straight into the keyframe and
FL2VA workflow by hand. **This is the first point at which Shots is useful**, before any editor exists.

### Phase 3: workspace shell (3–5 days)

The workspace entry, the shot list (scenes and shots), persistence in `.conceptstudio/`, the typed
command surface, undo through the Edit menu, and cancelling tasks when a project closes.

*Done when:* a project with no concept opens Shots, edits survive quit and reopen, and undo works.

### Phase 4: viewport and staging (12–18 days)

- the RealityKit viewport, picking, move and rotate handles, and ground snapping;
- the mannequin with gait animation;
- about 20 starter assets in a small parts format;
- label tints;
- the look-through shot camera with letterbox, using the same look as the export;
- accessibility and keyboard operation for all of the above.

*Done when:* two people and a few set pieces can be placed, posed and framed through the shot camera,
using the keyboard alone if needed.

### Phase 5: blocking tools, milestone A (9–14 days)

- the timeline: lanes, mark pills, drag to retime, stretch for hold, scrub;
- mark dropping, and inspectors for shot, entity, camera and mark;
- framing tools (porting Blockout's framing placement, with the tilt fix);
- a starter set of camera presets, aim lock, and lens, sensor and rig settings;
- the motion picker and the walk-and-talk merge;
- path ribbons, and speed and 180° warnings.

*Done when:* a two-person shot can be blocked along Blockout's minimum path (two people, marks, framing,
shot settings, about 14 interactions) plus motion and camera-move picks, then exported from the app.

### Phase 6: in-app H3 generation, milestone B (6–9 days of app work, after the image release)

The request; uploads of endpoints, guides, control video and adapters; take records with custody;
price and budget per take; progress, download, review, keep or discard; and recovery after a restart.
The pod service itself ships in the pod image (section 7), on its own schedule.

*Done when:* block, export, generate, download, quit, reopen and review all work in the shipped app on a
rented pod.

### Phase 7: verification and release (3–5 days)

Run the whole loop in the signed, notarised app. Add offscreen previews of every new screen and state,
the documentation, the glossary entries and the credits surface (section 12).

### Later, on demand

| Item | Size |
|---|---|
| Time-budgeted fight scheduler | 3–5 days |
| Creature support: a rig with wings, neck and tail; full-transform attachment with bank and pitch; mount poses; camera distances scaled to the subject | 6–10 days |
| Depth pass in Metal (if not already built in Phase 2) | 2–3 days |
| Populate a scene from a reference image | 2–4 days |
| External agent bridge (MCP) over the command surface | 2–3 days |
| Wider asset catalog | 5–9 weeks for all 205 assets; better done item by item |
| Keyframe (image-model) generation inside ConceptStudio | A separate project; it is not H3 |

### Totals

| Milestone | Phases | Size |
|---|---|---|
| Go/no-go answer | 0 | 3–6 days |
| A0: H3 packages from Blockout-blocked scenes | 0–2 | 13–22 days |
| A: block and export entirely in the app | 0–5 | 37–59 days |
| B: generate H3 takes in the app | 0–7 | 46–73 days, plus the pod image |

The earlier analysis estimated 40–65 days to its integrated release. This plan's total is higher,
because the native editor and the app's accessibility bar are sized from the evidence. It reaches
something useful far sooner: milestone A0 lands in roughly 3–4 weeks. The core costs less than assumed, since
agreement with Blockout is already shown. Generation costs more, because it needs a new runtime rather
than a new request on the existing one. These ranges assume Phase 0 passes with A1, A3 or K. If only
Ref2VA works, the adapter question needs its own training experiment, and everything after Phase 2
changes.

## 9. Risks

- **Previs may not improve shots enough.** Phase 0 answers this for a few days and a capped GPU budget.
- **Control video plus keyframes plus a likeness adapter.** The control branch has its own blocks that
  the adapter doesn't patch, so identity has to come from the base blocks. That is inference, and Phase 0
  measures it.
- **The keyframe ControlNets** that arm K relies on are community models whose model cards were not
  read. Arm K is how they get verified.
- **RealityKit on macOS 15 and in the sandbox** is unverified. That is why Phase 1 opens with a spike.
- **Interaction cost.** Handles, timeline and inspectors are where native editors overrun. Phases 4–5
  carry the widest ranges for that reason.
- **Licensing hygiene** (section 12) has to be right from the first ported file.

## 10. Decisions for the owner

**1. Whether to build Shots, and in what form.**
ConceptStudio today turns photos and clips into trained adapters for people with no machine-learning
background. Shots would add *using* those adapters to make video shots. That is a new purpose, and
PRODUCT.md's description of the app would need to change. There are four options.
- *Run Phase 0, then port natively.* This costs 3–6 days before any commitment, and could save 7–11
  weeks (milestone A) or 9–13 weeks (milestone B) if previs doesn't help. If it does help, the result
  is the full in-app feature.
- *Run Phase 0, then stop at a headless exporter over Blockout's own engine.* Phase 0 already builds
  most of this exporter. It would produce milestone A0's packages from shots blocked in Blockout's app,
  in about one more week, with no native editor and no ConceptStudio changes. On the other hand, the
  user works across two apps, Blockout's UI and its defects stay as they are, and in-app generation is
  not reached.
- *Port now, without Phase 0.* This saves 3–6 days. But it stakes seven to thirteen weeks of work on
  an untested assumption.
- *Don't build it.* The current keyframe workflow continues unchanged.

*Recommendation: run Phase 0, then decide between the native port and the headless exporter on its
results.*

**2. Where Shots lives in the app.**
ConceptStudio's window is a fixed journey of nine training screens. Their names and order are an
earlier owner decision. Shots is not a training step.
- *A separate workspace in the same window,* reached from the sidebar's bottom block and its own menu
  item. The training journey stays as it is, and a project needs no photos or concepts to use Shots.
  The window gains a second navigation mode that has to stay coherent with the first.
- *A tenth step after Monitor.* It is easy to discover. But it reopens the nine-screen decision and
  places shot-making at the end of training. Its keyboard shortcut also needs a small fix, because the
  numbered shortcuts stop at nine.
- *Its own window, sharing the project and the app's core.* This is the cleanest separation: neither
  navigation changes the other. It costs a second window to manage, and a slightly weaker sense of one
  app.

*Recommendation: a separate workspace in the same window.*

**3. Which H3 route Shots is built around.**
Previs can help H3 in three ways.
- *Planning keyframes.* Consistent guide frames and stills, and exact guide positions. This is low risk,
  but its effect on the motion between keyframes is indirect.
- *Driving motion with a pose or layout control video.* The control is stronger, it stays on the
  adapters' checkpoint, and its strength is adjustable. It is untested with likeness adapters.
- *Giving H3 the previs as a reference video.* This is closest to Blockout's own idea. It is the loosest
  control, it runs on a different checkpoint, and adapter transfer is unknown.

*Recommendation: decide after Phase 0, using its results.* The expected outcome is keyframe planning
plus control video, with the reference-video route kept as an experiment.

**4. What runs H3 for in-app generation.**
- *A new ComfyUI-based service in a ConceptStudio pod image.* It supports guide frames, control video and
  the existing production graphs, and adapters trained by the pod already load in it. The costs are:
  - a new image for the pod-image maintainer;
  - a second H3 runtime to keep pinned;
  - a second set of H3 weights on separately billed storage;
  - ComfyUI's GPL-3.0 licence inside a published image, plus the H3 and ControlNet weights' own
    licences.
- *Extend the current ai-toolkit generator.* It reuses the image the adapters were trained in. But it
  can't take a last frame without a patch, has no guide frames or control video, and reloads the model
  on every request.
- *SGLang's H3 server.* It is built for serving at scale. It accepts keyframes only at the first and
  last frame, and has no documented control input.

*Recommendation: the ComfyUI service.* The current generator stays as it is, for training comparisons.

**5. Whether ConceptStudio also makes the keyframes.**
- *Stop at exporting guide stills,* and accept finished keyframes the user brings in from their own image
  workflow. This keeps the project H3-only and ships sooner.
- *Grow image-model generation for keyframes inside the app.* This gives a complete loop, but it adds a
  second model family's runtime and interface.

*Recommendation: import keyframes for now, and revisit after milestone B.*

**6. Which content ships first.**
Blockout has 194 motions, 39 camera moves, 33 action paths and 205 assets. Shipping everything means
more to test and a harder picker to use. Shipping a subset means some shots need content added later.

A suggested first set:
- about 68 motions (sparring and weapons, conversation gestures, mounting and landing);
- about 20 camera moves suited to two-person and portrait framing;
- about 14 action paths;
- about 20 assets: people, a horse, basic furniture and primitives.

Dance and chase content would be dropped for now, and the environment kits deferred.

*Recommendation: that first set, with the rest kept in the data files and exposed on request.*

**7. Whether Shots reads Blockout project files.**
A one-way importer lets shots blocked in Blockout feed the headless exporter in Phase 2, before
ConceptStudio has its own editor. The port keeps Blockout's types closely, so the importer is cheap.
Its cost is that Blockout's field names and quirks stay a compatibility concern for as long as the
importer is kept.

*Recommendation: build the importer for Phase 2, and drop it later if nobody uses it.*

**8. When to support riders on large creatures.**
Blockout has nothing larger than a horse, and its attachments can't bank. Building creature support
into the first release delays milestone A by one to two weeks. Building it later costs the same 6–10
days of creature work, with no rework, provided the attachment type carries a full transform from the
start, as proposed.

*Recommendation: later, with the full-transform attachment from day one.*

**9. Whether takes carry H3's generated audio.**
H3 generates sound along with the picture, and its prompt structure has sections for soundscape and
music. Keeping the audio makes takes complete. It also means prompting for sound, and reviewing it.
Muting it keeps review on the picture, but throws away something the model does well.

*Recommendation: keep the audio, with a per-take mute in review.*

## 11. Open questions

- How should shots longer than one H3 request be chained (the trained range ends near 15 s)?
- Should middle guide frames be named as pictures in the prompt? MiniMax's guides only cover first
  and last frames.
- Should Shots accept adapters trained outside the project, and how is their partition checked?
- Which video format goes to the pod: limited-range MP4, or a PNG sequence?
- Will users align the grey-box set to a real location photo by hand? Whether depth helps depends on
  it.
- What is the lowest macOS version to test on? A macOS 15 virtual machine closes the current gap.
- Which depth convention did the Fun ControlNet train on? Its model card doesn't say.
- What is the licence of MiniMax's H3 prompt-writing skill? It must be checked before the skill is
  bundled.

## 12. Licensing and credit

- Ported code and converted data are Apache-2.0 derivative works inside an MIT repository.
  - Keep them in their own target, with Blockout's `LICENSE` and `NOTICE`.
  - Mark every translated file with its upstream file, the commit (`3f2d056`), and a statement that it
    was translated.
  - Record the source commit and licence in each JSON resource.
- Blockout's NOTICE requires crediting "Sam Wasserman (wassermanproductions.com)" in documentation and
  in any about or credits surface. ConceptStudio needs that surface.
- The small portable-path check came from a downstream Windows port of Blockout (Gumbii Digital, per its
  `MODIFICATIONS.md`). Credit that work if the check is ported, or reimplement the check.
- If the ComfyUI service ships, its image carries ComfyUI (GPL-3.0) and the H3 and ControlNet weights
  under their own licences. Record all of them in the image's release notes.
