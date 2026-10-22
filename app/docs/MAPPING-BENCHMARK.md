# Mapping contact-sheet measurement

The default is a **3 × 3 numbered contact sheet with 768-pixel tiles**. Single images and 2 × 2 sheets remain selectable on Mapping.

On 22 October 2026, the app's actual `StudioAssistant.proposeMappingSheet` path ran all three layouts against the same private copy of 69 photographs with confirmed mappings for two related people. The same references, concept definitions, image order and provider were used throughout. The provider was **Sign in with ChatGPT, `gpt-6.1-sol`**. Requests ran sequentially in each trial. The original dataset was not modified; the benchmark also verified that the copied job's saved mappings were unchanged.

| Layout | Exact concept-presence matches | False negatives | False positives | Wall time | Planned batches |
| --- | ---: | ---: | ---: | ---: | ---: |
| Single image | 63 / 69 (91.30%) | 6 | 1 | 404.77 s | 69 |
| 2 × 2 | 66 / 69 (95.65%) | 3 | 0 | 219.02 s | 18 |
| 3 × 3 | 68 / 69 (98.55%) | 1 | 0 | 174.24 s | 8 |

All trials completed with zero failed samples. The 3 × 3 trial was **2.32 times faster** than the single-image trial and matched the confirmed concept sets in five additional photographs. That result selects the initial layout. It is one measured dataset and provider; the layout control lets the user change it for another model or dataset.

“Exact concept-presence match” means the predicted set of triggers equals the confirmed set for a photograph. It does **not** establish that left/right locators or scene descriptions are correct, or that a person is assigned to the correct face when both people appear. False positives and false negatives count individual trigger decisions. Planned batches are the initial requests needed by the layout; validation and transport retries can add provider requests. Wall time includes the complete trial.

The aggregate receipt is [mapping-benchmark-2026-10-22.json](mapping-benchmark-2026-10-22.json). It contains no personal names, sample filenames, captions, reference images or photographs.

## Locator cross-check

A second live pass used the nine photographs with both people mapped, again with all three layouts. Each layout returned both people on eight photographs and omitted the partially visible subject on the ninth. Manual comparison of returned locator text with the confirmed locators found **zero left/right swaps among the 48 left/right assignments** returned for the eight clearly localized pairs across the three layouts. The remaining returned subject had no left/right label in the saved ground truth and was not included in that positional count.

This cross-check establishes agreement with saved positional labels on those rows. It does not grade every scene-description detail. The private predictions and descriptions stay outside the repository; the aggregate receipt includes only counts and timings.

## Running the same comparison

Use a private **copy** of a ConceptStudio project with confirmed mappings and reference photographs. The benchmark does not alter its mappings. Running it sends those photographs to the configured provider and can consume credits or plan usage.

```sh
MAPPING_BENCHMARK_PROJECT=/private/path/to/project-copy \
MAPPING_BENCHMARK_OUTPUT=/private/path/to/aggregate.json \
swift test --package-path app --filter MappingBenchmarkTests
```

The default benchmark provider uses the app's existing ChatGPT sign-in and plan permission. `MAPPING_BENCHMARK_MODEL` selects a model from that account. For an already running self-hosted server, set `MAPPING_BENCHMARK_ENDPOINT` to a private JSON file containing `baseURL`, `model`, and `token`. The test does not rent a GPU.

For a focused locator audit, `MAPPING_BENCHMARK_MULTI_PERSON_ONLY=1` selects only rows with more than one confirmed concept. `MAPPING_BENCHMARK_DETAILS=/private/path/to/details.json` writes the expected and proposed locators plus each tile's description to that explicitly private path. Those details can identify people and must stay outside public receipts.

## Operational behavior

Mapping skips confirmed samples and samples marked Not sure. Completed suggestions, including “no confident match,” are saved with the project and reused on resume. Clearing suggestions requests a fresh pass; changing a reference clears suggestions automatically. Each tile has a large number in a separate top margin, and replies are validated for exactly one answer per tile before filenames are associated with answers. Tile descriptions appear alongside proposals for review.

A transient sheet failure retries its images individually, up to twice. A failure for one image does not discard completed siblings. Cancellation preserves completed results. On a self-hosted vLLM endpoint, up to four batches run concurrently, bounded by the chosen concurrency setting; hosted providers use one batch at a time. Pending requests count as GPU activity. A count and estimated remaining time are shown during the run.

The local tests cover response order, tile-number validation through the structured stage, downsampled sheet dimensions, transient retries, cancellation, saved resume state, uncertainty, batch undo and reference replacement. The authorized RTX 5090 Secure Cloud trial could not run because the requested GPU was unavailable; these measurements therefore make no claim about vLLM throughput.

## Local face matching and review states

Mapping also offers **Match faces on this Mac**, using OpenCV Zoo's SFace 2021dec through native ONNX Runtime and Apple Vision landmarks. The first run downloads the 39 MB Apache-2.0 model; photos stay on the Mac. Results show match, needs review or no match, with similarity scores. Single-person bulk confirmation accepts only a unique match in a single-face sample. Tilted faces, collapsed landmarks, missing faces and all other results remain for review. Reference checks flag small or blurry faces before matching.

A missing or `null` job mapping means **unconfirmed/held**, never “confirmed absent.” Exclusion is separate: the media lives in `.conceptstudio/excluded/`. A confirmed nonempty mapping establishes which concepts are present; another concept omitted from that mapping is absent. The shared job format rejects empty mappings, so a sample with none of the project's concepts should be excluded. No migration converts null mappings into negative labels. Evaluation scripts must use included media and nonempty confirmed mappings for ground truth.

For a single-concept project whose trigger was edited outside the app, opening the project recovers a sole reference stored under an old UTF-8 hex filename to the current canonical filename. Multiple concepts or multiple reference images require an explicit choice; the app does not guess which reference belongs to which person.

## Native SFace measurement, 2026-10-22

The native implementation processed the same 69 confirmed photographs on the Mac in **6.00 seconds**
with the model already downloaded. It used the real project references, pinned OpenCV weights,
Vision landmarks and RGB 0–255 input. All samples completed; the answer key and references remained
byte-identical. The thresholds stayed at match above 0.39, review above 0.33 through 0.39, and no match
at or below 0.33, with the roll and landmark quality gates applied before confirmation.

| Confirmed state | Match | Needs review | No match |
| --- | ---: | ---: | ---: |
| Concept 1 present, 39 decisions | 26 | 12 | 1 |
| Concept 1 absent, 30 decisions | 0 | 3 | 27 |
| Concept 2 present, 39 decisions | 10 | 12 | 17 |
| Concept 2 absent, 30 decisions | 0 | 4 | 26 |

There were **zero false-positive match bands across 60 confirmed absences**. Both presence decisions
were decisive and correct in 30 of 69 photographs. In the nine photographs with both subjects,
each subject matched in five and both matched in four. This measures concept presence, not
face-to-locator correctness. These local SFace counts and the hosted contact-sheet counts above
measure different workflows; review-band results are retained for human review.

The second reference triggered both the small-face and low-clarity warnings. Its missed matches
also appeared in the original experiment: 11 matches, seven reviews and 21 no-matches among its
39 positive examples. Recomputing the documented nose-mean alignment with the same weights and
reference reproduced the native second-concept counts. No threshold was adjusted to fit this run.
Seven samples had quality-gated faces: four beyond 35° roll and three with collapsed landmarks.

The [anonymous aggregate receipt](native-sface-benchmark-2026-10-22.json) contains counts, timings,
weight identity and reference-quality warnings. Private photos, names, per-image scores and
sample identifiers remain outside the repository.
