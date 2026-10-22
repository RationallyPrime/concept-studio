# CORE-STATUS

**ConceptCore powers captioning, review and dataset exchange in the Mac app**, with the same
job, skill, profile and sidecar formats as the Python CLI. It captions images through vLLM and
ChatGPT, images and video through Gemini, and exchanges private datasets with Hugging Face.
The owner also confirmed native ChatGPT and OpenRouter sign-in and captioning, and completed a
267-image project through GPU captioning and private publication in ConceptStudio 0.3.1 on
2026-10-21, reported in the following day's briefing.

Updated 2026-10-22. [CORE-SPEC.md](CORE-SPEC.md) defines the shared contract;
[development history](../../docs/process/status-history-2026-10-10.md) records the original
2026-10-10 integration at `e620882`.

## Capabilities

All nine CORE-SPEC modules are implemented:

- **Projects, skills and prompts.** YAML round trips, bundled and custom Agent Skills,
  model-specific profiles, prompt assembly and exact trigger validation.
- **Model clients.** OpenAI-compatible servers, OpenAI Responses, Anthropic, Gemini and ChatGPT
  plan access. Structured output includes an in-conversation correction retry. ChatGPT streams
  Responses with `store: false`. OpenRouter, Vercel AI Gateway and Pydantic AI Gateway have
  dedicated host and credential routing.
- **Credential routing.** Jobs select models; configured account origins determine where keys
  are sent. vLLM credentials are bound to the configured scheme, host and port. Authentication
  headers are controlled by the client.
- **Runner.** Per-sample results, optional critic review, response records and human-final caption
  protection. Cancellation drains active work before returning.
- **Sources and sinks.** Local folders, caption/record sidecars, Hub imagefolder datasets and
  LFS upload with verification before commit.

## Walkthrough contract changes, 2026-10-12

Empty `concepts: []` projects load and save in both languages; adding a concept enables execution.
The Gemini client normalizes Google's `models/` prefix. Provider catalogs list available models;
Captioning runs the selected model.

Native imports retain matching captions and response records through file renaming and
normalization. Text-only captions retain imported status; human-final records retain their
protection. The app and CLI share the serialized job and sidecar formats.

## Overnight extensions

- **Concept categories.** Category-derived defaults and caption/reviewer instructions cover all
  seven categories. Style and motion use whole-target mappings; locator concepts use confirmed
  assignments. The shared Caption schema applies its usable rule across categories.
- **Video targets.** Local and Hub imagefolders preserve clips. Gemini, OpenRouter and native vLLM
  routes receive the full approved video target. LTX and H3 profiles describe the selected segment;
  `h3-video` retains its three text fields and is identical in Swift and Python. Mixed H3 datasets
  apply the `h3-still` conventions to still images.
- **Prepared media.** The app normalizes HEIC/TIFF and approves crops or video segments before
  captioning. Publication and training use the included targets. Prompts identify the attached
  media and its audio-inspection status.
- **Live caption preview.** ChatGPT deltas flow to the runner's per-sample preview. Retry,
  completion, failure and cancellation settle that preview; completed validated captions reach
  the sink.
- **Python parity.** Job-relative skill/profile loading and mixed-Hub file dispatch match Swift.
  Both implementations cap encoded video requests below **20 MiB**, including prompts, schema
  and retry history. Python Gemini/OpenRouter use pydantic-ai. The Python vLLM video route awaits
  library support; unsupported video routes report the restriction before sending media.

## Verified live

| Connection | Completed check |
| --- | --- |
| Hugging Face Hub | Private synthetic dataset uploaded, LFS objects verified before commit, and media downloaded with matching bytes, hashes and records. |
| vLLM on an owned pod | Native structured image captions from Qwen 2.5 VL 3B and Qwen3 VL 8B, with credentials bound to the configured host. On 2026-10-22 the app started the FP8/NVFP4 CapQwen3.6-27B on a rented 32 GB RTX 5090 (vLLM 0.31.0; server ready in 143 s, 20 H3 captions in 141 s). |
| Gemini | Direct image captioning and the 2026-10-11 native video check described below. |
| ChatGPT | Production image request returned HTTP 200 and a usable Caption from `gpt-6.1-sol`; 2,067 input / 49 output tokens. Owner confirmed native sign-in and captioning. |
| OpenRouter | Owner confirmed native sign-in and live image captioning on 2026-10-11. |
| Complete captioning project, reported 2026-10-22 | Owner completed Hub import, concept/mapping, rented-GPU captioning and private publication for 267 images in app 0.3.1. |
| Pod agent and RunPod through app code | Training-event reads, stop, and native FLUX/LTX model and comparison downloads with matching hashes and offline reopen. |

The **2026-10-11 Gemini video check** sent the exact approved synthetic MP4: **nine frames at
512 × 288**. `gemini-3.8-flash` returned HTTP 200 and a usable shared Caption with **4,389 input /
76 output tokens**. Explicit **24 FPS sampling** resolved the initial default-sampling 400;
a single-variable control and the production client confirmed the change. All three requests and
their decoded outputs are in `evidence/2026-10-11-video-native-proof/README.md`.

See the [ChatGPT results](APP-STATUS.md#chatgpt-connection-follow-up-2026-10-11) and
[GPU training, Resume and generation results](../../pod/docs/POD-STATUS.md).

## Automated test coverage

The **2026-10-12 walkthrough/glossary gate passed 261 Core tests in 38 suites and 118 Python
reference tests**, with clean lint and formatting. The Python gate includes the H3 clip profile,
mixed-metadata handling and unrelated-Parquet fixes.

Coverage includes:

- All seven concept categories in image and video modes; exact video bytes and 24 fps metadata.
- OpenRouter/vLLM video request bodies and encoded-size limits.
- OpenAI, Anthropic and all three gateway routes, including thinking settings and wire formats,
  through stubbed transports.
- ChatGPT streaming, interruption, failure, incomplete/malformed output, image/schema requests,
  cancellation and usage-limit handling.
- URLSession SSE reaching the runner before sidecar creation, with preview clearing on
  retry, failure and cancellation.
- Credential headers for matching/different origins and selected ambiguous URL inputs.

Independent source review accepted the media and progress integration.

<a id="open"></a>

## Next checks

- Update provider results for direct OpenAI API-key access, Anthropic and the remaining gateways.
- Record partial-caption preview and native saving in a live run.
- Add OpenRouter/vLLM video results alongside their request-body tests.

**Dataset format:** Hub inputs use imagefolder datasets. Convert Parquet-backed datasets to
imagefolder before importing.
