# images

Current release: `ghcr.io/rationallyprime/concept-captioner-pod-{base,aitoolkit,ltx,musubi}:v0.3.10-20261022`
and the trainers’ `-captioning` tags. Built on cx53 from an exact archive of commit `6589efb`,
including the workspace storage-accounting fix, expanded regularisation, training masks and
augmentation, style report scoring, and the shared-PyTorch SeedVR2 environment. All seven tags
are published and resolve anonymously. The [machine-readable release receipt](releases/v0.3.10-20261022.json)
records the full source commit, digests, sizes and control checks.

| tag | index digest | compressed download |
| --- | --- | --- |
| `base:v0.3.10-20261022` | `sha256:988da89c82a16fa80bbcf160a260b85ff2d3c5468f074275d16fd378e2bfa390` | 3.56 GB |
| `aitoolkit:v0.3.10-20261022` | `sha256:aafc08df6cad122b0c1dcd3f7d4edd665e85543d5a85da8e07ba4d50fe357dbb` | 7.42 GB |
| `ltx:v0.3.10-20261022` | `sha256:9fd661ef91ff2e2139b40a4cea2189948dfd901c0663b325176c25bde5d4a08d` | 7.16 GB |
| `musubi:v0.3.10-20261022` | `sha256:a61a77db140a448513b770b7f3ed2b14c489df21ea660304bba124f5376b425f` | 6.61 GB |
| `aitoolkit:v0.3.10-20261022-captioning` | `sha256:92b63d54272a9f5179d79c9cebfcb6437d80aef44eeadb94845186f1747169e0` | 14.36 GB |
| `ltx:v0.3.10-20261022-captioning` | `sha256:1b962a4ebac7142f8eb8f67becb1cdea57488d641a6cb66f316b796bcac00bb1` | 14.10 GB |
| `musubi:v0.3.10-20261022-captioning` | `sha256:9e51ba9964fdf9e28de564e249fa19d7269fc87cb50e25816433a4eac1eeb9f4` | 13.55 GB |

SeedVR2’s layer shrank from **2.96 GB to 202 MB**: a **93% reduction**, saving about **2.76 GB
on every image**. Its small dependencies remain isolated, while PyTorch, torchvision, Triton
and CUDA libraries come from the selected trainer through package symlinks. AI Toolkit and musubi
supply PyTorch 2.13.0+cu130; LTX supplies 2.13.0+cu132. Model weights download and pass SHA-256
validation on first Upscale. Environment installation is completed in the image build.

The captioning variants share one 6.94 GB vLLM layer (`sha256:7ece648aeae9…`). Each trainer build
passed SeedVR2 imports and CLI help with its shared GPU stack. All seven image control checks
passed bearer authentication, workspace-scoped storage accounting, and the expected availability
of SeedVR2 and vLLM. Every captioning build validated all 23 allowed vLLM flags.

### Live SeedVR2 acceptance

The test inputs are the bundled synthetic portrait resized to 512×512 and a 21-frame, 24 fps
pan/zoom clip with a tone. Both are upscaled to 1024×1024 with SeedVR2 3B FP16, seed 42. The first
image pass includes the empty-cache model download and SHA-256 checks. The 32 GB pass uses
VAE encode/decode tiling; the 96 GB pass runs untiled. Both use CPU component offload and no
BlockSwap. Times below are the SeedVR2 CLI’s measured elapsed times; peak memory covers the
complete image-and-clip run.

| GPU | first image, including weights | clip, cached weights | peak GPU memory |
| --- | --- | --- | --- |
| RTX PRO 4500 Blackwell, 32 GB | 51.88 s | 25.86 s | 22,934 MiB |
| RTX PRO 6000 Blackwell, 96 GB | 42.21 s | 15.19 s | 23,299 MiB |

Both GPUs’ outputs passed dimensions, all 21 frames, 24 fps and video-duration checks. Each clip
retains the original tone through the wrapper’s AAC encoding (waveform cosine above 0.99999; audio
padding within one AAC frame). Both images and a frame from each clip were visually inspected.
Outputs were downloaded and hash-checked. The 96 GB pod then completed H3 regularisation and
report acceptance on the same image: 16 generated and captioned class images, six training
steps, a saved checkpoint, four matched renders, prompt-adherence judgments and actual VGG19
style scores. Both test pods were stopped and removed after their outputs were secured.
Full runtime receipts, captioning and H3 acceptance are in [POD-STATUS](../docs/POD-STATUS.md).

## Earlier releases

These entries preserve the build and acceptance records at each release date. Current measurements
are recorded above and in [POD-STATUS](../docs/POD-STATUS.md).

Previous release: `ghcr.io/rationallyprime/concept-captioner-pod-{base,aitoolkit,ltx,musubi}:v0.3.9-20261022`
and the trainers' `-captioning` tags, a **clean build from commit `21247aa`** (PR #31 and PR #29): the base
gains SeedVR2 upscaling and restoration, the numz/ComfyUI-SeedVR2_VideoUpscaler v2.5.23 command line at
`/opt/seedvr2` with its own venv `/opt/venvs/seedvr2` (torch 2.9.1+cu130, diffusers 0.36.0), behind the
agent's new `upscale-media` service for the SeedVR2 3B and 7B models; and the app refuses gated models
when no Hugging Face token is set. Built on cx53 with `docker buildx build` from the committed Dockerfiles
and no overlay, pushed 2026-10-22. Every tag resolves anonymously.

| tag | index digest | compressed download |
| --- | --- | --- |
| `base:v0.3.9-20261022` | `sha256:1c2379a8e866dcccfb8d41db9ab5d73c072f009d65664384726e3aad95937328` | 6.32 GB |
| `aitoolkit:v0.3.9-20261022` | `sha256:d0085a4ef3744d093073a1ebd914943306bd67e3036063c64c87f09f865da5fa` | 10.17 GB |
| `ltx:v0.3.9-20261022` | `sha256:182edbb4de5fd33851d6695dc7af9540271b7737593203c38ed3fe09446495b0` | 9.92 GB |
| `musubi:v0.3.9-20261022` | `sha256:143081fda83ac0dd829644d61a931821c4a92c96e1d1a496f0e1ce5af70c195b` | 9.36 GB |
| `aitoolkit:v0.3.9-20261022-captioning` | `sha256:e138addb19b359a97ccc8e587b79a2225538d9d8657c79c9a667f5c3c664aca2` | 17.11 GB |
| `ltx:v0.3.9-20261022-captioning` | `sha256:00460fb653d9fdbbc5de53b374875ca67c55931e9346b32f69f5cd40f20ba063` | 16.86 GB |
| `musubi:v0.3.9-20261022-captioning` | `sha256:333b4c7bc459095e5b92da396520b00be452cf0b28cb6a9073b03ca7fa3fd20c` | 16.30 GB |

The SeedVR2 layer (`sha256:690803ed1090…`) is 2.96 GB compressed and 5.0 GB unpacked; every tag carries it
through the base, so each download is that much larger than its `v0.3.8` counterpart. The vLLM layer
(`sha256:11b265ae92f4…`, 6.94 GB compressed) is again one blob shared by the three `-captioning` tags. Build
checks: the SeedVR2 checkout at `5a4bf42`, its import check (torch 2.9.1+cu130, diffusers 0.36.0, cv2
4.11.0) and `inference_cli.py --help`; vLLM 0.31.0+cu129 with torch 2.13.0+cu129 and FlashInfer
0.7.0.post1, and the flag allowlist (23 flags) in each variant. A CPU smoke on cx53 ran the agent in both
musubi tags without fake GPUs: both answer 401 without the bearer and report `upscale-media` available
(`/opt/venvs/seedvr2/bin/python inference_cli.py --help` also ran inside each); the slim tag reports `vllm`
unavailable and the variant reports it available. No GPU run has used this tag yet; the SeedVR2 image and
clip passes are still open (POD-STATUS).

The previous release, `ghcr.io/rationallyprime/concept-captioner-pod-{base,aitoolkit,ltx,musubi}:v0.3.8-20261021`
and the trainers' `-captioning` tags, a **clean build from commit `fd40c60`**: H3 trains on a chosen frozen
adapter (Circlestone's image adapter or Ostris's v3, `model.training_adapter`), stills default to
Circlestone and runs with clips to Ostris; H3 stills train without gradient checkpointing; `push-lora`
no longer uploads H3's `h3-inputs/` caches. Built on cx53 with `docker build` from the committed
Dockerfiles and no overlay, pushed 2026-10-21. Every tag resolves anonymously.

| tag | index digest | compressed download |
| --- | --- | --- |
| `base:v0.3.8-20261021` | `sha256:5019d59053d7845b54f4b9598eae71f6e2f9f083d67004b8e92a3d9700adf8e7` | 3.35 GB |
| `aitoolkit:v0.3.8-20261021` | `sha256:875a6da7fd5ac7e6bb8c0745fbc59762c86cab9c886b759f74be4b8f03acf2ab` | 7.21 GB |
| `ltx:v0.3.8-20261021` | `sha256:1966f5064b315d9e64674fb312e5133a1360432965c81b775f6a8460635c1c5c` | 6.96 GB |
| `musubi:v0.3.8-20261021` | `sha256:7e524339cc3220e6cac92cfae96d67dacd4b6d81875992c81548b9e24b2e42a6` | 6.40 GB |
| `aitoolkit:v0.3.8-20261021-captioning` | `sha256:adcd03233aa31f5f6241b74b1a848c1cd23749172e4c08a1e3139e9e41c8750b` | 14.15 GB |
| `ltx:v0.3.8-20261021-captioning` | `sha256:bb0984329be40c095df693e76cdc86fee8c965ccf32fc654ac376094e7c85ef7` | 13.90 GB |
| `musubi:v0.3.8-20261021-captioning` | `sha256:16f12e84367f3d17c13556decc76af79d885ffef291c82e17ac44873113e3642` | 13.34 GB |

An A/B of the two adapters on one 33-photo still set (same recipe, seed and steps) found likeness level
(ArcFace about 0.37 for both at step 2100), less bleed into a no-trigger prompt and more photographic
renders on Circlestone's, and about 20% faster steps on Ostris's; hence the stills default. The
`v0.3.7-20261021` tags are a test build from `a0e0fa7` that predates the `push-lora` fix; that A/B ran on
it, and no GPU run has used `v0.3.8` yet.

The previous release, `ghcr.io/rationallyprime/concept-captioner-pod-{base,aitoolkit,ltx,musubi}:v0.3.6-20261019`
and the trainers' `-captioning` tags, a **clean build from commit `2eb68e1`**: vLLM moves out of the
base into `Dockerfile.captioning`, which adds it on top of each finished trainer image; the musubi
comparison generator (`generate-musubi`), the 1600-step Krea 2 recipe and the agent's
`available` / `409 unavailable` report are in it. Built on cx53 with `docker build` from the
committed Dockerfiles and no overlay, pushed 2026-10-19. Every tag resolves anonymously.

| tag | index digest | compressed download |
| --- | --- | --- |
| `base:v0.3.6-20261019` | `sha256:e94b3863fc52e6c1213b65d998c5def3ea113b34857f34bdde48c17120d1eaad` | 3.35 GB |
| `aitoolkit:v0.3.6-20261019` | `sha256:ff19fea081414ba46d6e83d2bde5298797498d40a27696c9f1dd77a5c4558245` | 7.21 GB |
| `ltx:v0.3.6-20261019` | `sha256:dea1ff19a677ae3240f94dfd02176c73a7e97c7aee2c89e3cbd56b034f433038` | 6.96 GB |
| `musubi:v0.3.6-20261019` | `sha256:04e1ff6183d22d0e53adc81d0d698cd759ab478bf59ff565d9a9dac7c7dd7035` | 6.40 GB |
| `aitoolkit:v0.3.6-20261019-captioning` | `sha256:b232b3c7ebfa5499e7f285afd344f0d66df4b89e787b9441a3ffa59de31b3a5c` | 14.15 GB |
| `ltx:v0.3.6-20261019-captioning` | `sha256:a5e10eef7e29566feb677946bab0b103c7d22b800e8944b2aa8506ace468b76a` | 13.90 GB |
| `musubi:v0.3.6-20261019-captioning` | `sha256:c3f3dcd0b64ec3379de2dedf7c8633fdd71fe5ba332e664eeb397ec479beda6b` | 13.34 GB |

Each trainer image is about half its v0.3.5 download (aitoolkit 14.15, ltx 13.90, musubi 13.34 GB
then). The vLLM layer (`sha256:1fa02f6f6039…`, 6.9 GB compressed) is the same blob in all three
`-captioning` tags, so the registry holds it once and a variant costs only that layer plus a few
small ones over its slim tag. Build checks: vLLM 0.31.0+cu129 with torch 2.13.0+cu129 and
FlashInfer 0.7.0.post1, and the flag allowlist (23 flags) in each variant; musubi-tuner 0.3.4 at
`30c658c` with its `krea2_*` entrypoints. A CPU smoke on cx53 ran both musubi tags: the slim one
reports `vllm` unavailable and answers a start with `409 unavailable`, the variant reports it
available; both answer 401 without the bearer. No GPU run has used this tag yet.

The previous release, `ghcr.io/rationallyprime/concept-captioner-pod-{base,aitoolkit,ltx,musubi}:v0.3.5-20261019`,
a **clean build from commit `c058bdf`** (the musubi-tuner trainer: `Dockerfile.musubi` at musubi-tuner
`30c658c` / v0.3.4, `launch_musubi.py`, `musubi_rules.py`, and the agent's `trainer-musubi`), the four
Dockerfiles as committed, built on cx53 with `docker buildx build` and no overlay, pushed 2026-10-19.
Digests: base `sha256:d2556d465a6e7684463811e1c198d8bb2c9cd4748c2f648732f496ceda32cfa0`,
aitoolkit `sha256:a5eebe9ddb27ab06908dadecd390a7df2b130c810f77201e850912544daa6487`,
ltx `sha256:27f65abc079704c8d80c964ebbe2f460e83e05bc425434eb734dbeb44faf0c55`,
musubi `sha256:8dfe1cded038b78b68bdbfa3ce01b43ece90d06c9a8afe0cd923baf17d1a42d0`. Base, aitoolkit and
ltx resolve anonymously; the musubi package was created private by GHCR and resolves anonymously once
its visibility is set to public. The musubi stage printed musubi-tuner 0.3.4, torch 2.13.0+cu130,
accelerate 1.6.0, huggingface_hub 0.34.3 and TensorBoard 2.21.0, and its build check found the three
`krea2_*` entrypoints `launch_musubi.py` computes. A dry run inside the musubi image wrote the dataset
files and a trainer command whose 30 flags all appear in the pinned `krea2_train_network.py --help` or
accelerate's launcher. No GPU run has used this tag yet.

The previous release, `ghcr.io/rationallyprime/concept-captioner-pod-{base,aitoolkit,ltx}:v0.3.4-20261015`,
a **clean build from commit `1adc7c8`** (PR #21: LTX-2.3 and LTX-2.5 Hub sources, the LTX trainer at `be6d6d0`, and
PRs #19/#20's trainer settings and log push): the three Dockerfiles as committed, built on cx53 with
`docker buildx build` and no overlay, pushed 2026-10-15. Digests: base `sha256:3226b5eefa6b7a5edb18564b746ec479694546071ef188757f7a3c343b29e2e9`,
aitoolkit `sha256:76873ce8d9fd921bf0a58aa20d4872223c076c69d3ef89422e1d561bfb14e147`,
ltx `sha256:fda47e2743d7a11238c2f4dea89ba7c4c46799f9bde587da5b19c3b20a781c4b`; each resolves anonymously.
The LTX stage resolved ltx-trainer 1.4.2, ltx-core 1.4.2, torch 2.13.0+cu132 and natten 0.21.7.
The previous releases stay published: `v0.3.3-20261014` (from `126eb67`; base `bfcb30c7…`, aitoolkit `24793dec…`, ltx `4aeb4e3b…`), `v0.3.2-20261014` (from `374e695`; base `3a809cae…`, aitoolkit `73266718…`,
ltx `5bf0ef9e…`), `v0.3.1-20261014` (from `0124582`; base `0483ff50…`, aitoolkit `3bc32673…`,
ltx `e568b43b…`), `v0.3.0-20261014` (from `f784947`,
PR #10; base `eab5ddb9…`, aitoolkit `afe466d1…`, ltx `41a74204…`) and `v0.2.3-clean-20261011` (from `b7908618`;
base `d41b8287…`, aitoolkit `fe09109d…`, ltx `40a0361f…`). The images carry no OCI revision label; this table is the record of
which commit they came from.

| image suffix | public manifest digest |
| --- | --- |
| `base` | `sha256:bfcb30c7f768a57fa9bfd1d36eab8742cecb1634d6b0352d9c9f5a3708fb402d` |
| `aitoolkit` | `sha256:24793dec0c0b6aa11bd9f39c258d98c8aeb17fe25d0fdfd5c5e5757342ebc14c` |
| `ltx` | `sha256:4aeb4e3b50af518f025b1df2a980136674a3de14db8d0a98168e14b282350789` |

Checked after the push: each tag resolves anonymously on GHCR to the digest above. The CPU
control smoke described next has not been rerun for this tag; it ran against the pushed `v0.2.3` base image and passed (receipt
`cx53:~/work/cc-clean3-logs/smoke.out`). The paragraph below records the same checks for
`v0.2.2`, including its anonymous pulls by digest. The base build ran
`check_vllm_flags.py` (23 flags found, build passed). The CPU control smoke ran against the
pushed base image: authentication (401 without the bearer), service catalog,
TensorBoard session and its cookie scope, run files with a range read, and planning with two
fake GPUs all passed. The LTX image has TensorBoard 2.21.0, LTX-2 at `9ec55f9f` and
`LTX_HUB_REVISION` `dfcc2108383fe1aaa0584bdf55d368a4bdadd90c`. No real-pod run has used these
images yet; that is the owner's training run. Receipts are on cx53 under
`/home/hive/work/cc-clean2-logs` (the `v0.2.1-clean-20261011` receipts stay under `cc-clean-logs`). Docker is not installed on the Mac; this x86 build host
produces the images.

The previous release, `v0.2.0-overnight20261011-r2` (base `sha256:65e6b5ec…7551e`, aitoolkit
`sha256:e7a84abe…31337`, ltx `sha256:e236160a…1ba66`), stays published and is what every real-pod
run so far used. It was not a clean build: runtime images were built from `017d79f`, and two
source files (the constant-frame-rate gate from `b1d0bef` and the selected-checkpoint custody
repair from `98708207`) were overlaid by exact source hashes onto those layers. The overlay
recipes were never committed. Current actual CUDA checks and historical tiny trainer receipts
are distinguished in [POD-STATUS](../docs/POD-STATUS.md).

| file | purpose |
| --- | --- |
| `Dockerfile.base` | CUDA 12.8 runtime + CPython 3.12 + uv; `/opt/venvs/agent` (podagent[pod], concept-captioner[hf], tensorboard, huggingface_hub, datasets, Pillow); `/opt/pod/scripts/*.py` plus `model-table.json` (the model table), `ltx_rules.py` and `musubi_rules.py`; entrypoint. No vLLM |
| `Dockerfile.captioning` | a finished trainer image + `/opt/venvs/vllm` (vLLM and its torch, built once in a stage on the base and copied with `COPY --link`), tagged `<tag>-captioning`. The build fails if a flag in the agent's vLLM allowlist is absent from the installed vLLM (`check_vllm_flags.py`) |
| `Dockerfile.aitoolkit` | base + `ostris/ai-toolkit` at a pinned commit in `/opt/ai-toolkit` with the local patch series applied on top (`git am`; `patches/ai-toolkit/`), venv `/opt/venvs/aitoolkit` with upstream's own torch/flash-attn/NATTEN stack. The build fails if a patch does not apply |
| `Dockerfile.ltx` | base + `Lightricks/LTX-2` at a pinned commit in `/opt/ltx-2` (uv workspace), venv `/opt/venvs/ltx` plus TensorBoard 2.21.0 (pinned, with an event write/read check) |
| `Dockerfile.fake` | `python:3.12-slim` + podagent only, for `compose.fake.yaml` (no CUDA, no trainers) |
| `entrypoint.sh` | creates `/workspace/{datasets,runs,models/hf-cache,logs}`, exports `HF_HOME`, execs `tini -s -- python -m podagent --host 0.0.0.0 --port 8800`; nothing else |
| `compose.fake.yaml` | local fake-GPU agent: `PODAGENT_FAKE_GPUS=2`, `PODAGENT_FAKE_HOST=0.0.0.0`, bind mount `./workspace:/workspace`, ports 8800 (agent), 8000 (fake vLLM); fake TensorBoard stays on loopback |

## Layout inside an image

```
/opt/python/cpython-3.12.14-…/      one managed interpreter, shared by every venv
/opt/venvs/agent/                   podagent + concept-captioner; no torch       (freeze.txt = what landed)
/opt/venvs/seedvr2/                 SeedVR2's small dependencies; symlinks share the trainer's PyTorch/CUDA
/opt/seedvr2/                       numz/ComfyUI-SeedVR2_VideoUpscaler v2.5.23 checkout (its inference_cli.py)
/opt/venvs/vllm/                    vllm 0.31.0+cu129, torch 2.13.0+cu129       (-captioning tags only; freeze.txt)
/opt/venvs/aitoolkit/               ai-toolkit stack, torch 2.13.0+cu130        (aitoolkit image; freeze.txt)
/opt/venvs/ltx/                     LTX-2 workspace, torch 2.13.0+cu132         (ltx image; freeze.txt)
/opt/venvs/musubi/                  musubi-tuner v0.3.4, torch 2.13.0+cu130     (musubi image; freeze.txt)
/opt/ai-toolkit/  /opt/ltx-2/  /opt/musubi-tuner/  the trainers' checkouts (ltx-2 also holds the uv.lock the build resolved; ai-toolkit's git log lists the patch series on top of the pin)
/opt/ai-toolkit-patches/            the patch series the aitoolkit image applied (record only)
/opt/src/{concept-captioner,podagent}  the sources the agent venv was installed from (record only)
/opt/pod/scripts/*.py               pull_dataset.py, push_lora.py, launch_aitoolkit.py, launch_ltx.py, launch_musubi.py, generate_results.py, model_table.py
/opt/pod/scripts/model-table.json    the model table (copied from app/Sources/ConceptStudio/Resources/Training/)
/opt/pod/entrypoint.sh
/workspace                          the network volume (POD-SPEC §6.4); nothing of value lives elsewhere
```

Separate venvs per workload so vLLM's and each trainer's torch never collide (POD-SPEC §6.1). The
agent runs services by absolute path (`/opt/venvs/<name>/bin/…`), so no venv is on `PATH`. The
build context is the repository root (`-f pod/images/Dockerfile.base .`) because the base image
installs `concept-captioner` from `src/` and `podagent` from `pod/agent/`; the trainer images copy
nothing from the context except the aitoolkit image's patch series (`pod/images/patches/ai-toolkit/*.patch`).

SeedVR2 reuses each trainer's PyTorch 2.13, torchvision, Triton and CUDA libraries through
symlinks to those packages and their version metadata. Other trainer packages stay isolated.
Its remaining dependencies are pinned in `seedvr2-requirements.txt` and installed
with `--no-deps`, so no second GPU stack is pulled in. The separate small environment preserves
the trainer's dependencies, including musubi's older diffusers. Each trainer build checks the
shared torch's version and location and runs SeedVR2's CLI help. No environment installation
runs at boot or on Upscale; only model weights download on first use.

## Pins

Every pin was read from its source on 2026-10-10. `date` is when upstream published it.

| what | pin | date | why this one |
| --- | --- | --- | --- |
| base image | `nvidia/cuda:12.8.1-cudnn-runtime-ubuntu22.04@sha256:17e2934e…1202bb` (manifest list; amd64 image `sha256:59e0e437…5010`) | 2025-03-13 | the tag the spec names, by digest. Runtime, not devel: the venvs bring their own CUDA libraries through pip, the system CUDA serves `nvidia-smi` and the optional JIT toolchain |
| uv | `ghcr.io/astral-sh/uv:0.12.21` | 2026-09-29 | more than a week old at pin time; its bundled interpreter registry lists 3.12.14 (checked in `crates/uv-python/download-metadata.json` at that tag) |
| CPython | `3.12.14` (python-build-standalone, via `uv python install`) | — | the newest 3.12 that uv 0.12.21 can install; 3.12.15 was released 2026-09-30, after that uv's registry was cut |
| vLLM | `0.31.0` **`+cu129`** wheel from the GitHub release | 2026-10-05 | the newest release; see "CUDA and drivers" for why cu129 and not cu128 |
| torch for vLLM | `torch==2.13.0+cu129`, `torchvision==0.28.0+cu129`, `torchaudio==2.11.0+cu129`, `torchcodec==0.15.0+cu129` | 2026-07-08 | exactly what the vllm wheel requires (`torch==2.13.0`, `torchvision==0.28.0`, `torchaudio==2.11.0`, `torchcodec>=0.14`), from the cu129 index |
| FlashInfer kernel cache | `flashinfer-jit-cache==0.7.0.post1` from `https://flashinfer.ai/whl/cu129` | — | the FlashInfer version vllm 0.31.0 pins (`flashinfer-python==0.7.0.post1`, and `FLASHINFER_VERSION` in its `docker/Dockerfile`) and the install vLLM's own image performs so FlashInfer needs no `nvcc` for its shipped kernels; optional (`FLASHINFER_JIT_CACHE_VERSION=""` skips it) |
| ai-toolkit | `ostris/ai-toolkit@f7a1fb9a77e5418269b1e9eda4ace6d7c1b7bb47` ("Version bump") | 2026-10-10 | the release commit at the top of `main` at pin time |
| ai-toolkit patches | the series in `pod/images/patches/ai-toolkit/` (REPA, three patches), applied with `git am --3way` | — | The pin above is the **base**: `AI_TOOLKIT_COMMIT` and `generate_results.AI_PIN` keep naming it. |
| ai-toolkit torch | `torch==2.13.0+cu130`, `torchvision==0.28.0+cu130`, `torchaudio==2.11.0+cu130`, `torchcodec==0.15.0+cu130` | 2026-07-08 (torch) | copied from that commit's `docker/Dockerfile` and `manager/spec.py` (upstream's "linux cu130" spec). cu126 is upstream's only other prebuilt stack and has no Blackwell kernels |
| ai-toolkit extras | `requirements.txt` at the commit (diffusers at `c9438378…`, transformers 5.5.3, peft 0.18.1, …), then `setuptools==69.5.1`, `natten==0.21.7+torch2130cu130` (whl.natten.org), `flash_attn 2.8.3+cu130torch2.13` cp312 (mjun0812/flash-attention-prebuild-wheels v0.9.47) | — | the same files and the same order as upstream's Dockerfile |
| SeedVR2 command line | `numz/ComfyUI-SeedVR2_VideoUpscaler@5a4bf428f3735cc72ac760d40f372f94dec28422` (v2.5.23) | 2025-12-24 | the newest release at pin time (2026-10-22); Apache-2.0, as are the ByteDance-Seed SeedVR2-3B/7B weights it downloads (FP16 repacks from `numz/SeedVR2_comfyUI`, SHA-256-checked by the program) |
| SeedVR2 venv | trainer's PyTorch 2.13/CUDA; diffusers 0.36.0, peft 0.18.0, rotary-embedding-torch 0.8.9, gguf 0.17.1, opencv-python-headless 4.11.0.86, … (full list: `seedvr2-requirements.txt`) | — | preserves the small packages resolved in v0.3.9; removes its separate torch 2.9.1, torchvision, Triton and NVIDIA packages. Upstream requires PyTorch 2.4+, not 2.9.1 |
| LTX-2 | `Lightricks/LTX-2@be6d6d0a69d11a0a399c462ed92606692e5f8697` ("Merge pull request #326"; packages 1.4.2) | 2026-10-13 | the top of `main` at pin time; differs from the previous pin `9ec55f9f` only in `LICENSE-2_x`; `packages/ltx-trainer/scripts/{process_dataset,train}.py` both exist there, and the trainer reads LTX-2.3 unified checkpoints and LTX-2.5 split packs |
| LTX weights | `LTX_HUB_SOURCES` in `pod/agent/src/podagent/ltx_rules.py`: `Lightricks/LTX-2.3@3c6a4e66` (plus the Gemma 3 root from `Lightricks/LTX-2@dfcc2108`), `Lightricks/LTX-2.5@49b093a3` (gated), `Lightricks/LTX-2@dfcc2108` for older runs | 2026-10-15 | downloaded by `launch_ltx.py` at run time, not baked into the image |
| LTX-2 torch | `torch==2.13.0+cu132` + `natten==0.21.7+torch2130cu132` via ltx-core's `natten` extra; everything else resolved by `uv lock` at build time inside the bounds the packages declare | — | upstream's README installs `uv sync --extra natten`; the extra is the only exact torch pin in the workspace, so the build asserts it landed. The resolved lock is kept at `/opt/ltx-2/uv.lock` |

apt packages (`git curl ca-certificates build-essential ffmpeg libgl1 libglib2.0-0`) are not
version-pinned on purpose: Ubuntu's archive keeps only the current security build, so an exact pin
breaks at the next security update. The base digest pins the layer beneath them.

The ai-toolkit patch series is part of that pin: after a bump to a commit that already contains
REPA, delete the series (and the Dockerfile's `COPY` and `git am` steps); otherwise re-export it
against the new base and let the build show whether it still applies.

To bump a pin: `curl -s https://pypi.org/pypi/vllm/json | jq .info.version` and the release's
asset list on GitHub for vLLM (look for the `+cu129` wheel), `git ls-remote <repo> HEAD` for the
trainers (then re-read their `requirements`/`pyproject` for the torch stack and copy it), Docker
Hub's tag page for the CUDA digest, `uv python list --all-versions` for the interpreter.

## CUDA and drivers

The contract says "vLLM with its cu128 torch". That no longer exists upstream: vLLM has never
published a `+cu128` wheel (its CUDA 12 variant has been `+cu129` since 0.20, with CUDA 13 as the
PyPI default since torch 2.13), and torch 2.13 is not on the cu128 index. The closest faithful
choice is the `+cu129` build on the CUDA 12.8 base: pip-installed CUDA libraries do not care what
`/usr/local/cuda` is, only the host driver matters, and CUDA 12.9 wheels run on any CUDA 12.x driver
(R570 is the 12.8 line RunPod hosts commonly report; minor-version compatibility covers 12.9). The
alternative, vLLM's PyPI default (CUDA 13), would make the *base* image need an R580+ driver too.

Both trainers are on CUDA 13 upstream and there is no supported way around it: ai-toolkit's own
Dockerfile pins torch cu130 with cu130-built flash-attn and NATTEN; LTX-2's packages pin the cu132
index and NATTEN cu132. So:

| image | wheels | host driver | RunPod |
| --- | --- | --- | --- |
| `…-pod-base` | no PyTorch; SeedVR2 gets CUDA from the trainer image | CUDA 12.8 base startup requirement; use a trainer image for GPU services | as its trainer |
| vLLM in the `-captioning` tags | cu129 | CUDA 12.x driver (R570+; R525+ via minor-version compatibility, unverified); the trainer below needs more | as its trainer |
| `…-pod-aitoolkit`, `…-pod-ltx` | base + CUDA 13.0 / 13.2 | **R580 or newer** | filter the pod's CUDA version to 13.0+ when creating it (`gpu.minCudaVersion` in the REST v2 pod create; the console's "CUDA version" filter) |

Mixing cu129 and cu13x venvs in one image is fine: each venv has its own `nvidia-*` libraries, and
one driver that satisfies the strictest (13.2) satisfies all. The base's `NVIDIA_REQUIRE_CUDA`
(cuda>=12.8) only gates container start, which an R580 driver passes.

## Building

```bash
# from the repo root; BuildKit is required (COPY --chmod), which is the default since Docker 23
docker buildx build --platform=linux/amd64 -f pod/images/Dockerfile.base      -t concept-captioner-pod-base:dev .
docker buildx build --platform=linux/amd64 -f pod/images/Dockerfile.aitoolkit -t concept-captioner-pod-aitoolkit:dev \
    --build-arg BASE_IMAGE=concept-captioner-pod-base:dev .
docker buildx build --platform=linux/amd64 -f pod/images/Dockerfile.ltx       -t concept-captioner-pod-ltx:dev \
    --build-arg BASE_IMAGE=concept-captioner-pod-base:dev .
# the "-captioning" variant of a trainer image: the same vLLM layer on top of it
docker buildx build --platform=linux/amd64 -f pod/images/Dockerfile.captioning -t concept-captioner-pod-ltx:dev-captioning \
    --build-arg BASE_IMAGE=concept-captioner-pod-base:dev --build-arg TRAINER_IMAGE=concept-captioner-pod-ltx:dev .

# push for RunPod (the app references ghcr.io/<owner>/concept-captioner-pod-<trainer>:<tag>)
docker tag concept-captioner-pod-aitoolkit:dev ghcr.io/<owner>/concept-captioner-pod-aitoolkit:<tag>
docker push ghcr.io/<owner>/concept-captioner-pod-aitoolkit:<tag>
```

Build args worth knowing: `CUDA_JIT_TOOLCHAIN=1` on `Dockerfile.captioning` adds the CUDA 12.9 compiler (`cuda-nvcc-12-9`
and the `-dev` packages vLLM's own image installs, about a gigabyte) and repoints `/usr/local/cuda`
at 12.9 for FlashInfer kernels missing from the prebuilt cache; `FLASHINFER_JIT_CACHE_VERSION=""`
skips the cache; `VLLM_VERSION`, `AI_TOOLKIT_COMMIT`, `LTX2_COMMIT` and the torch versions are all
args so a bump is a one-line change plus an updated comment. The platform is fixed on every `FROM`,
so a build on Apple Silicon works without `--platform` too (but is emulated and slow; build on x86).

Every venv's build ends with an import check that needs no GPU (vLLM: torch build string and
package versions; ai-toolkit: `import flash_attn, natten, torchcodec, diffusers, transformers`,
the same check upstream's Dockerfile runs; LTX-2: the exact torch build and that the `natten` extra
landed) and writes `/opt/venvs/<name>/freeze.txt`, so a broken pin fails the build rather than the
first service start. Release tables above record measured compressed sizes. The thin SeedVR2
environment removes the previous release's duplicate GPU stack and saves 2.76 GB per compressed
image. Release builds use an exact `git archive` context. The builds download several gigabytes of wheels.

There is no `.dockerignore` in the repository root yet, so the build context carries `.git`, the
local `.venv`s and `app/`. The Dockerfiles only `COPY` what they need, so this costs upload time, not
image size. Adding one is the repo owner's call; this content would do:

```
.git
**/.venv
**/__pycache__
**/.pytest_cache
**/.ruff_cache
app/
pod/images/workspace/
```

### Local fake mode

```bash
PODAGENT_TOKEN=local-dev-token-0123 docker compose -f pod/images/compose.fake.yaml up --build
podctl --url http://127.0.0.1:8800 health
```

The compose file publishes 8000 beside 8800 and sets `PODAGENT_FAKE_HOST=0.0.0.0`, so
vLLM's fake readiness endpoint is reachable from the host. Fake and real TensorBoard both bind
loopback and are shown through the authenticated agent at `/tensorboard/`; port6006 is never
published. The app first calls authenticated `POST /tensorboard-session`, installs its derived HMAC
cookie scoped to `/tensorboard`, then loads the page and its subresources. The cookie cannot
authenticate other agent API routes; the bearer is not a browser cookie.

`Dockerfile.fake` installs `pod/agent` alone (no `[pod]` extra, no concept-captioner); it exists to
drive the fake services (POD-SPEC §3, §6.3) and is not a stand-in for the CUDA images.

## Pod creation (the app's side, for reference)

HTTP ports `8800,8000` exposed, `PODAGENT_TOKEN` (16+ characters) and `HF_TOKEN` as env, the
volume at `/workspace`, a trainer image, and a CUDA 13.0+ host for the trainer images. The agent
refuses to start without the token, so a pod created without it exits immediately and visibly.
`nvidia-smi` is not in the image: the NVIDIA container runtime mounts it (the base sets
`NVIDIA_DRIVER_CAPABILITIES=compute,utility`), which is how `/gpus` reads the inventory.

## Verification record and remaining coverage

[POD-STATUS](../docs/POD-STATUS.md) records the current image, training, generation, captioning
and native-app acceptance. The release receipt above identifies the exact published images;
the build checks cover all three trainer stacks and all three captioning variants. Runtime
measurements identify the GPU, workload, output checks and resource cleanup for each pass.

### H3 runtime assets

The published AI Toolkit image includes the H3 helpers and the shared recipe/asset JSON from
the native resource. AI Toolkit remains pinned to `f7a1fb9a77e5418269b1e9eda4ace6d7c1b7bb47`.
H3 model binaries download at runtime from `Comfy-Org/MiniMax-H3` revision
`e5eb578a89295337b8ff433a035929ce0279e0b6`; the image training adapter comes from
`circlestone-labs/MiniMax-H3-Image-Training-Adapter` revision
`7c6c04f75ba597232d4ce2bb4a14709948ec723a`. Filename choices are defined once in the shared
resource. The BF16 H3 assets occupy 97.55 GB and the image adapter 0.62 GB. With SeedVR2 3B,
its VAE and the CapQwen caption checkpoint, the selected weights total 126.35 GB before training
outputs and caches. The real GPU acceptance uses a 150 GB workspace; the app’s default pod disk
is 300 GB.
