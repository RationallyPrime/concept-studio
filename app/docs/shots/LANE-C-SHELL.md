# Lane C: the Shots workspace

**Seat:** Ari. **Code:** `app/Sources/ConceptStudio/Shots/{Model,Workspace,Timeline,Inspector,Library}/`,
`app/Tests/ConceptStudioTests/Shots/`, and the existing app files listed in CONTRACTS section 2.
**Machine:** a Mac with Xcode.

**Mission.** Give Shots a home in the app. This lane builds:
- the workspace entry, the store, persistence, the command layer and undo;
- the scene and shot list, Blockout import, and export;
- the timeline, the inspectors and the asset library;
- the "Write H3 prompt" action;
- the glossary, credits, demo content and offscreen previews.

It hosts Lane D's views from day 1.

**Read first:**
- [CONTRACTS.md](CONTRACTS.md) sections 1, 2, 4, 7, 8.1 and 9.
- [SHOTS-PLAN.md](../SHOTS-PLAN.md) section 5.
- `app/PRODUCT.md` and `app/DESIGN.md`.
- `docs/ADR-LOG.md`.

**Constraints:**
- The nine training screens, their order and their shortcuts stay untouched.
- Shots never writes `job.yaml` or `images/`.
- Every edit is a `ShotsCommand`.
- Errors go through `StudioSession.errorMessage`, the app's single failure path (the window alert).
- Everything the viewport does can also be done with the keyboard and VoiceOver, through the entity list,
  inspector fields and timeline.

## Checkpoints

### C0: API skeleton (day 1, after A0 and B0)

**Deliver:**
- `StudioWorkspace`, `ShotsSelection`, `ShotsTool`, `ShotsCommand`, and `ShotsStore` with every member in
  CONTRACTS section 7, including `init(catalog:document:saveURL:readOnly:)` and the starting scene and
  shot it defines.
- `evaluator` and `frame` **working**: they wrap PrevisCore, and Lane D draws `store.frame` from day 1.
- `perform` may throw `ShotsError.notImplemented` for commands not done yet.
- `run` routes errors to `onError`, and the session sets `onError` to its `errorMessage`.
- `StudioSession.shots` created when a project opens. Read `shots.json`, or use an empty document if
  there is none. Release it in `releaseProject`.
- `StudioSession.workspace`.
- `--shots-self-test`, which calls `ShotsSelfTest.run()`, prints its result and exits with its code.

**Verify:** the build passes. A session test opens a project with no concept, finds a store, switches the
workspace to Shots and back, and checks that `step` never changed. A store built with the sample returns a
frame at playhead 61.

**Unblocks:** D0, B2's self-test.

### C1: workspace entry, hosting Lane D (day 1, after D0)

**Deliver:**
- A "Shots" item in the sidebar's bottom block, beside Cloud GPU, and a menu item with a shortcut that
  collides with nothing.
- A layout with four regions:
  - scene and shot list, with the library below;
  - **`ShotsViewport(store:)`**, with `ShotCameraView(store:)` beside it or swapped with it;
  - the inspector;
  - the timeline.
- It works at the 980 × 680 minimum window size.
- Leaving Shots returns to the training step the user left.

**Verify:**
- The existing suite passes unchanged.
- `PreviewRenderTests` gains the "shots-empty" and "shots-sample" screens at both sizes.
- `scripts/render-app-preview.sh` writes their PNGs. The viewport area is blank in offscreen previews,
  because RealityKit content doesn't render there; that's expected.

### C2: commands, persistence and undo (days 1–2)

**Deliver:**
- **Commands:** `perform` for every command, through one pure entry point
  `apply(_ command:, to document: inout ShotsDocument, catalog:) throws`.
  - It dispatches by command group (scenes and shots, entities, marks, camera) to small functions, so no
    function exceeds SwiftLint's complexity limit.
  - Generator commands surface PrevisCore's error until A4 lands.
- **Revisions:** the scene revision bumps on every edit except `setPrompt`.
- **Undo:**
  - snapshots of the whole document, capped at 200;
  - every `perform` is its own step, unless `coalescing: true` and the previous step was the same command
    kind and target within 0.8 s;
  - ⌘Z and ⇧⌘Z drive it while Shots is frontmost and no text field is editing.
- **Saving** (CONTRACTS 8.1):
  - `AtomicFile` 0.5 s after the last edit;
  - at the **start** of `releaseProject`;
  - on `NSApplication.willTerminateNotification`.
- **Reading:** an unreadable file is renamed aside with a message. A newer version opens the store with
  `readOnly: true`; `perform` then throws a plain sentence, and nothing is written.
- **Problems:** shown in `problems`.

**Verify:**
- A session test on a temp project: add a scene, two entities, three actor marks and a camera mark; undo
  twice and redo once; close and reopen. The document is equal.
- A corrupt `shots.json` is renamed and reported.
- A newer-version file is left untouched, and an edit attempt is refused with a message.
- Ten `setPlacement` commands with `coalescing: true` inside 0.8 s undo as one step. Without the flag
  they are ten steps.

### C3: scene and shot list, import and export, plus IT3 (days 2–3)

**Deliver:**
- **The list:** scenes and shots with add, rename, duplicate and delete.
- **Shot settings:**
  - the frame count as a stepper on the 17k+5 grid, showing seconds, with a warning outside 124–362;
  - the canvas from the presets, or custom in multiples of 32;
  - lighting.
- **Blockout import:** a file picker → `BlockoutImport` → `importScenes`, showing the import notes.
- **Export:**
  - `ShotExporter` to `FolderDestination(parent: <project>/Shots)`, with progress and Cancel;
  - when it finishes, reveal the package in Finder;
  - errors in plain words.
- **Demo:** a demo project starts with `ShotsSamples.twoPersonWalk()`.

**Verify:**
- **IT3:** temp project → commands, ending with `setFrameCount` 22 and `setCanvas` 320 × 576 to keep CI
  fast → save → close → reopen → equal document → export from the store → `PackageValidator` reports
  nothing.
- Importing `ShotsSamples.blockoutProjectJSON()` adds its scenes and shows its notes.
- Previews of the list, empty and with the sample.

### C4: timeline (days 2–3)

**Deliver:**
- **Lanes:** one per tracked entity, plus the camera.
- **Mark pills:** placed at mark times; dragging retimes with snap to frames; dragging the edge stretches
  the hold; clicking selects.
- **Navigation:** a frame ruler with seconds, a scrubbable playhead, and play and pause at 24 fps.
- **Guides:** markers for guide frames, with "Add guide frame here" at the playhead.
- **Keyboard,** per CONTRACTS section 7 (the timeline owns arrows, Home, End and Delete when it has
  focus; Space plays anywhere in Shots).
- **VoiceOver:** every pill reads its entity, time and gait.

**Verify:**
- The drag-to-time mapping snaps to frames.
- A hold stretch produces one `updateActorMark`.
- The keyboard steps the playhead when the timeline has focus and does nothing when the viewport has it.
- A preview of the timeline with the sample.

### C5: inspectors, library and prompt (days 3–4)

**Deliver:**
- **Inspectors,** one per selection kind:
  - **shot:** frames, canvas, guide frames, notes (description, appearance for each character, sound,
    music), prompt;
  - **entity:** asset (read-only), name, label text and colour, position, heading and scale, attach to;
    and "apply action path", with path, duration and an optional speed;
  - **camera:** sensor, rig and intensity, aim-lock subjects, car mount, framing buttons and starter camera
    moves;
  - **actor mark:** time, hold, eases, gait, heading, and apply motion or apply as overlay;
  - **camera mark:** time, hold, eases, position, pan, tilt, roll, focal length and focus.
- Continuously changing fields use preview while dragging, then `run(_, coalescing: true)`.
- **Library:** the starter assets. Choosing one sets `tool = .place(assetID:)`, and Lane D handles the
  click.
- **"Write H3 prompt":**
  - `ShotPromptCompiler.facts`, then `write(_:endpoint:)` with `try session.endpoint()`;
  - in demo mode, or when no model is set up, use `template`;
  - store the result with `setPrompt`;
  - show "older than the blocking" while `sceneRevision` is behind the scene.

**Verify:**
- One integration test drives each inspector-bound command once through the store: one undo step each.
- The prompt action with a fake endpoint stores a prompt whose `sceneRevision` equals the scene's, so it
  isn't stale.
- Previews of every inspector with the sample.

### C6: polish (day 4)

**Deliver:**
- **Glossary entries:** Shots, scene, shot, blocking, mark, hold, gait, guide frame, shot package, frame
  grid, canvas, look-through, aim lock. Put them in `Resources/Glossary/conceptstudio-operations.json`
  under its existing "using-conceptstudio" section.
- **Credits:** in the Help window, "Shots is derived from Blockout by Sam Wasserman
  (wassermanproductions.com), Apache-2.0", with the text from `PrevisCoreAttribution.notice()`.
- **An accessibility pass,** covering keyboard paths and VoiceOver labels.
- **The full preview set.**
- **A proposed paragraph for `app/PRODUCT.md`** describing Shots, in the PR description, for the owner to
  approve. Don't edit PRODUCT.md yourself.

**Verify:**
- `scripts/render-app-preview.sh` renders every Shots screen at both sizes.
- The keyboard-only path works and is written down in the status file: add a person, move it with the
  inspector fields, add a mark, export.

## Notes

- **Selection** survives undo when its target still exists, and clears otherwise.
- **The playhead** clamps when the frame count shrinks.
- **The evaluator** is cached per document, shot and preview (CONTRACTS section 10).
- **Visual language:** follow DESIGN.md (the InstantPrint style); don't invent new chrome.
- **Copy:** user-facing text explains itself for someone with no film or ML background.

## Out of scope

The viewport and look-through (Lane D), rendering and packages (Lane B), generation, and any change to the
training journey.
