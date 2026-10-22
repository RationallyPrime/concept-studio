#!/usr/bin/env python3
"""VGG19 Gram-feature style similarity for saved report renders.

Style representation: correlations of relu1_1, relu2_1, relu3_1, relu4_1 and relu5_1 features,
following Gatys et al. (https://arxiv.org/abs/1508.06576). Each flattened Gram matrix has unit
length; their concatenation has unit length. Reference images form a unit-normalized centroid.
The score is cosine similarity, not a calibrated probability or a content/identity score.

Torchvision's explicit IMAGENET1K_V1 weights download once to retained workspace storage.
Imports stay light until an actual style report requests embeddings.
"""

from __future__ import annotations

import os
import subprocess
import tempfile
from pathlib import Path
from typing import Any

METHOD = "vgg19-imagenet1k-v1-gram-relu1_1-2_1-3_1-4_1-5_1-cosine-v1"
LAYERS = (1, 6, 11, 20, 29)
VIDEO_FRACTIONS = (0.25, 0.5, 0.75)


def gram_vector(features: Any) -> Any:
    """One feature map's spatial correlations; shape CxHxW (or 1xCxHxW)."""
    import torch

    flat = features.reshape(features.shape[-3], -1)
    gram = flat @ flat.T / flat.shape[1]
    return torch.nn.functional.normalize(gram.flatten(), dim=0)


def media_images(path: Path) -> list[Any]:
    from PIL import Image

    if path.suffix.lower() != ".mp4":
        with Image.open(path) as image:
            return [image.convert("RGB")]
    duration = float(
        subprocess.check_output(
            [
                "ffprobe",
                "-v",
                "error",
                "-show_entries",
                "format=duration",
                "-of",
                "csv=p=0",
                str(path),
            ],
            text=True,
        ).strip()
    )
    images = []
    with tempfile.TemporaryDirectory(prefix="report-frames-") as temporary:
        for index, fraction in enumerate(VIDEO_FRACTIONS):
            destination = Path(temporary) / f"frame-{index}.png"
            subprocess.run(
                [
                    "ffmpeg",
                    "-v",
                    "error",
                    "-ss",
                    str(duration * fraction),
                    "-i",
                    str(path),
                    "-frames:v",
                    "1",
                    "-y",
                    str(destination),
                ],
                check=True,
            )
            with Image.open(destination) as image:
                images.append(image.convert("RGB"))
    return images


class StyleEmbedding:
    def __init__(self, workspace: Path) -> None:
        import torch
        from torchvision.models import VGG19_Weights, vgg19

        os.environ.setdefault("TORCH_HOME", str(workspace / ".cache/torch"))
        self.torch = torch
        self.device = "cuda:0"
        weights = VGG19_Weights.IMAGENET1K_V1
        self.transform = weights.transforms()
        self.model = vgg19(weights=weights).features[: LAYERS[-1] + 1].eval().to(self.device)
        self.model.requires_grad_(False)

    def image(self, image: Any) -> Any:
        value = self.transform(image).unsqueeze(0).to(self.device)
        parts = []
        with self.torch.inference_mode():
            for index, layer in enumerate(self.model):
                value = layer(value)
                if index in LAYERS:
                    parts.append(gram_vector(value))
        return self.torch.nn.functional.normalize(self.torch.cat(parts), dim=0)

    def media(self, path: Path) -> Any:
        vectors = [self.image(image) for image in media_images(path)]
        return self.torch.nn.functional.normalize(self.torch.stack(vectors).mean(dim=0), dim=0)


def score_outputs(
    groups: dict[str, list[str]], references: Path, outputs: list[Path], workspace: Path
) -> dict[str, Any]:
    encoder = StyleEmbedding(workspace)
    torch = encoder.torch
    try:
        centroids = {}
        for trigger, files in groups.items():
            vectors = [encoder.media(references / file) for file in files]
            centroids[trigger] = torch.nn.functional.normalize(
                torch.stack(vectors).mean(dim=0), dim=0
            )
        scores = {}
        for output in outputs:
            vector = encoder.media(output)
            scores[output.name] = {
                trigger: float(torch.dot(vector, centroid).clamp(-1, 1).item())
                for trigger, centroid in centroids.items()
            }
        return {
            "method": METHOD,
            "reference_counts": {key: len(files) for key, files in groups.items()},
            "video_frame_fractions": list(VIDEO_FRACTIONS),
            "scores": scores,
        }
    finally:
        del encoder
        torch.cuda.empty_cache()
