# Lane C status

Owner: Ari (Codex). C6 polish completion is on `shots/c-polish` (this PR). Reference implementation:
[Blockout](https://github.com/wassermanproductions/blockout) at `3f2d0564fd575f70fc28e9bfaa7e94b05e3955d9`
(`scripts/blockout/fetch.sh`).

## Checkpoints

| Checkpoint | State | Remaining work |
| --- | --- | --- |
| C0: API skeleton | Merged, PR #53 (`84de1758`) | None in source. |
| C1: workspace entry | Merged, PR #66 (`08cfd92`) | None in source. |
| C2: commands, persistence and undo | Merged, PR #68 (`bf9ab74`) | None in source. |
| C3: lists, import and export | Merged, PR #70 (`427d185`) | None in source. |
| C4: timeline | Merged, PR #71 (`ec2cb5a`) | None in source. |
| C5: inspectors, library and prompt | Merged, PR #76 (`03a4fa8`) | None in source. |
| C6: polish | Preparation merged, PR #77 (`f6b38b8`); completion on `shots/c-polish` | Review and merge; the owner's native walkthrough below. |

Every checkpoint's live keyboard, VoiceOver and signed-app behaviour is checked once, by hand, with the
**native walkthrough** at the end of this file. Headless tests and offscreen captures do not prove focus
traversal, VoiceOver speech or pointer behaviour.

## C6 delivered

**From PR #77 (preparation):** the thirteen Shots glossary terms under "using-conceptstudio"; Help › Credits
with the Blockout acknowledgement and `PrevisCoreAttribution.notice()`; keyboard alternatives to pointer
placement: the library's per-asset **Add to scene** button (adds at the stage centre, selects it) and the entity
inspector's **Add mark here** (a mark at the playhead from the evaluated position and facing).

**Accessibility pass (this PR).** Every Lane C view was audited in source for keyboard reachability and
VoiceOver labels, values and hints:

- *Names on screen and in speech.* Sensor, rig, framing and gait pickers showed raw identifiers (`super35`,
  `sticks`, `closeUp`, `carMount`); they now show readable names (`ShotsAccessibility.swift`). Canvas sizes no
  longer take locale digit grouping ("640 × 1,152").
- *Fields keep their names.* Entity name/label and the shot notes were bare macOS text fields whose only name was
  a placeholder that vanished once filled; they are now labelled fields. Number fields are spoken with whole
  units ("X in metres", "Pan in degrees"). Inspector fields, pickers and generator actions carry a plain
  explanation as their tooltip, which VoiceOver also reads: position axes (noting mount-relative camera marks),
  heading, scale, time, hold, ease in/out (Blockout `evaluate.ts`: a leg uses `from.easeOut` and `to.easeIn`),
  pan/tilt/roll, focal length, focus, sensor, rig, aim lock, mount (only with the Car mount rig), each framing,
  action paths and their duration/speed, camera moves (which replace the camera marks and aim lock), motions and
  overlay, guide frames, lighting, canvas, notes and export. Each explanation was checked against PrevisCore,
  ShotsMedia or Blockout by the independent review. Self-explanatory buttons (Remove, Width/Height) have none.
- *Containers and headings.* The asset library, inspector, timeline and each timeline row are labelled
  accessibility containers whose children stay reachable; section titles carry the heading trait.
- *Library.* The armed asset reports the selected trait instead of an empty value; a search that matches
  nothing says so.
- *Scene list.* Shot rename/duplicate/delete lived only in a pointer context menu; they are now also VoiceOver
  actions on each shot row and a "Chosen shot" section of the scene's actions menu, which the keyboard reaches.
- *Inspect menu.* Its value names what the inspector edits ("Man, mark at 3.50 seconds, walk"); each entity's
  mark submenu is named "Man marks" rather than repeating the entity's name. With several entities selected,
  the "Editing …" note now sits above the fields, and the menu value names the same entity the inspector edits
  (scene order, not click order). With no shot, the inspector says how to get one.
- *Timeline.* Pills read entity (the entity's name even when the row shows its label), time and gait; camera
  pills read "Camera mark at 2.00 seconds" instead of "Camera, camera". Hold is spoken in seconds. The
  timeline's tooltip lists its keys. Ruler labels clear the playhead line; the empty-state text sits at the top.
- *Export and prompt.* Export has a heading, a spoken progress value ("42 percent, Drawing the pose pass…"),
  a stated reason whenever it is unavailable, and announcements when it finishes or is cancelled. The prompt
  section has a heading and explanation, "Write H3 prompt again" once one exists, a "Cancel writing the prompt"
  label and an announcement when written. Failures still use the window alert, the app's single failure path.
- *Attention notices.* "Older than the blocking" and the trained-range warning used dark red text directly on
  the panel, unreadable in dark appearance; they now use the Instant Print pink attention slip.
- *Layout.* The split view starts its panes at equal widths up to their maximums, which left the viewport the
  narrowest pane at 980 × 680 (its toolbar wrapped "Move" mid-word). Side columns are capped at 200/230 points
  and the timeline at 250, so the viewport gets about 330 points at the minimum size; the inspector's minimum is
  200 so Export never truncates.

Tests: `ShotsAccessibilityTests` (5) cover pill labels, spoken units, readable unique
names for every sensor/rig/framing/gait, the Inspect value for each selection kind (never a raw mark id) and
the export progress value and canvas names. This follows the codebase's existing pattern of testing the text a
view hands VoiceOver (`ShotCameraView.accessibilityLabelText`).

**Full preview set.** `scripts/render-app-preview.sh` now renders every Shots screen in both appearances.
Window captures at 980 × 680 and 1240 × 820: `shots-empty`, `shots-sample`, `shots-read-only`,
`shots-library-armed`, `shots-inspector-{shot,entity,entities,camera,actor-mark,camera-mark}`. Column captures
(each whole inspector top to bottom, with a stale prompt and an out-of-range length so both notices show) at the
inspector's narrowest and usual widths: `shots-inspector-column-{shot,entity,camera,actor-mark,camera-mark}` and
`shots-export-{running,finished,unavailable}`. Plus `help-credits` (C6 credits). The Shot camera picker
position is Lane D's view and is not captured offscreen (RealityKit content is blank there by design).

## Keyboard-only path

Turn on System Settings › Keyboard › **Keyboard navigation** first: without it macOS moves Tab focus only
between text fields and lists, not buttons and menus.

1. Open a project and press **⌘0** (Go › Shots). If there is no scene, Tab to **New scene** and press Space:
   a scene with one shot is created and chosen.
2. Tab past the scene list, New scene, Import, **Find an asset** and the first library row's name (that button,
   "Place Man", arms pointer placement) to the row's **Add** button (VoiceOver: "Add Man at stage centre").
   Press Space. A person named Man is added at the stage centre and
   selected; the inspector shows **Entity**.
3. Tab into the inspector's **X (m)** field, type `1.5`, press Tab; in **Z (m)** type `-2` and press Return.
   Each committed field is one placement edit; edits to the same entity within 0.8 seconds are one Undo step.
4. Tab to the timeline (its focus ring surrounds the timeline) and press **End** to move the playhead to the
   last frame (Right arrow: one frame; Shift-Right: one second; Home: start). Arrow keys act only while the
   timeline has focus.
5. Shift-Tab back to the inspector and activate **Add mark here**. A walk mark is added at the playhead from
   the person's current position and facing, and the inspector switches to **Actor mark**.
6. **⌘Z** removes the mark; **⇧⌘Z** restores it.
7. Tab to **Export shot package…** and press Space. Progress and **Cancel export** appear; when it finishes,
   Finder shows the package inside the project's `Shots` folder.

Backed by the headless integration test
`ShotsHelpAndKeyboardTests.keyboardActionModelAddsMovesMarksUndoesRedoesAndExportsAValidPackage`, which follows
these steps through the same store actions the controls call: `addLibraryAsset` (Add), two coalesced
`setPlacement` runs (the X and Z fields), `navigateTimeline(.end)` (End in the focused timeline),
`addInspectorMark` (Add mark here), Undo/Redo, and the exporter Export calls on `exportSnapshot()`. It checks the
mark's time and position, Undo/Redo state, a 22-frame 320 × 576 package and zero `PackageValidator` problems.
It does not send key events, move focus or speak.

## Native walkthrough (owner, by hand)

Use a signed build (`scripts/build-app.sh`) on an Apple-silicon Mac, with Keyboard navigation on. Open the demo
project or any project, and keep the pointer away from the window unless a step says otherwise.

**Keyboard**

1. ⌘0 opens Shots; ⌘1–⌘9 still open the nine training screens; Go › Training workspace returns.
2. Run the keyboard-only path above, steps 1–7. Expected: every step reachable without the pointer, focus ring
   visible at each stop, Finder opens on the package.
3. With focus on any **button** (Add, Add mark here, Export), press Space. Expected: the button acts and
   playback does **not** start. (Shots binds Space to Play/Pause at the workspace level; this checks the button
   wins. If playback toggles instead, record it: the fix is in `ShotsWorkspaceView`.)
4. With focus in the X field, press Space, Left, Right, Delete, Home, End. Expected: they edit the text only;
   the playhead, playback and the selected mark do not change.
5. With the timeline focused, Left/Right/Shift-Left/Shift-Right/Home/End move the playhead; select a mark
   (Inspect › Man marks › a time) and press Delete in the timeline: the mark is removed; ⌘Z restores it.
6. Inspect menu: Tab to it, open with Space, reach Shot, Camera, each entity and each mark submenu with arrows.
7. Scene actions: Tab to the scene's "…" menu, open it; **Chosen shot** offers Rename, Duplicate and Delete for
   the chosen shot. Rename's alert takes the new name and Return.
8. Framing: select the Woman (Inspect › Woman) with aim lock off, move the playhead between camera marks and
   activate Close-up in her inspector; one camera mark is added at the playhead and the camera view shows her
   face. On a camera mark's frame, Close-up changes that mark instead of adding one. The camera inspector's
   Framing note names the Man, the first person, as who its shot sizes frame.
9. Slider: Tab to Rig intensity, change it with arrows; one Undo step reverts it. Drag it with the pointer and
   press Escape before releasing: nothing is committed.
10. Shot inspector: Write H3 prompt (demo uses the template); Cancel stops a running write; edit the scene and
    see the pink "Older than the blocking" slip.
11. Library: Space on a library name (not Add) arms placement and shows the hint; Space again cancels.

**VoiceOver** (⌘F5; VO = Control-Option)

12. VO-U rotor › Headings lists Scenes and shots, Library, Inspector, the inspector's sections, Export and
    Timeline.
13. Library rows read "Place Man, button" (and "selected" once armed) and "Add Man at stage centre, button";
    VO-Shift-H (help) reads each tooltip.
14. Inspect menu reads its label and value ("Shot 1A", then "Man" after Add, then "Man, mark at …, walk").
15. Number fields read "X in metres", "Pan in degrees" etc. and their explanation as help; Name and Label read
    their names when filled.
16. Shot rows: VO-Command-Space (actions) offers Rename shot…, Duplicate shot and Delete shot.
17. Timeline: each row is a group named "Man marks"/"Camera marks"; pills read "Man, mark at 3.50 seconds,
    walk", value "Hold 0.00 seconds", and "selected" when chosen; VO-Space selects a pill and the inspector
    follows. Playhead reads "Frame N of M" and steps with VoiceOver's increment/decrement.
18. Export: progress reads "Export progress, N percent, <step>"; finishing announces "Shot package exported.
    Showing it in Finder."; Cancel announces "Export cancelled."; a failure raises the window alert, which
    VoiceOver reads. With no shot, the reason under the disabled button is read.
19. Prompt: "Write H3 prompt" and its help; "Writing prompt…" while running; "Cancel writing the prompt";
    "H3 prompt written." when done.
20. Read-only file (a `shots.json` with a future `version`): the inspector's lock line is read; edits are dimmed.

Record each step as passed or failed with what was heard or seen. Offscreen captures, tests and this list do not
substitute for it; M1/M2 acceptance remains separate.

## Open for the owner or other lanes

- **Framing and aim lock.** Closed by the owner's ruling (2026-11-09) that Shots framing behaves like Blockout:
  framing frames the selection by Blockout's rules and no longer needs aim lock (`ShotsFramingSubjects`); see
  "Framing like Blockout" in lane-a.md. Aim lock still re-aims a framing while it is on, as in Blockout, and the
  inspector says so. Still for the owner: camera moves take their subject from aim lock, where Blockout uses the
  same selection rule as framing.
- **Lane A:** Blockout import notes still print raw identifiers ("it became super35/sticks",
  `BlockoutImport.swift`). **Lane B:** export step text uses film-pass jargon ("Drawing the pose pass…").
  **Lane D:** the viewport's selection announcement reads raw mark ids ("Selected actor mark mark_… for Man");
  `ShotsAccessibility.markLabel` could supply a time-and-gait description.

## Product proposal

The proposed `app/PRODUCT.md` paragraph is in this PR's description for the owner to approve. PRODUCT.md is
unchanged.

## History

- **C0** (#53): store, evaluator/frame access, selection/tool/command seams, preview/commit, snapshot
  undo/redo, coalescing, debounced atomic saving, corruption and future-version handling; release, quit and
  close flush first and veto on saving failures.
- **C1** (#66): Shots entry beside Cloud GPU and Go › Shots (⌘0); four regions hosting Lane D's
  `ShotsViewport` and `ShotCameraView`; training navigation untouched.
- **C2** (#68): the single command entry (duplicate/import, camera settings, mark deletion, reference cleanup);
  Edit-menu Undo/Redo bridge while Shots is mounted. A CI debounce failure under main-actor contention was
  repaired by polling save opportunities instead of wall time; production debounce unchanged.
- **C3** (#70): scene/shot menus (add, rename, copy, delete), Blockout JSON import with notes, shot settings
  (frame grid, canvas, lighting) and export through Lane B with progress, Cancel and Finder reveal; IT3 exports
  a reopened project with zero validator problems. Selecting a shot resets the playhead (Blockout
  `store.ts:330-341`).
- **C4** (#71): camera-first lanes, ruler, guides, scrubbing, mark selection, retime and hold stretch with a
  single commit on release, Escape cancellation latched to release, focused-timeline keys and 24 fps playback.
- **C5** (#76): selection inspectors, Inspect menu, starter library, coalesced field edits, slider
  preview/cancel, and the prompt action through B5's real `ShotPromptCompiler` (fake-endpoint boundary test).
- **C6 preparation** (#77): glossary, credits, Add to scene and Add mark here, as above.
- **Framing like Blockout** (`shots/framing-like-blockout`, owner ruling 2026-11-09): the framing buttons
  (`ShotsFramingSection`, in the camera inspector and in a selected person's or prop's inspector) frame the
  selection as Blockout does (one selected entity for shot sizes, else the first person; two or more for the
  others, else every person) and work without aim lock; a framing on a camera mark's frame rewrites that mark,
  and a new mark keeps the roll of the one before it. The framing note names who each group frames and warns
  when aim lock is on; the button help no longer says "aim-lock subject".
