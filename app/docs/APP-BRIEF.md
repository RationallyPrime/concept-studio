# ConceptStudio product brief

**Turn your photos and clips into a trained image or video model adapter—all from your Mac.**

ConceptStudio brings the complete workflow into one native app: prepare examples, define the
concept, generate and review captions, rent a cloud GPU, train, and collect the result. Teach
a model a person, pet, object, style or movement, then use the LoRA in your image or video workflow.

## What it is

The Mac is the studio. It curates the dataset, directs captioning, controls the cloud GPU and
brings the trained adapter home. RunPod supplies the compute; ConceptStudio handles the rental,
training services, progress and results. Users work through the app without a terminal or a
local graphics card.

One concept per LoRA is the default. Its trigger names the concept; captions describe the
clothing, lighting, pose, scene and other details the user wants to control.
Categories shape the questions, subject mapping and caption instructions. The chosen training
model supplies the recipe.

Hugging Face connects through browser sign-in. Users publish datasets and LoRAs and access
their approved gated models from the same account. Credentials are saved in Keychain; pasted tokens
remain an Advanced option.

## Who it is for

A first-time user brings examples and an idea. ConceptStudio supplies the guidance, model
settings and explanations to finish the job without programming or machine-learning experience.
An experienced user gets direct controls, keyboard shortcuts, saved settings and repeatable runs.

- **Lead with the intended result.** Ask what to teach, which details to keep changeable and what the
  user wants to spend.
- **Make the next action obvious.** Each screen explains its operation, inputs and consequences
  in plain language. Errors identify the problem and the action that resolves it.
- **Put expertise within reach.** Define real terms where they appear, including on hover,
  selection and keyboard focus. Keep the substantive training introduction and searchable Help.
- **Keep repeat work fast.** Remember choices and let experts navigate directly. Advanced
  controls reveal depth without resetting retained settings or replaying introductory guidance.
  Keep detailed “learn these traits” and “describe these details” controls under Advanced.
- **Make cost visible.** Show prices before spending, progress while work runs and Stop everything
  throughout the GPU journey.

Interface copy names actions and explains consequences. Keep slogans out of controls and preserve
the native Mac conventions in [DESIGN.md](../DESIGN.md).

## The user journey (one screen each, in this order)

| Screen | What the user accomplishes |
| --- | --- |
| **Images** | Import photos and clips from folders, Hugging Face or Apple Photos. Keep the best duplicates, drag crops, rotate, straighten, and adjust tone and colour while retaining originals. Correct individual dataset outliers. Crop around a chosen person, exclude unwanted samples, or draw supported training loss masks. Select exact video segments. Upscale and restore media with SeedVR2 and a before-and-after preview. |
| **Concepts** | Choose a category, describe the concept and give it a trigger and class noun. Draft concepts with a model and add reference photos to identify subjects. Advanced settings expose multiple concepts and detailed boundaries. |
| **Mapping** | Match identities locally with SFace in Match, Needs review and No match bands, or request contact-sheet model proposals. Confirm eligible matches in batches and keep uncertain samples for review. Identify object and character locations in each target. Style and motion apply to the whole target and go straight to Captioning. |
| **Captioning** | Choose the provider, model, skill, caption format and optional reviewer. Start or cancel a run; follow partial captions and per-sample outcomes as they arrive. |
| **Review** | Inspect each caption beside its actual crop or playable segment. Edit and protect finished captions, re-caption a selection and compare captioning models. |
| **Publish** | Prepare included targets, saved captions, response records and the shared job. Publish a Hub dataset with upload progress and a recorded revision, or check local inputs for direct GPU upload at training start. |
| **Cloud GPU** | Compare GPU stock and prices, choose hardware and storage, set budgets and an idle limit, and manage the rental. See GPU spend and storage charges separately; Stop ends compute billing and Remove confirms deletion of the pod disk. |
| **Training** | Choose a model-specific recipe, regularisation source and supported augmentation. Review the report prompts and shared run budget. Read the allocation plan: caption then train on one GPU, or caption on GPU 0 and train on the remaining GPUs. Repeat a saved run with changes or resume its supported checkpoint state. |
| **Monitor** | Follow curves, logs and TensorBoard. Retrieve the LoRA and its automatic report, compare runs within a frozen prompt group, and inspect identity, bleed, style and adherence scores beside their renders. Generate further matched comparisons on supported routes. Save the trained model to the Mac or publish it to the Hub. |

Welcome offers recent projects, New, Open and Try the demo. Settings holds accounts and advanced
controls. The offline demo provides a complete practice project with synthetic media, prepared
captions and simulated services. Its **Demo · no charges** badge stays visible throughout.

## Required features and implementation notes

### Projects that belong to the user

Projects use the same media, job, caption sidecars and response records as the Python CLI.
Custom skills are copied into the project and referenced with a relative path. Users can move
projects, inspect their files and continue work from the app or CLI.

The approved target is the training target: the captioner, publisher and trainer all consume
the included crop or exact video segment. Explain caption and mapping resets before replacing
media. Preserve clips as clips and describe observed motion and inspected audio. Present
unsupported routes explicitly. Use capture-quality warnings rather than a generic aesthetics score.

### Captioning with the user's accounts

Support ChatGPT-plan sign-in, OpenRouter browser connection, provider and gateway keys, and
self-hosted vLLM. Lead key-based setup with one gateway key; put direct provider credentials
under Advanced. Keep credentials in Keychain and show the active account, available models and
usage-management controls. Switching billing routes is an explicit user choice.

The optional reviewer checks captions against their training media and returns actionable notes.
Partial text appears while a caption is being written; completed, validated captions are saved.
Final human captions stay protected. Category-aware instructions cover people, objects,
characters, styles and motion through one shared job contract.

### Cloud compute with clear costs

Show hourly price, rental spend, storage charges, a training-run budget, a whole-computer budget
and an idle interval. Preserve budget settings and recorded costs with each run. The app stops
compute at the applicable limit and confirms the provider's stopped state. Keep Stop everything
accessible and warn before quitting while a computer is billing.

Keep the app open and the Mac awake during a rental: the app enforces these controls. On launch,
restore and reconcile tracked computers; present other discovered app-owned rentals with stop
controls. Stop preserves persistent storage; Remove deletes the pod disk. Explain that choice
and protect uncollected results.

### The trained adapter reaches the user

Deliver the LoRA to the user's chosen destination: a private Hub repository or the project
folder on their Mac. Preserve uncollected results, checkpoint records and download state across
sessions, and verify downloaded artifacts. Store each run's destination, dataset revision,
settings and outputs with that run.

Publish and direct upload use the same dataset layout. Direct upload trains from the project
without a Hub dataset account. Meet the selected base model's access and licence requirements
on either route. Repeat creates a new run; Resume restores the selected trainer's checkpoint
and optimizer state.

### Native operation from first run to repeat run

Use SwiftUI, native keyboard and window behavior, user-selected folders and security-scoped
bookmarks. Keep long-running work cancellable, report completed work after cancellation and
make the state of rented compute clear when a project closes. Browser sign-in uses a temporary
loopback callback listener that closes on completion, cancellation or timeout.

The app drives ConceptCore for captioning and the authenticated pod agent for remote services.
Keep the pipeline in those components. RunPod is the first GPU provider; the provider interface
and the project's own container images supply the remote execution contract.

## Owner-approved overnight additions and current requirements

The five standing owner decisions follow verbatim. Their implementation history is in the
[decision log](../../docs/ADR-LOG.md); the [2026-10-11 review](../../docs/process/overnight-review-2026-10-11.md)
records the later category, curation, video, run-history, comparison and direct-upload decisions.

- **Project on disk in the same layout the CLI uses** (images, job file, caption sidecars with
  response records), so the app and the CLI interoperate and nothing is proprietary. A custom
  skill the user picks is copied into the project (`skill/<name>/`, written as `skill: ./skill/<name>`); the
  job never points outside the project. *(Owner decision, 2026-10-11.)*

- **Log in with ChatGPT** as an alternative to a key: eligible users can caption with OpenAI
  models on their ChatGPT plan. Captions stream, so progress shows while each one is written.
  Show the active account, available models, plan usage and its management link. Keep
  credentials in Keychain; never silently switch to separately billed API credits.
  *(Owner decision, 2026-10-11.)*

- **Money safety**: price before creating a pod, running cost while it is up, a per-run budget cap
  that stops the pod, an idle watchdog, a warning on quit while a pod runs, and an always-visible
  stop-everything action. Keep the Mac awake while a pod runs; on launch, find pods this app
  created that are still running and show them. *(Owner decision, 2026-10-11.)*

- **The trained LoRA reaches the user**: by default, if the user is signed in somewhere the
  LoRA can be pushed to, push it to a private repo there when training finishes; otherwise
  save the `.safetensors` file into the project. Many users have no GitHub or Hugging Face
  account, so saving to disk is a first-class outcome, not an error. Today the push target is a
  Hugging Face model repo, used when a Hub write token is configured. No stop discards a result
  that has been neither pushed nor saved. *(Owner decision, 2026-10-11.)*

- **Sandbox-compatible from day one** so the Mac App Store stays an option: user-selected
  folders only, no subprocesses, outbound networking plus a temporary `127.0.0.1` callback
  listener for ChatGPT sign-in. Close the listener on completion, cancellation or timeout.
  *(Owner decision, 2026-10-11.)*

### Dated supersessions of the original screen wording

The [afternoon decisions](../../docs/process/overnight-review-2026-10-11.md#owner-decisions-on-the-items-above-2026-10-11-afternoon)
established one concept in the ordinary flow, optional references by category, locator-based
Mapping and automatic style/motion assignments. The
[final fix-round decision](../../docs/process/overnight-review-2026-10-11.md#fix-round-decisions-decided-2026-10-11-afternoon)
added training without a Hub account. The original clauses from `36617c8` follow as the historical
record; the journey above defines the current flow.

Original Concepts clause:

```text
2. **Concepts**: define each trigger, its class noun, one reference face, and the boundary
   decisions, with help text and an option to have a model draft them from a plain description.
```

Original Mapping clause:

```text
3. **Mapping**: for each image, which trigger is who. Detected faces and a model's proposal
   pre-fill the answer; the user confirms with one click or types a locator. Progress is visible;
   unmapped images are easy to find.
```

Original Publish clause:

```text
6. **Publish**: push the project to a Hub dataset, with progress.
```

## Constraints

- Swift 6 language mode, macOS 15 minimum and SwiftPM. Xcode opens the package directly.
- Yams is the only third-party Swift dependency. Use Swift Testing and offline test doubles;
  keep live provider runs separate from the ordinary test suite.
- Build a double-clickable `.app` with the repository script. Support development signing,
  Developer ID distribution and notarisation as documented in [RUNNING.md](RUNNING.md).
- Keep the app free of subprocesses; remote execution goes through the pod agent.
- Google Photos, Google Drive and Gemini batch are outside v1. Re-staging and the
  caption-policy experiment require a separate owner decision.

## Done means

A first-time user finishes the demo without outside research or a dead end. A repeat user reaches
the required controls immediately, reuses saved choices and collects the resulting adapter.
Every screen, sheet, menu, empty state and error supports that journey with clear operations,
keyboard access and visible costs.

Builds, tests, lint and formatting pass. Review the complete interface in the running app.
[APP-STATUS.md](APP-STATUS.md) records delivery and successful runs;
[CORE-STATUS.md](CORE-STATUS.md) covers the captioning library, and
[POD-STATUS.md](../../pod/docs/POD-STATUS.md) covers remote execution.
