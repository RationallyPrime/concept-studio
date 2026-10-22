# Model table

The supported training models are the rows of one JSON file. The app and the pod read the same
file, so a model is added in one place.

The file is `app/Sources/ConceptStudio/Resources/Training/model-table.json`. The app bundles it
(`Bundle.module`, subdirectory `Training`). Both pod images `COPY` it to
`/opt/pod/scripts/model-table.json`; `pod/scripts/model_table.py` reads that path when it exists,
and otherwise the file in the repository checkout. Wrapper scripts and the agent load
`model_table.py` by path.

Code does not branch on a model's name. Where a model genuinely behaves differently, its row
names a **hook** (see [Hooks](#hooks)). Code may still branch on the trainer (`aitoolkit`, `ltx`,
`musubi`): each has its own image, services, launcher and checkpoint layout.

## Format

```json
{
  "format": "conceptstudio-model-table",
  "version": 1,
  "default_model": "flux1-dev",
  "trainers": { "aitoolkit": {...}, "ltx": {...}, "musubi": {...} },
  "models": [ row, row, ... ]
}
```

| Field | Meaning |
| --- | --- |
| `format`, `version` | `conceptstudio-model-table`, `1`. |
| `default_model` | Row id a new project and an unknown caption profile start with. |
| `trainers.<name>.min_cuda` | Lowest host CUDA the trainer image needs, as `major.minor`. |
| `trainers.<name>.default_model` | Row selected when the trainer changes, and the row a custom base model on that trainer borrows its defaults from. |
| `trainers.<name>.resume` | `false`: runs on this trainer cannot be continued from a checkpoint. The app shows no Continue action for them and the agent refuses `resume: true` (musubi-tuner restarts its step counter on `--resume`). |
| `models` | Rows. Order is the picker order, the order of video formats in the media editor, the order of names in messages and the order of family matching. |

Every row field is required unless marked optional; `null` is written where a field does not
apply.

| Row field | Meaning |
| --- | --- |
| `id` | Row id, used inside the table. |
| `display_name`, `short_name` | Names in pickers and messages (`FLUX.1-dev` / `FLUX`). |
| `trainer` | `aitoolkit`, `ltx` or `musubi` (kohya-ss musubi-tuner). |
| `model_ref` | The `base_model` value in run.json, a Hub id. Unique across the table. |
| `source.revision` | Pinned Hub revision, or `null` when the trainer resolves the name itself. |
| `source.weight_repos` | Optional. Other Hub repos the trainer downloads this model's weights from (a repack). With an unpinned revision, cached regularisation images are keyed by the current commit of each. |
| `source.gated` | The Hub repo needs an accepted licence before a token can download it. |
| `source.first_download_gb` | Size of the first model download on a fresh volume, decimal GB. Shown in the picker for rows whose licence notice is on. |
| `source.download_note` | What that size covers. |
| `architecture.arch` | AI Toolkit `model.arch`; `null` for the LTX trainer; for musubi the script prefix (`krea2` runs `krea2_train_network.py`). |
| `architecture.dtype`, `quantize`, `quantize_text_encoder`, `gradient_checkpointing` | Training precision and memory settings. AI Toolkit: `train.dtype`, `model.quantize`, `model.quantize_te` (written when not `null`), `train.gradient_checkpointing`. For the LTX row they describe the settings in `trainer_options.run_extra`. `gradient_checkpointing` is a trainer setting (below). |
| `architecture.model_extra` | Further AI Toolkit `model` keys, in order (FLUX: `is_flux: true`). |
| `family_match` | `substrings` and `tokens` that match a custom base model to this row's AI Toolkit `model` block; `null` for none. Tokens must not touch another letter or digit. |
| `resolution.choices`, `default` | Selectable training resolutions and the ones applied when the model is selected. |
| `resolution.multiple` | `true`: Advanced shows one toggle per resolution bucket. `false`: a single picker. Each chosen bucket adds a pass over the images to an epoch (see [Training length](#training-length)); regularisation images are drawn at the largest. |
| `recipe.length` | `{unit, value}`: the default training length in `steps`, or in `epochs` (passes over each training image and clip). |
| `recipe.learning_rate`, `rank`, `alpha`, `batch_size`, `gradient_accumulation` | Defaults for the editable Advanced fields. |
| `recipe.optimizer` | AI Toolkit `train.optimizer`; for LTX it describes `run_extra.optimization`. A trainer setting. |
| `recipe.lr_scheduler`, `lr_warmup_steps` | AI Toolkit `train.lr_scheduler` (`constant`, `constant_with_warmup` or `cosine`) and, for `constant_with_warmup`, `train.lr_scheduler_params.num_warmup_steps` (0 otherwise); `null` for LTX. Trainer settings. |
| `recipe.caption_dropout` | The share of training images seen without their caption, 0 to 1 (AI Toolkit `caption_dropout_rate` on every dataset); `null` where the trainer has none (LTX). A trainer setting: see below. |
| `recipe.checkpoints` | `every` (steps), `keep` (`max_step_saves_to_keep`; 0 keeps all), `dtype` (saved precision, `null` when the trainer has none) and `editable` (Advanced shows the three checkpoint controls and the app sends their values). |
| `trainer_options` | Optional. `run_extra`: the exact `extra` object the app sends for an LTX run (key order matters). `process`: AI Toolkit `process` keys the typed fields do not cover; the pod deep-merges them over the generic config and under run.json `extra`, which still wins. The app does not read `process`. For musubi it is required and read only by the pod (see [musubi rows](#musubi-rows)). |
| `gpu.min_vram_gb` | GPU offers with less memory are not shown. |
| `gpu.verify_on_pod`, `verify_message` | Before uploading inputs, training, resuming or generating, ask the agent for the real GPU memory and refuse with `verify_message` when it is below `min_vram_gb`. |
| `gpu.note` | The sentence after "These have at least N GB of memory per GPU." |
| `video` | `null` for an image-only model, else the clip training support: `title` (media editor), `frame_law` (`first + k × step` frames), `fixed_fps` (or `null` for any constant rate), `min_frames`, `initial_frames`, `duration_choices` (a fixed list, or `null` for every count on the law) and `select_whole_clip`. |
| `preview` | `training_samples` (the launcher can sample during training), `still` (comparison may produce one still frame) and `video` (`min_frames`, `max_frames`, `choices`, `default_frames`; `null` for images only). Optional `generation`: the `steps` and `guidance_scale` a comparison starts with, for a model whose own differ from the generic 20 steps at guidance 4 (a distilled model run without CFG). |
| `captions` | `image_profile`, `video_profile`, `profile_prefix` (a project caption profile starting with it selects this model) and `titles` (display names of this row's profiles). |
| `selection.follows_project_profile` | The selection may move to the project's profile model when the project's caption profile changes. |
| `license` | `id`, `name`, `url`, `notice`, `show_notice`. With `show_notice` the picker shows the notice, a link and the download size, and the pushed model card carries the licence. `id` is the Hub's licence identifier when the Hub lists one (the card says `license: <id>`); otherwise the card says `license: other` with `id` as `license_name`, which the Hub accepts only as lowercase letters, digits, `-` and `.`. |
| `usage_note` | Optional. A sentence about using a LoRA trained on this model, shown under the picker and in the model card's `## Use` section. |
| `hooks` | Concern to hook name; an absent concern is the generic behaviour. |
| `regularization` | Prior-preservation mode (`generate`, `folder`, `unsupported`), defaults and explanation for this row. See [Regularisation and REPA fields](#regularisation-and-repa-fields). |
| `repa` | Optional. Representation alignment is offered for this row, with its defaults. See [Regularisation and REPA fields](#regularisation-and-repa-fields). |
| `notes` | Free text for maintainers. Not displayed. |

Readers keep the order of `architecture.model_extra` and `trainer_options.run_extra`: use an
order-preserving parser (the app uses `JSONValue(parsing:)`).

### Trainer settings

Some recipe values are defaults a person can change for one run: `recipe.caption_dropout`,
`architecture.gradient_checkpointing`, `recipe.optimizer`, `recipe.lr_scheduler` and
`recipe.lr_warmup_steps`. Advanced
shows them for AI Toolkit rows without a `trainer_config` hook (such a hook builds the whole recipe,
as H3's does, and the row's values only describe it). The app sends a value in run.json only when
it differs from the row's (POD-SPEC 4.1); an absent value means the row's, so Repeat takes the
row's current default for a setting the repeated run left alone.

### Training length

A row in `epochs` shows passes over each image and clip, and the app sends
`steps = ceil(epochs × buckets × ceil(items / batch_size) / gradient_accumulation)`, where `items`
is the number of included training images and clips and `buckets` the number of chosen resolution
buckets on AI Toolkit (1 on LTX): AI Toolkit splits a dataset into one copy per bucket and fills
each copy's last batch on its own, so a pass is `ceil(items / batch_size)` batches at every chosen
size. run.json always carries `steps`; Resume and saved runs work on steps, and Repeat turns them
back into epochs with the repeated run's own item and bucket counts.

## Lookup rules

- **Exact row**: the row whose `model_ref` equals `base_model` (case-sensitive) on the given
  trainer. Hooks, generation, GPU verification and project-profile following use it.
- **Effective row**: the exact row, else the row `trainers[trainer].default_model` names. Defaults
  and capabilities use it, so a custom base model behaves like the trainer's default model.
- **Family match** (pod, AI Toolkit `model` block only): without an exact row, the first row in
  table order whose `family_match` matches the lowercased `base_model`, so custom paths such as
  `/workspace/models/MiniMax-H3` still get the right `arch`. It supplies the `model` block and
  nothing else.

## Hooks

A hook is a named strategy for one concern. The row names it; the app (`ModelHooks`) and the pod
(`model_table.HOOKS`) each register the names they know, and a name that is not registered is an
error.

| Concern | Name | What it does |
| --- | --- | --- |
| `trainer_config` | `minimax_h3` | The pod builds H3's whole AI Toolkit config (quality recipe, dataset groups, initialization, guidance check) instead of the generic mapping, and fetches its pinned assets before launch. |
| `native_recipe` | `minimax_h3` | The app imports a native AI Toolkit recipe and warm-starts a new run from LoRA weights; the guidance rules go with it. The agent admits external initialization only for such a row. |
| `generator` | `aitoolkit_image` | Comparison stills through AI Toolkit's `StableDiffusion` class, with the row's model settings (FLUX). |
| `generator` | `aitoolkit_arch_image` | Comparison stills from the model class AI Toolkit registers for the row's `arch`, with the trained LoRA bound as a network; for architectures that are their own class (Z-Image, Qwen-Image-2.1). Needs the source run's saved `native-config.json`. |
| `generator` | `ltx_one_stage` | LTX's official one-stage CLI. |
| `generator` | `minimax_h3` | H3's registered model with the trained network recipe. Needs the source run's saved `native-config.json`. |
| `generator` | `musubi_krea2_image` | Comparison stills through musubi-tuner's own Krea 2 inference (`krea2_generate_image.py`) on the DiT `trainer_options.generate.dit` names, with the trained LoRA merged at load on the trained side. |
| `run_extra` | `ltx_video_buckets` | When the inputs contain video, the app sets `preprocess` to `{"buckets_from_media": true, "args": ...}`. |

A row without a `generator` hook does not support comparison generation.

## Regularisation and REPA fields

Each row declares its regularisation support; REPA remains an optional AI Toolkit field. The app
copies enabled settings into run.json, so saved runs keep their explicit settings when the table changes.
The pod reads the same row to admit generated or supplied class-image sets.

### `regularization`

A regularisation (prior-preservation) set trained beside the subject: ordinary pictures of the
subject's class ("a person"), drawn by the base model before training from the subject's own
captions with the trigger taken out. The LoRA then learns that the trigger means one subject while
the class noun keeps meaning any member of the class.

The pod draws the set (`draw-regularization`), the app fetches the pictures and has the project's
own captioner (the same provider, model and endpoint) describe each one, and the run starts with
those captions. The captioner is told only the class nouns, with the skill's
`references/regularization.md`; it never sees a trigger.

```json
"regularization": {
  "mode": "generate",
  "default_on": true,
  "images": 40,
  "weight": 1.0,
  "generation": {"steps": 40, "guidance_scale": 3.0, "seconds_per_image": 33},
  "note": "For maintainers."
}
```

| Field | Meaning |
| --- | --- |
| `mode` | `generate`: offered, including your own images; `folder`: own images only; `unsupported`: not possible with this pinned trainer. Advanced displays the reason. |
| `default_on` | Whether a new run starts with regularisation on when this model is selected. Generated sets default on; supplied sets start when a folder is chosen. |
| `images` | Default number of generated images; editable. `null` for supplied-only or unsupported rows. |
| `weight` | Default `train.reg_weight`: how much a regularisation image counts against one of the subject's. |
| `generation.steps`, `guidance_scale` | Sampling settings for the generated images. |
| `generation.seconds_per_image` | Time per image at the row's largest default resolution, for the estimate the app shows; the app scales it by the area of the largest chosen bucket. Display only. |
| `note` | Support explanation shown in Advanced. |

Generated sets require a registered `generator` hook. `generate_results.render_base` loads the
row's base model without a LoRA. H3 uses the pinned BF16 asset paths from its native recipe and
omits the training adapter. Its 16-image default produces stills even for a video training run;
clip captions also supply class prompts. Generation-time figures are planning estimates, not
benchmarks. Existing cached images are reused.

**Use my own regularisation images** in Advanced accepts a local class-image folder. The app
normalises the images through its standard importer, captions them with the project's provider,
model and endpoint, and uploads only usable images with their new captions. For a video profile,
class stills use that model's image caption profile. The source folder and existing captions are
preserved. A repeated run can reuse its captioned folder on retained cloud storage.

run.json carries a top-level `regularization` object: `source: "generate"` with `images`, `weight`,
`class_nouns` (trigger to class noun), `generation` (`steps`, `guidance_scale`, `seed`) and
`captions` (picture key to caption, written by the app), or `source: "folder"` with `path` (a
folder under `datasets/`) and `weight`. The launcher writes `train.reg_weight` and appends an
`is_reg: true` dataset **after** the final custom or generic configuration is built. The class dataset
keeps matching caption/cache settings and uses `num_frames: 1`, `do_audio: false`, including when
H3's subject datasets contain clips. AI Toolkit alternates class and subject batches (save/sample
steps keep subject batches), so the app doubles the steps computed for an `epochs` row.
Generated images are cached under `<workspace>/regsets`; each run keeps its own captioned copy.

### Regularisation coverage

Surveyed against the shipped trainer pins on 2026-10-22. **Offered** rows enable generation by
default and also accept supplied images. **Own images only** rows use AI Toolkit's weighted class
loss without requiring a new generation integration. These capabilities do not change a row's
separate training-recipe verification status.

AI Toolkit's [dataset classification and alternating loader](https://github.com/ostris/ai-toolkit/blob/f7a1fb9a77e5418269b1e9eda4ace6d7c1b7bb47/jobs/process/BaseSDTrainProcess.py)
and [reg_weight configuration](https://github.com/ostris/ai-toolkit/blob/f7a1fb9a77e5418269b1e9eda4ace6d7c1b7bb47/toolkit/config_modules.py)
provide the dedicated prior-preservation path. The pinned
[musubi dataset schema](https://github.com/kohya-ss/musubi-tuner/blob/30c658c4f4b0bf05038b3346eff9670259b10fc7/src/musubi_tuner/dataset/config_utils.py)
and [training loss](https://github.com/kohya-ss/musubi-tuner/blob/30c658c4f4b0bf05038b3346eff9670259b10fc7/src/musubi_tuner/training/trainer_base.py)
provide ordinary datasets/repeats and flow-matching loss, with no separate class-loss weight.
The pinned [LTX trainer](https://github.com/Lightricks/LTX-2/blob/be6d6d0a69d11a0a399c462ed92606692e5f8697/packages/ltx-trainer/src/ltx_trainer/trainer.py)
loads one precomputed dataset and averages its loss, without a separate class/prior branch.
Mixing class examples into either ordinary dataset is different from this dedicated weighted
prior-preservation mode. “Not possible” below describes those pins, not an inherent model limitation.

| Model row | Trainer | Regularisation | Default / reason |
| --- | --- | --- | --- |
| `flux1-dev` | aitoolkit | offered | On; 40 stills, 28 generation steps, weight 1. |
| `ltx-2.3` | ltx | not possible | Pinned trainer has no separate class/prior-preservation loss or class-loss weight. |
| `ltx-2.5` | ltx | not possible | Pinned trainer has no separate class/prior-preservation loss or class-loss weight. |
| `minimax-h3` | aitoolkit | offered | On; 16 stills, 28 generation steps, weight 1. Reuse stills for image or video training. |
| `z-image` | aitoolkit | offered | On; 40 stills, 28 generation steps, weight 1. |
| `qwen-image-2.1` | aitoolkit | offered | On; 40 stills, 40 generation steps, weight 1. |
| `anima` | aitoolkit | own images only | Native AI Toolkit class loss; automatic generation is not connected for this row. |
| `chroma` | aitoolkit | own images only | Native AI Toolkit class loss; automatic generation is not connected for this row. |
| `lumina2` | aitoolkit | own images only | Native AI Toolkit class loss; automatic generation is not connected for this row. |
| `ming-image` | aitoolkit | own images only | Native AI Toolkit class loss; automatic generation is not connected for this row. |
| `sdxl` | aitoolkit | own images only | Native AI Toolkit class loss; automatic generation is not connected for this row. |
| `omnigen2` | aitoolkit | own images only | Native AI Toolkit class loss; automatic generation is not connected for this row. |
| `flux2` | aitoolkit | own images only | Native AI Toolkit class loss; automatic generation is not connected for this row. |
| `zimage-turbo` | aitoolkit | own images only | Native AI Toolkit class loss; automatic generation is not connected for this row. |
| `zimage-deturbo` | aitoolkit | own images only | Native AI Toolkit class loss; automatic generation is not connected for this row. |
| `flux2-klein-4b` | aitoolkit | own images only | Native AI Toolkit class loss; automatic generation is not connected for this row. |
| `ernie-image` | aitoolkit | own images only | Native AI Toolkit class loss; automatic generation is not connected for this row. |
| `flux2-klein-9b` | aitoolkit | own images only | Native AI Toolkit class loss; automatic generation is not connected for this row. |
| `nucleus-image` | aitoolkit | own images only | Native AI Toolkit class loss; automatic generation is not connected for this row. |
| `hidream-o1` | aitoolkit | own images only | Native AI Toolkit class loss; automatic generation is not connected for this row. |
| `prx-pixel` | aitoolkit | own images only | Native AI Toolkit class loss; automatic generation is not connected for this row. |
| `iris3b` | aitoolkit | own images only | Native AI Toolkit class loss; automatic generation is not connected for this row. |
| `krea2` | musubi | not possible | Pinned trainer has no separate class/prior-preservation loss or class-loss weight. |
| `boogu-image` | aitoolkit | own images only | Native AI Toolkit class loss; automatic generation is not connected for this row. |
| `flex2` | aitoolkit | own images only | Native AI Toolkit class loss; automatic generation is not connected for this row. |

### `repa`

Representation alignment (REPA; Yu et al., ICLR 2025): an auxiliary loss that aligns one
transformer block's image tokens with a frozen vision encoder's patch features. The AI Toolkit
image carries it as a patch series on top of its pin (`pod/images/patches/ai-toolkit/`).

```json
"repa": {
  "default_on": false,
  "encoder": "facebook/dinov2-giant",
  "encoder_download_gb": 4.4,
  "block_index": 8,
  "weight": 0.5,
  "projector": "mlp",
  "projector_dim": 2048,
  "encoder_resolution": 518,
  "note": "For maintainers."
}
```

| Field | Meaning |
| --- | --- |
| `default_on` | Whether a new run starts with REPA on. |
| `encoder` | The frozen vision encoder. The trainer downloads it into the model cache on the first run. |
| `encoder_download_gb` | Size of that download, for the sentence the app shows. Display only. |
| `block_index` | 0-indexed block whose output is aligned. |
| `weight` | Weight of the alignment term. |
| `projector`, `projector_dim` | The projector trained beside the LoRA and discarded (it is not part of the LoRA), and its hidden width. |
| `encoder_resolution` | The pixel side the encoder is run at. |
| `note` | Free text for maintainers. Not displayed. |

The row's `architecture.arch` must be one the patch series wires (`qwen_image_2`, `zimage`;
`ModelRow.repaArchitectures` in the app). The app copies the six values after `default_on` into
run.json's top-level `repa`, and the launcher writes them as AI Toolkit's `process.repa` block
before `extra` merges (`extra.repa.enabled: false` turns it off).

## musubi rows

A musubi row trains with kohya-ss musubi-tuner (`pod/images/Dockerfile.musubi`); `launch_musubi.py`
reads its `trainer_options`:

| Field | Meaning |
| --- | --- |
| `weights.<role>` | `{repo, revision, file}` per weight file, each from a pinned Hub revision into `<workspace>/models/huggingface/<repo>/`. Roles: `dit` (trained), `vae`, `text_encoder`, and `sample_dit` (the model training samples are drawn on, fetched only when the run samples). |
| `args` | musubi-tuner training flags in order (`true` passes a switch). run.json `extra.args` merges over them; the flags the wrapper owns (`musubi_rules.WRAPPER_ARGS`: weights, dataset, output, logging, length, saving, sampling, Resume) cannot be set there. |
| `sample` | `steps` and `cfg` for each sample prompt line, and `args` added only when the run samples. |
| `generate` | For the row's `generator` hook: `dit`, the weight role comparisons render on, and `args`, generation settings the inference script takes beyond the request's size, steps and guidance (Krea 2 Turbo's fixed `mu`). |

`recipe.optimizer` and `recipe.lr_scheduler` become `--optimizer_type` and `--lr_scheduler` unless
`extra.args` sets them. `recipe.caption_dropout` is `null` (musubi-tuner has none) and
`recipe.checkpoints.editable` is `false`: the run saves every `save_every` steps and keeps
`checkpoints.keep` of them (0 keeps all). There is no custom base model on this trainer: `base_model`
must be a musubi row's `model_ref`.

## Adding a model

1. **Check the trainer pin.** For AI Toolkit the `arch` must exist at `AI_TOOLKIT_COMMIT` in
   `pod/images/Dockerfile.aitoolkit`.
2. **Write the row.** Append it to `models` (order is picker order). Fill it from a training
   config that works: `architecture`, `resolution` and `recipe`; `gpu.min_vram_gb` and
   `gpu.note`; `source.first_download_gb` from the Hub file sizes; `license` from the model page,
   with `show_notice` true when users should read it before training.
3. **Choose caption profiles.** Reuse an existing profile when the model reads the same prose, or
   add a profile file to the bundled caption skill (the Python package and the app both carry
   it) and name it in `captions`. Give a `profile_prefix` only when projects should select the
   model from their profile.
4. **Comparison.** `aitoolkit_image` builds AI Toolkit's legacy `StableDiffusion` class, which
   serves only the legacy architectures (`LEGACY_ARCHS` in `toolkit/util/get_model.py`; FLUX is
   one). Newer architectures load through `get_model_class` and use `aitoolkit_arch_image`. Leave
   `generator` out, and `preview` off, for a model whose comparison has not been shown to work;
   it still trains.
5. **Hooks only for behaviour data cannot express.** Add the name to both registries and to the
   table above. A value that can be data is an optional row field instead
   (`trainer_options.process` is one for AI Toolkit `process` keys).
6. **Rebuild the pod images** so they carry the new row, and try the model through the app on a
   rented pod.

## Advanced user recipes

`recipe_status` is `verified` for recipes measured end to end (Krea 2 on musubi-tuner among them)
and `unverified` for recipes copied from AI Toolkit's pinned UI. The app offers unverified rows only while Settings → Advanced user
is on. Turning it off retains the selected model and all edited values; each affected screen
reports the overrides still in force. `training_notice` is an optional visible sentence about
the upstream issue check. An unverified recipe is not a measured training or quality result.

Unverified rows use per-architecture defaults from the `ui.tsx` registrations at
`AI_TOOLKIT_COMMIT`, layered over `ui/src/app/jobs/new/jobConfig.ts`. `trainer_options.dataset`
contains dataset defaults; the launcher merges them into each runtime dataset without replacing
its path or chosen resolutions. `trainer_options.process` supplies the remaining native defaults;
explicit run settings still win. Samples and comparison stay unavailable until verified.

Their download size is the Hub repository file-size total (including alternate formats), not a
measured first download. Model-specific dependencies can add files. GPU floors are conservative
allocations, not evidence that the recipe fits; the pod checks its actual memory before upload.

New rows require rebuilding the pod image before they can train. This change does not rebuild
or publish images and does not run rented-GPU smoke tests.

Models a strictly better successor has replaced get no row (owner decision, 2026-10-14):
Qwen-Image and Qwen-Image-2512 (Qwen-Image-2.1), Qwen-Image-Edit, -2509 and -2511, Wan 2.1,
HiDream-I1 (HiDream-O1) and Flex.1 (Flex.2).
