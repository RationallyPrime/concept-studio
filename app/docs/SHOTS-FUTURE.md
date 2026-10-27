# Shots, later: beyond the camera's trajectory

Status: **future venture, proposal, 2026-10-27.** This is not part of the current Shots build. That build
finishes as planned in [shots/README.md](shots/README.md), and nothing here changes a lane, a contract or
a checkpoint. Every decision below belongs to the owner, to take if and when this venture starts.

## 1. The idea

Today a Shots package holds what one camera sees of one consistent grey-box world, on one clock: guide
stills, pose, layout and matte videos, a structured prompt, and `shot.json`. That shape is right for
control. Everything ComfyUI receives as a guide has to be rendered from geometry.

H3 is not bound by that shape. It can render things no camera trajectory describes:
- **Transitions inside a shot:** a morph, a match cut on a shape or a motion, a frame that becomes a
  photograph or a screen.
- **Time:** speed ramps, a freeze while the camera keeps moving, reversal.
- **Impossible space:** into an eye or a keyhole, a pull from a face out to orbit, a world that
  rearranges around a still camera.
- **Optics:** a focus pull between two subjects, depth of field, exposure and lens character.

Today the prompt is the only channel for these, and B5 spends much of it describing the camera path
that the guide videos already show.

The proposal rests on one split:
- **Mathematics carries geometry and timing:** the camera path, poses, depth, mattes, and where and when
  a change happens.
- **Images and words carry meaning:** what things are, and what they become.

## 2. What H3 can take today (research, 2026-10-27)

**The official model has no camera-path input.** The H3 weights, ComfyUI core's H3 nodes, ai-toolkit and
Alibaba PAI's H3 Fun ControlNet Union (v1 and 2.0) take text, keyframes, references and control videos,
but no camera pose. The camera reaches H3 three ways:
- **In words:** MiniMax's prompt guide has a camera vocabulary (motion type, amplitude and speed), which
  B5 already uses.
- **As a reference video:** H3's documentation and diffusers both describe a Ref2VA reference video as a
  motion and camera reference.
- **Inside a control video:** a depth or grey render along the path carries the camera implicitly.
  Community recipes do this, but nobody has measured how faithfully H3 follows it.

**Open models that condition H3 on a camera do exist, from outside MiniMax:**
- **SolarWM-H3** ([code](https://github.com/Junchao-cs/SolarWM), Apache-2.0; arXiv 2609.02886; weights
  released 2026-09-13, gated, under the H3 licence).
  - Its Stage2 model generates from a first image plus a camera trajectory: a camera-to-world matrix
    for every frame, with intrinsics.
  - The camera enters inside attention as a projective position encoding, not through an extra branch.
  - It was trained on about 1.43 million camera-labelled clips.
  - Full-length inference is documented on 8 GPUs, and a community ComfyUI port exists.
  - Its published H3 configuration appears to fix the focal length, so zooms are probably not honoured.
    This is unverified.
- **Meridian** (Viggle, [Hugging Face](https://huggingface.co/Viggle/Meridian), 2026-09-14) re-films an
  existing clip or image along an authored path: position, look target and focal length, with no roll.
  - It renders a point cloud along the path and gives H3 the source and the render as two reference
    videos, through two LoRAs on the FL2VA checkpoint.
  - It ships inference code only, and its geometry step depends on VGGT-Omega, which is non-commercial.
- **SolarRenderer** (reported October 2026) is described as LoRAs that render a finished video from a
  structure video, which can be a scene grey box. That would be the closest existing fit for a previs
  render. It has not been checked here.
- **Smaller pieces:** camera-move LoRAs (orbits, handheld, head-mounted), a depth-warp re-angle LoRA
  (Cseti's CrossView Warp), and nodes that turn a drawn path into prompt text.

**MiniMax runs a camera-adapted H3 only as a hosted service.** "H3 Max Camera Controls" (on fal,
Picsart and others, launched by 2026-09-24) takes one image plus 2 to 12 keyframes of azimuth,
elevation and distance around a frozen scene. There are no open weights, and it has no position or
focal input.

**For comparison, Wan has had camera models for over a year.** PAI's VideoX-Fun released Control-Camera
models for Wan2.1-Fun in April 2025 and Wan2.2-Fun in August 2025.
- They read a RealEstate10K-style pose file.
- The poses become Plücker rays, a 6-channel ray for every pixel of every frame.
- A small convolutional adapter adds those rays to the patch embeddings.
- ComfyUI's nodes for them expose preset moves, and an arbitrary path goes in through VideoX-Fun's
  Python scripts.

## 3. Proposals

### 3.1 Write the camera path in the conventions camera models read

`shot.json` already holds the evaluated camera for every frame: position, pan, tilt, roll, vertical field
of view and focal length (CONTRACTS section 8.3). What is missing is a conversion to the conventions
camera models expect:
- a camera-to-world matrix per frame, in OpenCV axes (x right, y down, z forward) and metres;
- pixel intrinsics per frame (fx, fy, cx, cy at the canvas), derived from the field of view;
- writers for the two formats that matter now: the RealEstate10K/CameraCtrl text file (Wan's Fun
  camera models) and SolarWM's per-frame matrices and intrinsics.

*Pros:* the data is exact and already computed, the conversion is small, and it lets Shots feed SolarWM
and Wan's camera models now, and an H3 adapter of our own later.
*Cons:* it adds a second camera format to keep stable. SolarWM appears to ignore focal changes, so a
zoom would be lost there.
*Recommendation:* do this first. It is the cheapest step, and every other camera proposal needs it.

### 3.2 A camera adapter for H3

The owner's idea was to train one in future. SolarWM-H3 shows that an adapter can be trained on H3 at
all, for the image-to-video case. So the choice becomes whether to use it or train our own.

- **Use SolarWM-H3 as it is.**
  - *Pros:* no training, and it takes an exact per-frame path today.
  - *Cons:*
    - It starts from one image, so it may not combine with an FL2VA last keyframe, Fun control videos or
      likeness adapters. That is untested.
    - Full-length inference needs 8 GPUs.
    - Its weights are gated, and focal changes are probably ignored.
- **Train our own on the FL2VA checkpoint our adapters use.** The aim would be an adapter that combines
  with first and last keyframes and likeness LoRAs, and that honours focal length. Three designs have
  precedents:
  - *Camera inside attention,* as SolarWM does. This avoids reshaping rays to H3's token grid, and there
    is public code to learn from.
  - *Plücker rays added to the patch embeddings,* as Wan's Fun camera models do. This needs redesign
    for H3: its tokens cover 32 pixels, and its latent frames cover 1, 4, 4, 4, 4 video frames rather
    than a steady 4.
  - *Continued training of PAI's Fun Union branch on a new condition.* A third party has done this for
    a hand-and-object signal: 1,441 clips, 4 × H200, about 66 minutes an epoch.
  - **Data:**
    - SolarWM-Data: 1.43 million clips, gated, with each source's own licence.
    - MultiCamVideo: Unreal Engine renders, 136,000 videos, Apache-2.0, one fixed focal length per clip.
    - RealEstate10K.
    - DL3DV-10K, which is non-commercial.
    - Shots itself could render exactly labelled clips with any focal path. But published work finds
      that synthetic-only training transfers imperfectly, so it should be mixed with real footage.
  - **Compute:** an estimate, not a reported figure. About 90–220 H100-hours for a proof of concept,
    and 0.5–2.2 thousand H100-hours for a research-grade run at 480p and about 5 s.
  - **Risks:**
    - Camera datasets are silent. Training with zero audio loss has precedents in ai-toolkit and in the
      run above.
    - Keyframe rows were never exercised by a camera condition.
    - Most data has a fixed focal length per clip.
    - Pose-annotation tools carry non-commercial parts; MegaSaM, for example, depends on UniDepth.

*Recommendation:* when the venture starts, first try SolarWM-H3 on paths from 3.1, which is a one-pod
experiment. Train our own only if it falls short on keyframes, likeness or zoom.

### 3.3 First and last keyframes from different scenes

FL2VA already invents the path between its two keyframes. Letting a shot take its first and last
guides from different scenes, places or scales makes H3 compose the transition: a face to a wolf, a room
to a street.

*Pros:* the largest gain in expressive range for the least work, since Shots already renders guide
stills.
*Cons:* control videos are undefined across the jump, so they must be off or limited to one side.
*Recommendation:* the first non-camera item to build.

### 3.4 Authored beats that are not camera moves

A beat is a timed change the camera does not make, such as:
- "morphs into a wolf between frames 40 and 60";
- a speed ramp;
- a freeze while the camera keeps moving;
- a focus pull.

Beats go into the prompt as words, at their times. For a morph, Shots can also write a matte that
tweens from the first silhouette to the second. That tells H3 how big the change is, where it happens
and how fast, while the keyframes and the prompt say what it becomes.

*Pros:* it opens the stories a trajectory cannot tell, and it keeps the split in section 1.
*Cons:*
- Wherever a beat breaks the geometry, the pose and layout guides must be blanked or weakened for those
  frames. Otherwise the control net pulls toward the old geometry while the prompt asks for the change.
- How the Fun ControlNet node handles blanked frames is untested.
- A freeze while the camera moves also needs each entity to keep its own clock, which the evaluator
  does not have today.

### 3.5 Less camera narration in the prompt

If the camera reaches H3 through 3.1 or 3.2, describing it in words repeats the same thing through a
lossier channel. Blockout's own prompt describes no camera moves at all. The prompt's space would go to
the beats instead.

*Pros:* most of B5's camera reader could retire, and its edge cases with it.
*Cons:* this revises B5's spec, which asks for a move per camera leg. Without a camera channel, a short
camera line still helps.
*Recommendation:* decide after the experiment in 3.2.

## 4. The H3 licence

The [MiniMax H3 Community License](https://huggingface.co/MiniMaxAI/MiniMax-H3/raw/main/LICENSE) governs
every adapter trained on H3:
- **Territory:** it grants use, modification and distribution only outside its Excluded Territories:
  the European Union, the United Kingdom, the Republic of Korea and the United States.
- **Derivatives:** adapters are Model Derivatives, under the same terms.
- **Outputs:** H3's outputs may not be used to improve any model other than H3 and its derivatives.
- **Notices:** a commercial product must display "MiniMax H3" in its interface, and a non-hosted
  distribution must carry a NOTICE file.

These terms bind any camera adapter we would ship, and they bear on H3 features for users in the
excluded territories generally.

## 5. Decisions for the owner, when the venture starts

1. Whether and when to start it.
2. Whether packages gain the standard camera format (3.1).
3. Whether to evaluate SolarWM-H3, and train an adapter of our own only if it falls short (3.2).
4. Whether shots can take keyframes from different scenes (3.3), and carry beats with morph mattes
   (3.4).
5. Whether the prompt keeps its camera narration (3.5).
