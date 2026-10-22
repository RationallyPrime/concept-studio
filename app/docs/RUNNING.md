# Running ConceptStudio

Open `app/dist/ConceptStudio.app` in Finder and build a training set, write captions and train
an image or video model from your Mac. ConceptStudio runs on **macOS 15 or newer**. Running
the app requires no Python, terminal, local GPU or development environment.

To build the app, follow [Building and distribution](#building-and-distribution). If macOS
blocks an unsigned build, attempt to open it, then choose **Open Anyway** in System Settings →
Privacy & Security. A Developer ID release with notarisation opens normally. Approve Keychain
access when macOS asks so the app can use your saved accounts.

## First run: the offline demo

Choose **Try the demo** in Welcome to explore the complete workflow with 24 synthetic
portraits, prepared captions and simulated cloud services. The demo stays offline, uses no
credentials and incurs no charges. Its Demo badge stays visible; Apple Photos import is
disabled. Close the project to return to Welcome and connect your accounts.

1. **Images:** inspect the photographs. Exclude a sample and restore it with **Undo curation**.
   Open **Inspect and crop**, then Cancel to keep the prepared captions matched to the images.
   Read the training introduction and prepared dataset advice.
2. **Concepts:** open **Edit concept** to explore the fictional person and trigger, NORA7.
   Advanced settings add multiple concepts and detailed caption instructions.
3. **Mapping:** inspect the prepared assignments and confirm a sample. Try a simulated model
   request. Style-only and motion-only projects skip this screen: those concepts apply to
   every training target.
4. **Captioning:** choose **Start captioning**. Try **Unusable**, **Failed** or **Rejected** to
   practise recovery; Rejected uses the optional reviewer. Return to **Success** and enable
   overwriting existing model captions to repeat a batch.
5. **Review:** edit a caption, mark it **Final** and save. Future model runs skip it. Compare
   captions or re-caption one or several unprotected samples.
6. **Publish:** choose **Simulate dataset upload** to prepare the project files locally.
   The demo dataset name carries through to training.
7. **Cloud GPU:** refresh offers, compare hourly prices, set a budget and rent a simulated GPU.
8. **Training:** inspect the model, settings and GPU plan, then choose **Start training**.
9. **Monitor:** follow the simulated learning curve, logs and saved settings. **Load settings
   for repeat** returns to Training. **Stop everything** ends the simulation. Base-versus-LoRA
   generation is available with a real trained result.

Use **Definitions** on any screen to explore its terms. Hover, click, or focus a term and press
Space or Return; Escape closes the definition. **Help → ConceptStudio Help** (⌘?) opens the
searchable glossary and full training introduction, even before you open a project. Switch
between **Plain language** and **Show me the good stuff** for the depth you want. The glossary
also covers techniques beyond the app's current controls; the model picker shows what you can
train here.

## A real project

Choose **New project…** and select its folder. Import your images or clips, then define the
first concept on Concepts. Images are copied into `images/`, reference photos live in
`references/`, and `job.yaml` records the training-caption configuration. Captions and response
records sit beside the media as `.txt` and `.json` files. Marking a caption Final records
`source: human`, protecting it from future model runs. The app and CLI share these formats;
see [CORE-SPEC](CORE-SPEC.md). Credentials stay in Keychain, separate from project files.

Open **Accounts & settings** to choose **Continue with ChatGPT**, **Connect OpenRouter** or a
manual account key. A single OpenRouter, Vercel AI Gateway or Pydantic AI Gateway key gives
access to its model catalog. Direct providers are available too. Add Hugging Face and RunPod
credentials in the publishing and training section.

Saving a key checks account access without generating a caption. The **Captioning connection
test** uses your selected model and consumes that account's allowance. Captioning lists models
and their declared media capabilities; **Other model…** accepts custom model names. Changing
provider selects its default model. Gemini accepts both bare IDs and Google's `models/` prefix.
Your choices are remembered in the job and local preferences.

For a custom vLLM server, set its URL in Advanced settings. The app sends your saved server key
only to that origin: the same scheme, host and port. An imported project pointing to a different
origin needs its own authorization. Paths on the configured origin share the saved key.

### Caption with your ChatGPT plan

Choose **Continue with ChatGPT** in Settings, read the access explanation and approve sign-in
in your browser. On Captioning, choose **OpenAI → ChatGPT plan**, then select a model from your
account's catalog. **Manage usage** opens [ChatGPT usage settings](https://chatgpt.com/settings/usage)
for your allowance and app limits. Choose a model with image support for photo captioning.

The selected account handles every OpenAI request: captions, the optional reviewer, model
comparisons and photo/concept assistance. **OpenAI API credits** selects your separate API key;
the app never switches billing routes automatically. ChatGPT plan access depends on account
eligibility, and usage draws on the plan or credit balance according to the permissions you
approve. Other providers use their own accounts.

The ChatGPT route accepts images and returns native structured captions or JSON. Leave output
token limits and sampling controls such as temperature unset: this API does not accept them.
Unsupported settings produce an error. Reaching a usage limit stops new requests and directs
you to **Manage usage**; completed captions stay saved.

Select an existing account to reuse it, **Sign in again** to renew authorization, or
**Continue with ChatGPT** to add another account or workspace. **Sign out** clears local tokens
and requests remote revocation. If remote revocation cannot be confirmed, disconnect the app
in ChatGPT settings. The authentication choice stays on this Mac; shared jobs retain
`kind: openai` without OAuth tokens. The Python CLI uses its configured OpenAI API credentials.

See OpenAI's [sign-in flow](https://developers.openai.com/siwc/token-sharing-open-source/sign-in)
and [API limitations](https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations)
for the service contract.

### Connect OpenRouter

Open **Accounts & settings → Connect OpenRouter** in a real project and approve access in
your browser. ConceptStudio saves the returned key in Keychain and sends caption requests
directly to OpenRouter. Cancelling leaves your previous key in place. Check account status
for the usage and allowance OpenRouter supplies; an unavailable balance is displayed as
unavailable. See [OpenRouter authorization](https://openrouter.ai/docs/guides/overview/auth/oauth).

### Prepare and train

Import from a folder, selected files, Apple Photos or a Hugging Face imagefolder dataset.
HEIC and TIFF images become oriented PNG training targets. Matching `.txt` captions and
`.json` response records travel with their images, including through format conversion and
filename changes. Captions imported from text show **Imported**; human-final records stay
protected. Use Captioning's bulk protection action before a rerun to keep imported captions.
Parquet-only Hub datasets require conversion to imagefolder before import.

Review dataset advice, duplicate candidates and **Include in training** before captioning.
Advice samples up to 48 evenly selected examples; the full included set remains available for
training. Excluded media stays in the project. **Undo curation** restores a selection or
approved edit during the current session.

Define a concept and choose **Confirm concept and continue** (⌘↩). Person and object/character
concepts require confirmed locators. Reference photos guide suggestions; person concepts need
references for model-assisted identity proposals. Manual mapping works without references.
With one detected face, checking a person concept fills the locator from its class noun;
describe the subject explicitly in multi-person
scenes. Review on-device matches and model proposals before confirming them. Accept one
proposal or all eligible suggestions, and use Undo to reverse a confirmation. Style and motion
concepts apply to the whole target and skip Mapping.

Use **Inspect and crop** to preview the exact image crop before approval. Approval replaces
the training target and clears its caption and subject assignment for a fresh review; style
and motion assignments carry forward automatically. For video, set **Start time** and
**Duration**, preview the segment and choose its training model. **Advanced: Exact frames and
size** exposes frame indices, supported frame counts and dimension limits.

Video preparation follows the chosen model's requirements:

- **LTX:** 9–257 frames in steps of eight. Select a constant-frame-rate portion; variable
  timing cannot be retained by the current trainer.
- **H3:** 5–243 frames in steps of seventeen, at exactly 24 fps. Other rates, including
  23.976 fps, require conversion before approval.
- Approval preserves the selected timing and full scene, aligns dimensions for the trainer,
  and writes the MP4 used by both captioning and training. Inspect its frames or play it back.
  LTX derives its buckets from these targets; H3 groups clips by exact frame count and uses
  a resolution cap that retains the approved dimensions.
- Gemini accepts inline video and samples it at 24 fps. OpenRouter and vLLM accept video when
  the selected model supports it. OpenAI and Anthropic routes accept images only. The Python
  CLI supports Gemini/OpenRouter video; its pydantic-ai route does not support vLLM video.
- Encoded video requests must stay below 20 MiB, including prompts, schema and retry history.
  See the [CORE-SPEC route table](CORE-SPEC.md) for the complete contract.

Approving a segment selects the matching LTX or H3 caption format. Review or re-caption saved
text when changing formats; existing captions retain their text.

**Upscale and restore…** on Images enlarges and repairs images or clips with SeedVR2 on your
cloud GPU. Choose the media and model, then compare each returned result with its original
before keeping it. Pay particular attention to faces: restoration can invent detail.
**Put back original** restores the source even after reopening the project. The automatic
`v0.3.9-20261022` pod images include SeedVR2; see [pod images](../../pod/images/README.md) for
image contents and [POD-STATUS](../../pod/docs/POD-STATUS.md) for execution records.

Hosted captioning needs no GPU rental. For self-hosted captioning, choose **Rent or choose a
cloud GPU for captioning**, rent on Cloud GPU, then return and choose **Start caption server
and use this cloud GPU**. ConceptStudio starts the server and checks its authenticated vLLM
endpoint. Complete captioning and dataset preparation before training on a single GPU.

The app automatically chooses the training image for your trainer. Set a custom image under
**Settings → Advanced user**, or clear and save the field to use **Automatic**. The GPU list
shows stock beside your selected network volume. With **No saved storage**, the GPU receives
a 300 GB persistent disk: **Stop** keeps its files, **Remove** deletes them. A network volume
can be reused by another GPU in the same data center. Both storage choices continue billing
while the GPU is stopped.

Cloud GPU and Training list the prerequisites for training with links to the relevant steps.
Complete them before starting training; you can rent earlier when you need the GPU for
captioning. If a stopped GPU's host has no free GPU, retry later or use **Remove it to rent a
new one…**. Read the listed disk contents before confirming deletion. Retrieve uncollected
results from the same stopped GPU first; the app blocks removal while those results remain
unsettled or unsaved.

Turn on **Settings → Advanced user** for custom servers and images, caption model and batch
controls, multiple concepts, caption overrides and detailed training controls. Turning it off
keeps your settings; each screen lists active non-default choices. The training picker adds
18 AI Toolkit architectures with their licences and upstream issue notes. **Unverified recipe**
identifies settings drawn from the trainer's defaults rather than a measured GPU run. Use a
pod image containing the same model table; see [models and recipes](../../docs/model-table.md).

Set training length in the number field. For H3, Advanced controls checkpoint cadence,
retention, saved precision, resolution buckets and adapter selection. Automatic selects
Circlestone's adapter for still images and Ostris's v3 when clips are included. Circlestone's
adapter requires guidance preservation loss off. Ostris's adapter and adapter-free training
support that control. New H3 selections start with checkpoints every 300 steps, 40 retained,
float32 saves, 768/1024 resolution buckets and guidance loss off with target 3.5. Imported
recipes and repeated runs retain their saved settings. Generation guidance is a separate
control.

Choose hardware for the training model:

- **FLUX and LTX:** at least 32 GB GPU memory. LTX defaults use an 8-bit text encoder,
  quantized training, an 8-bit optimizer and tiled image preparation.
- **Qwen-Image-2.1:** at least 80 GB GPU memory for bf16 training without quantisation.
  Accept its Qwen Research License terms, including non-commercial use. The first model
  download is about 32.5 GB.
- **Krea 2 (Raw):** at least 96 GB GPU memory for bf16 training. Accept the Krea 2
  Community License access conditions on Hugging Face and configure your token. Training
  uses Raw weights; generated previews use Krea 2 Turbo at eight steps.
- **H3:** the BF16 recipe uses a 96 GB GPU reference. The app checks the connected GPU's memory
  before uploading inputs. Batch size and resolution still determine the run's memory use.
- Rentals request at least 60 GB host RAM per GPU for model loading.

For exact recipes, hardware measurements and execution coverage, use the
[model table](../../docs/model-table.md) and [APP-STATUS](APP-STATUS.md).

To start from an existing H3 LoRA, import its native AI Toolkit recipe on Training and select
its `.safetensors` weights. Both files are copied into the project. Review the imported
optimizer, precision, trained-layer settings and new training length, then start. This creates
a new run at step zero on the selected project's dataset, with fresh optimizer state and model
components downloaded at pinned revisions. Reopening the project before starting requires
selecting the recipe and weights again; the copied files remain. **Resume latest checkpoint**
continues an existing run and its state on the original storage instead.

With a Hub token, Publish sends the included targets, saved sidecars, imagefolder metadata and
`concept-captioner/job.yaml` in one commit. Media names remain the shared sample IDs; reference
images stay local. **Private dataset** is on by default.

Without a Hub token, choose **Check training data** on Publish. **Start training** captures
saved inputs, uploads them through the pod agent and waits for installation before launching
the trainer. Limits are 2 GiB per file and 20 GiB per dataset. Editing is held only while the
snapshot is captured. A Hub dataset account is unnecessary for this route; gated base models
such as FLUX.1-dev still require their own access credentials.

Set the rental's spending limit before creating the GPU and the separate run budget before
training. A new run starts a new spend total. Resume keeps the run's cap and adds continuation
cost; raise the cap explicitly before resuming a run that reached it. Either limit stops the
GPU. Estimates cover GPU time; RunPod bills storage separately.

**Keep ConceptStudio open on an awake Mac while the GPU runs.** The spending and idle guards
run in the app. App-managed work such as dataset publishing holds off the idle stop and
restarts the countdown when finished. **Stop everything** cancels local work, waits for it to
settle and stops the GPU. Close and Quit warn while work or a GPU is active, and keep the
project open until a requested stop is confirmed. A saved running GPU's cost and Stop controls
appear on Welcome after relaunch, even before a project is opened.

Stopping clears temporary container storage, keeps the persistent pod disk or network volume,
and leaves storage billing active. Remove the stopped GPU before renting another. Network
volumes survive removal; the GPU's own disk does not. See
[RunPod's storage rules](https://docs.runpod.io/pods/storage/types).

Caption drafts follow you between samples and screens. **Save caption** or Command-S on
Review writes the selected draft; **Discard edits** restores the saved text. Closing,
quitting or switching projects asks before discarding drafts. Dataset preparation uses saved
captions, so save edits before publishing or training.

Use **Clean completed dataset copies** on Cloud GPU to reclaim eligible dataset storage.
The same cleanup runs at training and generation start. It preserves current, active, failed,
unknown and shared inputs, plus the latest three resumable completed runs. Checkpoints,
generated results and model caches stay on storage. Cleanup runs on these actions, without
a background timer.

### Try a trained result and reuse a run

Open **Monitor → Generated results** for a base-versus-LoRA comparison on the supported
FLUX.1-dev, Z-Image, Qwen-Image-2.1, LTX-2.3/2.5, H3 and Krea 2 routes. Select a checkpoint,
enter prompts and seeds, then generate.
Both sides receive identical inputs with the LoRA as the changed variable. H3 generates still
images or video, including from a LoRA trained on still images. Complete comparisons are saved
in the project gallery. Failed comparisons retain any downloaded files for inspection and
show the failure; unsupported model/trainer combinations explain the requirement.
**Save trained model to this Mac** downloads the model files.

Set **Save trained model to** on Training for the current project. With a Hub account, an empty
destination starts as `<account>/<project>-lora`; edit it to choose another repository.
Without a Hub token, the result goes to the project's results folder. Each run retains its
original destination and privacy, including when you retrieve or publish it later.

Open **Saved runs** for dataset revisions, training settings, checkpoints, outputs and cost
records. **Load settings for repeat** copies a run into Training and starts with its recorded
dataset revision. Edit the settings, or choose **Use this project's current dataset instead**
to refresh its data revision, caption format, triggers and video status while keeping your
training edits.

For trainers that support resuming, **Resume latest checkpoint** continues from a supported
checkpoint on the same storage, with a total step count above the checkpoint step. Pruned Hub
inputs are restored from the pinned revision. Direct-upload runs
use their original local inputs and reject changed media, saved captions or job settings;
use Repeat to train changed inputs as a new run. Missing revision or billing data is shown as
unavailable; recorded GPU estimates exclude storage charges.

## Building and distribution

Build from the repository root with Xcode installed:

```sh
scripts/build-app.sh debug
# app/dist/ConceptStudio.app
CONCEPTSTUDIO_SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' scripts/build-app.sh release
# signed and notarised, with a notarytool keychain profile stored once:
CONCEPTSTUDIO_SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
  CONCEPTSTUDIO_NOTARY_PROFILE=<profile> scripts/build-app.sh release
# then the shareable disk image (same two variables): app/dist/ConceptStudio-<version>-<date>.dmg
CONCEPTSTUDIO_SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
  CONCEPTSTUDIO_NOTARY_PROFILE=<profile> scripts/build-dmg.sh
```

The build copies the executable and resources into `app/dist/ConceptStudio.app`. It compiles
`app/Packaging/ConceptStudio.icon` with `xcrun actool`, so Xcode is required in addition to the
command-line tools.

Debug builds use an available **Apple Development** identity automatically, or the identity
you supply. Without a signing identity they are unsigned and run without the sandbox.
Release builds require the named **Developer ID Application** identity in Keychain and apply
the sandbox entitlements, hardened runtime and timestamp before verifying the signature.

Store notarisation credentials once with `xcrun notarytool store-credentials <profile>` and
set `CONCEPTSTUDIO_NOTARY_PROFILE` for release distribution. The script submits the app to
Apple, waits, staples the ticket and checks it with `spctl`. Use the same signing identity
across builds to preserve a stable app identity; changing it can require new Keychain and
folder-access approvals. Building does not launch the app.

`build-dmg.sh` requires a notarised Developer ID app. It creates
`app/dist/ConceptStudio-<version>-<date>.dmg` with the app, an Applications link and the app's
volume icon, then signs, notarises and staples the image. Public release availability and
verification records are in [APP-STATUS](APP-STATUS.md).

Run `swift test` and `swiftlint lint --strict` from `app/`.
`swiftformat Sources Tests --lint` checks formatting. The native UI conventions are in
[DESIGN.md](../DESIGN.md).

After the normal build has populated its Yams checkout, render the app's screens from the
repository root:

```sh
scripts/render-app-preview.sh
# Offscreen PNGs and source/render manifests in app/dist/visual-check
```

The render pass captures minimum and default window sizes in light and dark appearances,
using the offline demo and isolated preferences. It leaves the desktop untouched. Use the
running app to check keyboard navigation, VoiceOver, titlebars and native vibrancy. Ordinary
`swift test` skips this render pass.

`app/ConceptStudio.entitlements` declares the sandbox, user-selected read/write access,
security-scoped bookmarks and network-client access. The bundle includes its Photos usage
description. Sign-in callbacks listen on `127.0.0.1` and close on completion, cancellation or
timeout. Follow [Apple's distribution signing procedure](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac/)
and consult [APP-STATUS](APP-STATUS.md) for signed-build checks, including Photos access and
permission persistence.
