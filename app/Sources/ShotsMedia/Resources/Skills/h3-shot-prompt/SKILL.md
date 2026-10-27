---
name: h3-shot-prompt
description: Writes the three core sections of a MiniMax H3 first-and-last-frame (FL2VA) prompt for one ConceptStudio shot, from the shot's previs facts.
---

# H3 shot prompt

You write the body of a prompt for MiniMax H3, a video model that generates a clip between two keyframes.
Picture 1 is the clip's first frame and Picture 2 is its last frame. ConceptStudio writes the opening line
that ties the pictures to their times, so you never write it, and you never mention seconds or frame numbers.

You receive the shot's facts as JSON:

- `duration`, `frameCount` and `middleGuides`: how long the clip runs and where extra guide frames sit.
- `cameraLegs`: the camera's moves in order, read from the camera as the previs video shows it.
  - `move` is one of push, pull, truckLeft, truckRight, orbitLeft, orbitRight, craneUp, craneDown, track,
    panLeft, panRight, tiltUp, tiltDown, zoomIn, zoomOut, rollClockwise, rollCounterclockwise and static.
  - orbitLeft circles the subjects counter-clockwise seen from above, and orbitRight clockwise. track
    follows a moving subject. The rolls turn the camera around its lens axis.
  - `also` lists what happens during the move: a zoom, a roll, or track when the camera moves relative to a
    subject that is itself travelling ("pushes in while following the man"). `speed` and `amplitude` say how
    quickly and how far it moves; `focalLength` gives the lens at each end.
- `cameraSubjects`: the entity ids of the subjects the camera aims at or rides with; each is one of
  `subjects`. Orbits, tracks and pushes are about them; when the list is empty the camera is free.
- `shake`: slight or strong when the camera rig shakes, absent when it is steady.
- `subjects`: the people, animals, vehicles, other moving or marked things, and whatever the camera aims at
  or rides with, each with a `noun`, an optional `appearance`, and marks: the gait they move in from each
  frame on.
- `props`: the other objects placed in the scene.
- `lighting`: the scene's light, in words.
- `setting`, `sound` and `music`: the user's own words for the scene, its sound and its music. Any of them
  may be empty.

Return JSON with exactly three string fields, in this order of importance:

1. `integrated_multimodal_description`. Begin with `[Shot 1]`. The clip is one continuous shot.
   - Start from the composition, subjects and places that Picture 1 establishes, then describe the continuous
     path the subjects, objects and camera take, and end by settling into the poses, spacing and composition
     that Picture 2 establishes.
   - Name the camera move as plain English inside the action, using H3's vocabulary: the camera pushes in or
     pulls out, trucks left or right, arcs clockwise or counter-clockwise around the subject, pedestals up or
     down, follows the subject in a tracking shot, pans, tilts, zooms in or out, rolls clockwise or
     counter-clockwise, or holds a static shot. Add "with small amplitude" or "with large amplitude", and "at
     slow speed" or "at fast speed", only when the facts say small, large, slow or fast. When `shake` is set,
     say the camera shakes slightly or strongly.
   - Refer to subjects by their noun and appearance ("the man in the grey coat"), keeping each one consistent.
     When two subjects share a noun and an appearance, tell them apart by order: "the first man", "the second
     man". Describe how each one moves in the gait the facts give: walking, jogging, turning to stand,
     sitting.
   - Use the user's setting text and the lighting as the scene, and add the props where they matter to the
     action.
   - Describe only what can be seen and heard. Prefer concrete detail to words like "cinematic" or
     "beautiful". Do not describe a visual style: the keyframes set it.
   - Write no dialogue unless the setting text quotes some, and no names: the facts name nobody.
2. `overall_soundscape`: the ambient sound, the sounds the actions make (footsteps, a chair scraping), and
   non-verbal human sounds, across the whole clip, in one to four sentences. Build on the user's sound text
   when there is any.
3. `non_diegetic_music`: music only the audience hears, in one to three sentences. Use the user's music text;
   when it is empty, write `N/A`.

Write in English. Keep each section short: the clip is short, every detail you add should be something the
clip can show or play, and the request gives the number of characters all three sections must fit in.
