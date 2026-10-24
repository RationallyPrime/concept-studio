# ConceptStudio

**Teach an image or video model something new from your own photos or clips: a person, a pet,
an object, a style or a movement. Everything runs from a Mac, with no graphics card and no
machine-learning background needed.**

ConceptStudio takes you from a folder of examples to your own trained model adapter. Choose
what to teach, prepare your images and clips, generate captions, and train on a cloud GPU—all
in one native Mac app. Bring the result into your favourite image or video workflow and start
creating with it.

| Make every caption count | Watch your model learn |
| --- | --- |
| ![Review captions beside your training images](docs/images/readme-review.png) | ![Follow training with live learning curves](docs/images/readme-monitor.png) |

## Your examples. Your model.

- **Build the training set you want.** Import from folders, Apple Photos or Hugging Face.
  Keep the best copy of each duplicate, drag a crop around your subject, and select exact video segments.
  Adjust light and colour on your Mac, bring individual outliers into line, and keep every original.
  Start a project directly from a Hugging Face dataset URL, down to the folder you want.
  Upscale and restore images and clips with SeedVR2, with a before-and-after preview.
- **Teach the subject, keep the scene.** Define your person, pet, object, style or movement.
  Match faces locally with SFace, or map nine photos per AI request with numbered contact sheets.
  Confirm matches in batches and set uncertain samples aside for review. Model-specific captions describe the surroundings, pose and lighting
  that make each example distinct.
- **Caption with your choice of AI.** Use your ChatGPT plan, OpenRouter, a provider key or
  your own vLLM server. Launch a captioning model on a cloud GPU directly from the app.
  Add a second model to review captions, edit them beside the media, and protect the ones
  you've finished.
- **Put cloud power to work.** Compare live GPU prices and availability, choose your storage,
  and set your budget. ConceptStudio rents and controls the GPU for you. Keep stopped GPUs and their model caches,
  then switch computers when you need different hardware.
- **Train with settings ready to go.** Choose a model and start from its prepared recipe.
  Add class images to preserve the base model's range, mask unwanted people out of training,
  and flip eligible examples on the fly. Each trainer exposes the controls it supports.
  Teach H3 clips with sound or train their picture and motion alone—your project remembers the choice.
  Follow the learning curve and logs live, save checkpoints, and repeat runs with your saved
  settings. Advanced controls put the details within reach.
- **Measure what you taught.** Get a report with matched renders, fixed seeds, identity and
  style similarity, and prompt-adherence scores. Compare training runs against the same frozen
  prompt set. Save your adapter to your Mac or publish it to Hugging Face.

## Image and video models

Train image adapters for **FLUX.1-dev**, **Z-Image**, **Qwen-Image-2.1** and **Krea 2**, and image
or video adapters for **LTX-2.3**, **LTX-2.5** and **MiniMax H3**. Each comes with a model-specific recipe.

Want more control? **Advanced user** unlocks detailed training settings and 18 additional
AI Toolkit architectures, including FLUX.2, Chroma, SDXL, Lumina 2 and HiDream-O1.
Explore [models, recipes and licences](docs/model-table.md) and
[training settings and hardware requirements](app/docs/RUNNING.md#prepare-and-train).

## A Mac app that puts you in control

Your projects live in ordinary folders. Your credentials live in Keychain. Review exactly
which media and captions enter training, keep datasets private, and choose where to save the
result. Publish to Hugging Face or send your dataset straight to the GPU. Uncaptioned samples
stay out by default, with a clear choice to include them. Adult-content projects get explicit
captioning guidance and private publishing.

ConceptStudio is free and open source. GPU rentals and storage are billed to your RunPod
account; captioning uses your chosen provider or self-hosted model.
[Accounts, privacy, costs and GPU operating requirements](app/docs/RUNNING.md#prepare-and-train)
are covered in the running guide.

Built-in Help explains the workflow and its vocabulary in plain language, with deeper
explanations one click away. Start simple and open up the expert controls when you want them.

## Get started

Build on **macOS 15 or later** with Xcode:

```sh
git clone https://github.com/RationallyPrime/concept-studio.git
cd concept-studio
scripts/build-app.sh debug
open app/dist/ConceptStudio.app
```

Choose **Try the demo** to explore the complete workflow with a ready-made project—no accounts
or spending required. Then create your own project and bring your examples.

[Run ConceptStudio](app/docs/RUNNING.md) covers setup, accounts, training and distribution.

## Command-line captioning

**`concept-captioner`** brings the same captioning workflow to Python and the terminal. Read
images from a folder or Hugging Face dataset, generate model-specific captions, and write
sidecars or update the dataset. Shared project files let you move between the CLI and the app.

```sh
uv venv
uv pip install -e ".[hf]"
.venv/bin/concept-captioner --help
```

The [CLI guide](docs/CLI.md) covers providers, custom instructions, caption profiles and reruns.

## Explore the project

- [App and workflow](app/docs/APP-BRIEF.md) · [Running guide](app/docs/RUNNING.md) · [CLI guide](docs/CLI.md)
- [Mapping benchmark](app/docs/MAPPING-BENCHMARK.md) · [Engineering](docs/ENGINEERING.md) · [GPU services](pod/README.md) · [Model table](docs/model-table.md)
- [Captioning contract](app/docs/CORE-SPEC.md) · [Pod contract](pod/docs/POD-SPEC.md) · [Decision log](docs/ADR-LOG.md)
- [App status](app/docs/APP-STATUS.md) · [Captioning status](app/docs/CORE-STATUS.md) · [GPU status](pod/docs/POD-STATUS.md)

## Licence

ConceptStudio is [MIT licensed](LICENSE). Model licences and access requirements are listed
in the [model guide](docs/model-table.md) and shown in the app before training.
