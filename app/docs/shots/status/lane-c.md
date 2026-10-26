# Lane C status

Owner: Ari (Codex). Branch: `shots/c-shell`.

## Checkpoints

| Checkpoint | State | Remaining dependency or work |
| --- | --- | --- |
| C0: API skeleton | In preparation | A0 core declarations and B0 media declarations must land first. |
| C1: workspace entry | Pending | C0 and D0; host both viewport views. |
| C2: commands, persistence and undo | Pending | C0; implement command application and lifecycle saves. |
| C3: lists, import and export | Pending | C2, A1 import, B3 export; IT3. |
| C4: timeline | Pending | C2; keyboard ownership follows the focused region. |
| C5: inspectors, library and prompt | Pending | A1 catalog, A4 generators, A5 corrections, B5 prompt. |
| C6: polish | Pending | Integrated C/D workspace, previews and keyboard walkthrough. |

The execution README and contracts now agree on startup: B's W0, A's A0, B0, C0, D0, then C1.
No upstream declarations or build wiring are duplicated here.

## Available preparation

`StudioWorkspace` and the session's default `.training` workspace are implemented. Workspace state
is separate from `StudioSession.step`. There is no Shots UI or store yet; C0 is not complete.

Run the focused navigation regression from the repository root:

```sh
swift test --package-path app --build-system native --filter ShotsWorkspaceTests
```

It uses a temporary concept-free project, isolated preferences and in-memory secrets. For each legal
training step in that project, switching to Shots and back must preserve the step and `job.yaml` bytes.

Verification:
- Passed: the focused test, with all three parameter cases, using SwiftPM's native build system.
  The app and test targets compiled successfully with local Swift 6.4. CI's Swift 6.3 is not verified.
- Passed: SwiftFormat and SwiftLint on the three changed Swift files, plus `git diff --check`.
- Failed before testing: the first attempt lacked compiler-cache sandbox access. With cache access,
  the default Swift Build engine then failed signing a generated test bundle because of Finder metadata.
  The native build system completed the same focused test.
- Not run: the full suite, CI, core/media integration, preview renders and signed sandbox self-test.

## Integration points inspected

- `StudioSession.swift`: own `workspace` and `shots`; preserve existing `project` and `step` observers.
- `StudioSessionProjectLifecycle.swift`: initialise/load the Shots store for demo, create and open;
  flush and release it at the start of `releaseProject`, before demo removal or security-scope release.
- `ConceptStudioApp.swift`: add the self-test launch path, workspace menu and focused undo commands;
  add a termination save without changing training shortcuts.
- `StudioRootView.swift`: choose the workspace without overloading the existing training step.
- `DemoProject.swift`: seed the sample document when the core sample is available.
- `PreviewRenderTests.swift`: add empty/sample Shots states at both supported window sizes.

## Next verification cases

These are acceptance cases to implement alongside their functionality, not tests already run.

| Checkpoint | Case |
| --- | --- |
| C0 | Open a concept-free project through the session, require its empty store, switch workspaces without changing step. |
| C0 | Sample store at playhead 61 returns an evaluator frame; `run` routes a refused command to the session alert. |
| C2 | Edit scene, actors, marks and camera; undo twice, redo once, close/reopen; compare the full document. |
| C2 | Preserve corrupt bytes under a renamed file and report them; refuse newer versions without any write. |
| C2 | Explicit slider coalescing groups ten placements; ordinary commands remain ten distinct undo steps. |
| C2 | Flush pending edits before project access ends; stale project tasks cannot write into the next project. |
| C3 | IT3: session edits, save, reopen, export, then an empty package-validator problem list. |
| C4 | Frame snapping, one commit per hold drag, and focused timeline keyboard stepping. |
| C5 | Inspector-bound commands undo separately; prompt facts and stored prompt have the intended scene revision. |
| C6 | Preview render matrix and the documented keyboard-only editing/export path. |

## Open dependencies

- W0, A0 and B0 are absent from the inspected main branch; the remaining C0 integration cannot build
  before those owners supply their declarations.
- The coordinator owns confirmation of the named peer routes and upstream checkpoint integration.
- Plan commit `f348682` contains the settled W0-first startup. C0 must use the final store initializer
  `init(catalog:document:saveURL:readOnly:)`; a newer document version must remain read-only.

## Coordination

- Delivered a project-specific message to the local plan author with C's isolated preparation, test
  evidence and W0/A0/B0 dependencies, requesting W0 status and the unique Lane A owner.
- Gnomon is the intended single Lane A owner. This was delivered to the verified local plan author,
  who recorded it in Lane B's working coordination notes. No competing Lane A branch was found.
- The author's `shots/b-media` worktree contains W0 wiring changes and is running verification.
  W0 has no checkpoint commit yet; its status prose is not proof that the checks have completed.
- A bounded read-only host probe verified cx53's public SSH route with the existing key, an active
  Hive edge, Ubuntu 24.04/x86_64 and Bun 1.3.14. Swift is absent. No native Claude/tmux session was
  available to address; no wake has been sent by C.
- The environment-approved toolchain operation is complete: official Swift 6.3.3 is installed for
  the cx53 `hive` user. The archive passed GPG verification against Swift's published release-key
  fingerprint. Both the installed-path version check and a Foundation compile/run check passed.
  Ubuntu added 16 prerequisite/dependency packages, with no upgrades or removals. Credentials, shell
  profiles and service configuration were not changed; the Hive edge retained its active process.
- The local author received the verified compiler-ready update. Gnomon's staged handoff has the
  exact compiler path, but staged files are not proof of delivery, claim or task execution.
- Supported Gemini conversation searches for Shots, Concept and Metis found no matching target.
  No message was sent to an ambiguous conversation.
- The coordinator handles the external seat route; C has not duplicated a wake.

## Consumer drafts waiting for A0

The command/selection/tool declarations and a document-file loader are drafted outside the buildable
checkout. The loader preserves corrupt bytes under the required backup name, refuses newer versions
in read-only mode, and uses `AtomicFile` for saves. Three integration tests are drafted for corrupt
bytes, future versions and sample-document round trips.

These drafts pass Swift syntax parsing and formatting/lint checks. They have not been type-checked
against PrevisCore and their tests have not run. Move them into the owned Model and test folders once
A0 provides the actual declarations; do not count them as C0 or C2 completion.

## Product paragraph proposal

For owner review before editing PRODUCT.md:

> ConceptStudio also prepares assets for video shots made in ComfyUI. In the Shots workspace, the user
> places people and simple set pieces, marks their movement, and frames a virtual camera. It exports
> guide images, pose and layout control videos, actor masks, shot details and an H3 prompt as a folder
> the user carries into their ComfyUI graph.

This proposal does not change PRODUCT.md or claim approval.

No merge, release, deployment or paid operation has been performed.
