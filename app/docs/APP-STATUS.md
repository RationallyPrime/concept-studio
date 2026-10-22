# ConceptStudio app status

**ConceptStudio turns your images and clips into trained model adapters in one native Mac app.**
Prepare the dataset, caption it, train on a cloud GPU, compare results and save your adapter.
The [Qwen-Image-2.1 run](#end-to-end-run-through-the-app-2026-10-14) trained for **10,004 steps
in 1 h 19 min at US$3.99 of GPU cost**. The signed, notarised app handled the full workflow,
including regularisation, REPA, private publication and automatic idle stop.

Updated 2026-10-22. The app defaults to **`v0.3.9-20261022`**, including SeedVR2 restoration,
with **seven verified recipes** and **18 additional recipes** under Advanced user.
[Get started](RUNNING.md), explore [captioning](CORE-STATUS.md) and
[GPU services](../../pod/docs/POD-STATUS.md), or see [published images](../../pod/images/README.md).

## Friction fixes, 2026-10-22

Implemented named project creation and Hub URL/subfolder import, recursive folder import,
duplicate exclusion, fixed-bottom Cloud GPU access, kept stopped GPUs, purpose-specific GPU
selection, startup/rental progress, activity-aware idle stops, typed idle intervals and
workspace-scoped storage reporting. Added bulk Mapping, Not sure notes and filtering,
forward-only confirmation, reference selection from thumbnails, resumable contact-sheet
requests, bounded self-hosted concurrency and per-image retries. Removed the general-image
fingerprint reference-match button.

Adult content is a shared Python/Swift job setting. Person defaults describe dress or undress;
adult jobs additionally describe sexual activity and other people. Publish locks privacy on
for those jobs and verifies the actual destination before upload. Hub publication and direct
GPU upload omit uncaptioned media by default, with an explicit override, and always omit
excluded and Not sure samples. Publication uses saved captions from disk.

Verification completed:

- Full Swift run: 352 app tests and 267 core tests passed. Focused import/project and Mapping
  checks were repeated after the final native-dialog and benchmark-default changes.
- Python package tests, Ruff and type checks passed; affected pod storage tests passed (9).
- Native app walkthrough used synthetic fixtures: named Save panel, nested import, actual
  byte-identical duplicate detection and exclusion, adult policy, single-face confirmation,
  Not sure notes, publication omissions and private toggle.
- A development-signed sandboxed build verified existing-project opening, unrelated-folder
  refusal and remembered Save-panel location. Existing folders use a native Open confirmation
  to grant directory access instead of a destructive-sounding Replace prompt.
- Actual SwiftUI renders covered Mapping, suggested assignments, Concepts and Publish at
  minimum/default sizes in both appearances. A truncated confirmation action was repaired.
- Independent code review covered import, Mapping, GPU lifecycle and shared publishing policy;
  material findings were repaired and independently checked.
- Live ChatGPT Mapping trials and the locator cross-check selected 3×3 contact sheets. See
  [measurement and anonymous receipts](MAPPING-BENCHMARK.md). Source mappings were preserved.

The hosted Mapping measurements are recorded in [the benchmark](MAPPING-BENCHMARK.md).
The requested RTX 5090 Secure Cloud placement was unavailable during this verification run;
the follow-up cloud-captioning acceptance targets a 32 GB Blackwell GPU. The app uses the
published **v0.3.9-20261022** images. Workspace storage accounting changes in this PR need the
next pod-image rebuild; older-agent host totals are suppressed in the app.

## Recent completed work, 2026-10-21–22

**A complete 267-image captioning project.** The owner's 2026-10-22 briefing records taking a
single-person dataset through ConceptStudio **0.3.1** the previous night: Hub import, concept
definition, mapping, captioning on a rented GPU and private dataset publication. The resulting
improvements are in [PR #32](https://github.com/RationallyPrime/concept-studio/pull/32).

**H3 adapter comparison.** The 2026-10-21 experiment trained both adapters for **3,000 steps** on
the same **33-image dataset**, with rank 16, learning rate 1e-4, 768/1024 buckets and seed 42.
On an RTX PRO 6000 with the **v0.3.7-20261021** image, Ostris v3 took about **21 minutes** and
Circlestone about **26 minutes**. Matched base/LoRA images used checkpoints 1200, 2100 and 3000,
seeds 42 and 43, **1024 × 1024**, **28 inference steps** and **guidance 1.0**. Downloaded renders
passed SHA-256 checks; checkpoints were published privately and the GPU was stopped.

Both arms peaked near step 2100, with mean ArcFace similarity **0.371 and 0.366**, respectively,
for Circlestone and Ostris over six trigger-prompt faces per checkpoint. Visual review favoured
Circlestone for natural rendering and the no-trigger control; Ostris trained about 20% faster.
The comparison retained Circlestone as the stills default. Both arms also produced occasional
white side bars, recorded for follow-up. This comparison used one subject and two render seeds.

## Walkthrough integration, 2026-10-12

The walkthrough delivered account setup, project import, caption review and GPU controls in one
coherent flow. Settings separates captioning connections from publishing and training accounts.
Connection checks validate saved keys; Captioning tests the selected model. Provider catalogs
follow the account and server in use. Imports preserve captions and response records through
renaming and normalization. Mapping supports bulk acceptance of proposals with Undo.

Help bundles the supplied **177-entry glossary, two readings and 81 sources**, plus **18
operational entries**. Search, aliases, related terms and contextual definitions connect it to
every workflow screen. Welcome provides orientation; Images holds the full training explanation.

GPU selection follows storage location. Stop preserves persistent pod disks; Remove deletes them.
Output-custody guards protect unsettled results, including runs with lost start acknowledgements.
H3 controls expose checkpoint cadence, retention, precision, buckets and the training adapter.

The integration gate passed **550 Swift tests** (289 app, 261 Core), **118 Python reference tests**
and **315 pod-script tests**, with clean SwiftLint, SwiftFormat and Ruff checks. Independent
review accepted the project, provider and UI changes and closed startup/output-custody defects.
The [repair record](../../docs/process/walkthrough-repairs-2026-10-12.md) covers the seven
hardening lanes and follow-up `cd5f746`. Developer ID signing followed on 2026-10-14.

## Model table

One [model table](../Sources/ConceptStudio/Resources/Training/model-table.json) supplies the app
and pod images with model choices, recipes, GPU requirements, checkpoints, resolutions, video
rules, caption profiles and saved-run capabilities. Model-specific hooks handle H3 recipes,
LTX buckets and generation. See [the model-table guide](../../docs/model-table.md) for the schema
and extension points.

The seven `verified` rows are **FLUX.1-dev, LTX-2.3, LTX-2.5, MiniMax H3, Z-Image,
Qwen-Image-2.1 and Krea 2**. Eighteen `unverified` rows expose the pinned AI Toolkit defaults for
architectures including FLUX.2, FLUX.2 klein, Chroma, SDXL, Lumina 2 and HiDream-O1. Advanced user
shows these as **Unverified recipe**, with their licences, GPU requirements and training notices.

LTX-2.3 and LTX-2.5 replaced LTX-2 on 2026-10-15. Both completed 100 steps at 512 on a 32 GB RTX
5090 with the v0.3.4 LTX image: **5.0 and 5.8 minutes, 27.6 GB peak**, followed by matched
base/LoRA clips through `generate-ltx`. LTX-2.5 used the split-pack path and requires gated Hub
access. Z-Image and Qwen-Image-2.1 present training length in epochs and send steps to the trainer;
both compare through `aitoolkit_arch_image`. Z-Image's picker documents use on Z-Image-Turbo at
about twice the strength. Qwen-Image-2.1 requires a GPU with at least 80 GB.

## Advanced user switch

**Settings → Advanced user** opens custom servers and images, model and batch controls,
multiple concepts, caption overrides, starting-model selection and detailed training settings.
The switch starts off and is remembered per install. Hiding advanced controls preserves their
values; each screen identifies active non-default settings and where to edit them.

## Regularisation images and REPA

Qwen-Image-2.1 offers **Regularisation images** and **Representation alignment (experimental)**
on Training. The app shows the image count, class nouns, download sizes, preparation-time and
cost estimates, and regularisation's roughly doubled training time. Advanced controls expose
regularisation strength.

The app draws regularisation images with the base model, then uses the project's captioner,
skill and profile to describe them by class noun, without identity triggers. On one GPU it
switches between drawing and captioning services. Saved runs capture the generation settings,
captions and all six REPA settings so Repeat restores the original configuration. Epoch/step
conversion accounts for alternating training and regularisation examples.

The [model-table guide](../../docs/model-table.md) describes eligibility and configuration;
bundled Help explains regularisation, prior preservation and representation alignment. The
[2026-10-14 run](#end-to-end-run-through-the-app-2026-10-14) exercised both aids through the app.

## Upscale and restore with SeedVR2, 2026-10-22

**Upscale and restore…** selects images and clips from Images, recommends samples below the
training resolution, and offers SeedVR2 3B or 7B. The sheet shows the GPU price, weight-download
size, model licence and restoration guidance. Results appear beside their originals for review.
**Keep**, **Discard** and **Put back original** manage each result, including after project reopen.

The app uploads media under neutral names, starts `upscale-media`, displays completed-item
progress and verifies downloaded SHA-256 hashes. Keep preserves the locator mapping and retains
the original caption with the original media. The GPU stays active throughout processing.

The **published v0.3.9 images include SeedVR2** and passed import/CLI and authenticated CPU agent
checks. Automated tests cover keep, discard, persistent revert, name collisions and the app's GPU
flow through a fake agent; light/dark renders cover selection and review.
[GPU status](../../pod/docs/POD-STATUS.md), [published images](../../pod/images/README.md) and
[the service contract](../../pod/docs/POD-SPEC.md) carry the runtime results and implementation details.

## Implemented

- **Prepare training examples.** Import images and clips from files, folders, Photos or Hub
  imagefolder datasets. Review duplicate groups, include/exclude examples, crop images, normalize
  HEIC/TIFF and approve exact video segments. Undo restores curation changes. Publication removes
  previously published excluded targets and preserves unrelated remote files.
- **Define the concept.** Start with one person, object, character, style or movement. Style and
  motion map to the whole target; locator concepts use confirmed subject assignments. Advanced
  settings add concepts and caption-policy overrides.
- **Work with exact clips.** Playback and frame inspection support approved constant-rate segments
  with aspect-preserving, 32-aligned dimensions. LTX uses `8n+1` frames; H3 uses `17n+5` at 24 fps.
  LTX derives its preprocessing buckets from those targets. The editor identifies variable-rate
  selections that need a constant-rate portion. Provider support is listed in [Core status](CORE-STATUS.md).
- **Caption and review.** Choose a provider, review captions beside the media and protect final
  captions. ChatGPT streams real text into the per-sample preview; completed validated captions
  are saved. Imports preserve existing captions and human-final records.
- **Publish or upload directly.** Hub publication carries included targets, saved captions,
  records, metadata and the shared job. Without a Hub token, Start training sends an immutable
  snapshot directly to the agent: up to 2 GiB per file and 20 GiB per dataset. Resume checks the
  exact input digest; Repeat accepts edited inputs as a new run. The direct route is included
  in v0.2.2 and later images.
- **Save, repeat and resume runs.** Project history records dataset revisions or input digests,
  settings, checkpoints, outputs and available GPU cost data. Run budgets begin before input
  preparation; Resume retains the cap and accumulates continuation cost alongside the computer cap.
- **Compare and retrieve results.** Supported model routes generate base/LoRA pairs with matched
  prompts, seeds and selected checkpoints. Downloads verify each manifest-listed file and retain
  partial outputs for recovery. Models and comparison galleries can be saved to the Mac.
- **Connect accounts.** ChatGPT sign-in and OpenRouter browser authorization have separate account
  flows. OpenRouter uses PKCE and a loopback callback; credentials are stored in Keychain. Manual
  provider keys remain available.
- **Manage projects and storage.** Recent projects retain recoverable entries after access failures.
  Storage controls report usage and clean completed datasets while retaining active inputs and the
  last three resumable datasets. A pruned Hub dataset is restored from its saved exact revision.
- **Control GPU cost and output custody.** Budget and idle stops, startup reconciliation and
  pending-output guards run in the Mac app. RunPod secrets deliver Hub and agent credentials to
  the pod through secret references. Project-contained skills and CLI-compatible job/sidecar
  formats keep work portable.

## Exercised in the native window

**2026-10-11 offline demo:** a native walkthrough covered Welcome, all nine journey screens,
Settings, Advanced controls, File/Go menus and scrolling. It exercised synthetic-photo import,
Exclude/Undo, crop preview, prepared mapping and captions, Final/Save protection, simulated
publication and rental, training completion, saved settings, Repeat and Stop. The walkthrough
caught and repaired paragraph width and concept-sheet state; custom style details survived reopen
and an unchanged Save.

**Clarity and repair checks:** Concepts ⌘↩ opened Mapping for Person and Captioning for Style/Motion.
The crop preview showed all four edges and dimmed excluded pixels. Reference comparison displayed
agreement or no confident suggestion alongside human mappings. Caption edits showed the unsaved
notice without moving the image. Recent entries displayed parent folders and removal controls.
Monitor distinguished **Training: Finished** from **Computer: Running** in the simulated run.
The expanded Concepts controls, **Demo · no charges** badge, simulated storage cleanup and Stop
were inspected in the rebuilt window.

Keyboard controls and downloaded media passed the
[unlocked-Mac checks](#unlocked-mac-follow-up-2026-10-11).

## Offline verification

| Gate | Passing checks |
| --- | --- |
| Walkthrough/glossary integration, 2026-10-12 | 550 Swift: 289 app + 261 Core; 118 Python reference; 315 pod scripts |
| Walkthrough/H3/help, 2026-10-11 | 498 Swift: 238 app in 39 suites + 260 Core in 38 suites; 117 Python reference |
| Walkthrough clarity, 2026-10-11 | 478 Swift: 218 app + 260 Core; clean Swift formatting across 153 files |
| Review repairs, 2026-10-11 | 450 Swift: 190 app in 29 suites + 260 Core in 38 suites; 116 Python; 660 agent; 291 pod scripts; 125 podctl |
| Overnight implementation | 402 Swift: 160 app + 242 Core; 94 Python; subsequent dataset-switch repair: 23 session/history tests |

SwiftLint, SwiftFormat and Python Ruff/format passed the respective gates. The review-repair and
overnight formatter passes covered 145 and 129 Swift files, each with two resource exclusions.
Debug builds and independent reviews passed across the six repair threads, upload flow and
dataset-switch fix.

Coverage includes authorization and cancellation; seven concept categories; exact media and
sidecars; curation and Undo; Hub file selection; immutable direct upload, quotas and digest
checks; generation requests; run restore/repeat/resume; budgets and output custody. Synthetic
H3 fixtures export **22- and 39-frame audiovisual segments**. Video tests check variable timing,
visible edges, HEIC/TIFF normalization and restoration. Actual URLSession SSE reaches the runner
before sidecar creation and clears correctly on retry, failure and cancellation.

The offscreen harness rendered **116 light/dark, minimum/default states**, including Help at
**640 × 480 and 780 × 720**, with clean lint/format across **164 Swift files** at the earlier
presentation gate. Review covered all nine screens, Welcome, Settings and Help; focused rerenders
checked Captioning width and video-editor start/duration controls. Expanded Advanced controls,
keyboard interaction and native vibrancy were checked separately in the native window.

<a id="live-evidence-and-remaining-acceptance"></a>

## Live runs and follow-up checks

On 2026-10-10, lab commit `e620882` completed private Hub upload/download, Gemini and vLLM image
captioning, native RunPod status/stop and FLUX/LTX event reads.

| Run or connection | Recorded result |
| --- | --- |
| Gemini native video, 2026-10-11 | Exact approved synthetic MP4: 9 frames, 512 × 288. `gemini-3.8-flash` returned HTTP 200 and a usable Caption; 4,389 input / 76 output tokens. Explicit 24 FPS sampling resolved the default-sampling 400, checked with a single-variable control and the production client. |
| FLUX generation and Resume, r1 image | Matched 256 × 256 base/LoRA PNGs, seed 42, four inference steps; downloaded files and manifest matched their hashes. Resume advanced the synthetic run from step 2 to step 3 and saved a distinct checkpoint with step-3 metadata. |
| LTX video, r2 image | Preprocessed the approved 512 × 288 × 9 clip, trained two steps and resumed to step 3. Matched videos each decoded to 49 frames at 512 × 512, 24 fps; the complete manifest recorded the step-3 checkpoint hash. |
| Native retrieval and reopen | FLUX and LTX models/comparisons downloaded through the app and reopened offline. The FLUX import restored one run and one comparison. |
| TensorBoard access | Session/cookie handshake passed through the real RunPod proxy, including unauthenticated and out-of-scope rejection. |
| ChatGPT and OpenRouter, 2026-10-11 | Owner confirmed native sign-in and live image captioning with both providers. |

Both FLUX/LTX runs used **one 32 GB GPU and 62 GB host RAM**. After output retrieval, independent
status reads confirmed both GPUs **Exited**. FLUX ran on r1, followed by source/hash and CPU checks
of the checkpoint-snapshot repair; LTX ran on final r2. The LTX input hash matched at native export
and exact-revision Hub download.

The Gemini results, including all three requests, are in
`evidence/2026-10-11-video-native-proof/README.md`.
[Published images](../../pod/images/README.md) lists release commits, digests and build history.

## End-to-end run through the app, 2026-10-14

A **Developer ID-signed, notarised and stapled release build** completed the first full training
run through the app's interface with a real single-person image dataset. macOS requested Keychain
access once per stored key on first use.

| Stage | Result |
| --- | --- |
| Publish | Dataset published to a private Hub repository. |
| Rent | One RTX PRO 6000, 96 GB, with a persistent pod disk and `v0.3.3-20261014` AI Toolkit image. |
| Regularisation | 40 base-model images generated and captioned without the identity trigger. |
| Train | Qwen-Image-2.1, 10,004 steps, regularisation and REPA: DINOv2 giant, block 8, weight 0.5. Checkpoints every 500 steps; elapsed time 1 h 19 min. |
| Deliver | Final LoRA pushed to a private Hub model repository. Intermediate checkpoints retained on the pod disk and copied separately. |
| Record | Saved runs captured model, dataset, settings, destination and US$3.99 GPU cost against a US$10 run budget. |
| Stop | Automatic idle stop ended GPU billing. |

The run drove five fixes: removal of an absent computer under the current key (#16), project-owned
training destinations, publication guidance and upload activity tracking, clearing stale 404 event
status, and a labelled run budget (PR #17).

## Next checks

- Update [GPU status](../../pod/docs/POD-STATUS.md) with current-image results for SeedVR2
  restoration, direct upload, storage cleanup and generation/Resume.
- Reconcile H3 clip training/generation, external warm-start and same-run Resume follow-ups with
  the latest runs; add a clip-adapter comparison alongside the completed still-image experiment.
- Record native TensorBoard rendering during a live run.
- Record human VoiceOver navigation and signed-build Photos/bookmark behavior across rebuilds.
- Publish a public download. Developer ID signing, notarisation and stapling are complete.

**Operating requirements:** keep ConceptStudio running and the Mac awake for budget and idle
stops. Startup reconciliation resumes these guards. Stopped GPU storage continues to accrue
storage charges. [RUNNING.md](RUNNING.md) covers account, cost and storage operation.

## Unlocked-Mac follow-up, 2026-10-11

Native synthetic-clip import and playback passed. A selected segment starting at frame 19 exported
as **17 frames, 30 fps, 512 × 288**; Undo restored the original hash. A zero-tolerance seek repair
made the selected first and late frames display correctly. Tab reached glossary terms; Space and
Return opened their popovers and Escape closed them. All three keys passed in the rebuilt window.

The retained FLUX comparison displayed two labelled images, with working gallery/model Reveal
links in Finder. The retained LTX pair reopened in native video players and played successfully.
Command-number navigation and Go Back passed. OpenRouter opened browser authorization and
cancelled cleanly; ChatGPT reached two-factor authentication and cancelled cleanly. The owner
subsequently completed both sign-in and live-captioning paths.

Recent-project restoration passed across restarts of the same preview build. An ad hoc rebuild
exposed a bookmark-access failure; the repair retained the Recent entry and requested folder
reselection. Native readback confirmed both behaviors. The repairs passed **25 focused Swift
tests**, lint/format and independent review.

<a id="h3-source-integration-and-remaining-runtime-proof"></a>

### H3 training and generation

The H3 route uses pinned AI Toolkit `minimax_h3`, BF16 component downloads, exact approved clip
groups and imported native recipes. New runs can initialize from external LoRA weights with fresh
counters and optimizer state. Same-run Resume retains its separate continuation path. Comparisons
capture the native network recipe and selected weights for matched base/LoRA prompts and seeds;
still-trained adapters support still or video generation.

The app applies a **96 GB GPU requirement** for the reference recipe. Metadata checks accepted
**18 prepared clips** with exact decoded frame counts, **24 fps**, **32-aligned dimensions** and
a **1024 resolution cap**. Export, initializer, generation and budget checks passed offline.
The v0.2.3 release powered the still-image run below. The later adapter comparison exercised
matched image generation on v0.3.7.

## Owner/Claude H3 run, recorded 2026-10-12

The [walkthrough record](../../docs/process/walkthrough-2026-10-11.md) reports **3,000 training
steps on 69 still images**, with Gemini captions, the clean **v0.2.3 AI Toolkit image** and a
**96 GB RTX PRO 6000**. The **179 MB LoRA** was published privately and the GPU stopped after
approximately **72 minutes**, at an estimated **US$3 GPU cost**.

## ChatGPT connection follow-up, 2026-10-11

The rebuilt ChatGPT client handles raw-byte SSE framing (`60469b4`) and captions delivered through
`response.output_item.done` before a successful completion with `output: []`. It retains indexed
completed items, requires `response.completed`, preserves a populated final output and rejects
failed, incomplete, interrupted or refused responses.

Settings prepares the selected account's model catalog within its cancellable connection test,
so a fresh launch can test the account immediately. Native Settings confirmed ChatGPT plan access
and the OpenRouter credential in Keychain; Gemini's key was installed separately.

A live request through the rebuilt **`ChatGPTModelClient`** sent one synthetic demo PNG and
received **HTTP 200** with a usable Caption from **`gpt-6.1-sol`**, using **2,067 input / 49 output
tokens**. The owner then confirmed the native connection test and live captioning. Focused gates
passed **19 Core stream test methods** and **23 app account test methods**, with independent
source acceptance. Developer ID signing and notarisation followed on 2026-10-14.
