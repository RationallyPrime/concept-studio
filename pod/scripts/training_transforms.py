#!/usr/bin/env python3
"""Native AI Toolkit augmentation and spatial masks over metadata-listed training targets."""

from __future__ import annotations

import copy
import json
import re
from pathlib import Path
from typing import Any

import yaml
from PIL import Image

MEDIA_SUFFIXES = {".jpg", ".jpeg", ".png", ".webp", ".mp4", ".mov", ".m4v"}
VIDEO_SUFFIXES = {".mp4", ".mov", ".m4v"}
SIDE_WORD = re.compile(r"\b(?:left|right)\b", re.IGNORECASE)


def native_transforms(cfg: dict[str, Any], run_dir: Path, process: dict[str, Any]) -> None:
    """Split native file lists, not media bytes; masks stay paired by the original stem."""
    mode = cfg.get("augmentation", "none")
    root = Path(cfg["dataset"]["path"])
    mask_dir = root / "training_masks"
    has_masks = mask_dir.is_dir() and any(mask_dir.glob("*.png"))
    if mode == "none" and not has_masks:
        return
    if mode == "square":
        job = (
            yaml.safe_load((root / "job.yaml").read_text()) if (root / "job.yaml").is_file() else {}
        )
        concepts = job.get("concepts", []) if isinstance(job, dict) else []
        if not concepts or any(c.get("target_concept") != "style" for c in concepts):
            raise ValueError("Square symmetries require a style-only project's saved job.yaml")
    result: list[dict[str, Any]] = []
    for index, dataset in enumerate(process["datasets"]):
        if dataset.get("is_reg"):
            result.append(dataset)
            continue
        source = Path(dataset.get("dataset_path") or dataset["folder_path"])
        caption_ext = dataset.get("caption_ext", "txt").lstrip(".")
        if source.is_dir():
            entries = {
                str(file.resolve()): file.with_suffix("." + caption_ext).read_text(encoding="utf-8")
                if file.with_suffix("." + caption_ext).is_file()
                else dataset.get("default_caption", "")
                for file in sorted(source.rglob("*"))
                if file.is_file()
                and file.suffix.lower() in MEDIA_SUFFIXES
                and "training_masks" not in file.relative_to(source).parts
            }
        else:
            entries = json.loads(source.read_text(encoding="utf-8"))
        groups: dict[str, dict[str, str]] = {}
        for path, caption in entries.items():
            if not isinstance(caption, str):
                raise ValueError(
                    "Training augmentation requires text captions in native file lists"
                )
            file = Path(path)
            masked = (mask_dir / (file.stem + ".png")).is_file()
            if masked and file.suffix.lower() in VIDEO_SUFFIXES:
                raise ValueError(
                    "Spatial loss masks support still images; exclude or crop video subjects"
                )
            applied = mode
            if SIDE_WORD.search(caption):
                applied = "none"
            elif mode == "square":
                # Rotation must preserve batch dimensions. Native flips align masks, unlike RandomRotate90 replay.
                square = False
                if not masked and file.suffix.lower() not in VIDEO_SUFFIXES:
                    with Image.open(file) as image:
                        square = image.width == image.height
                if not square:
                    applied = "horizontal"
            groups.setdefault(applied, {})[path] = caption
        for applied, rows in groups.items():
            file_list = run_dir / f"training-inputs-{index}-{applied}.json"
            file_list.write_text(json.dumps(rows, ensure_ascii=False) + "\n", encoding="utf-8")
            native = copy.deepcopy(dataset)
            native.pop("dataset_path", None)
            native.update(
                folder_path=str(file_list),
                flip_x=applied == "horizontal",
                flip_y=False,
                augments=[],
                augmentations=[],
            )
            if applied == "square":
                native.update(
                    augmentations=[
                        {"method": "RandomRotate90", "params": {"p": 1.0}},
                        {"method": "HorizontalFlip", "params": {"p": 0.5}},
                    ],
                    cache_latents=False,
                    cache_latents_to_disk=False,
                )
            if has_masks:
                native.update(
                    mask_path=str(mask_dir), mask_min_value=0.0, invert_mask=False, alpha_mask=False
                )
            result.append(native)
    process["datasets"] = result
    if has_masks:
        process["train"]["inverted_mask_prior"] = False


def reject_unsupported_masks(dataset: Path, trainer: str) -> None:
    mask_dir = dataset / "training_masks"
    if mask_dir.is_dir() and any(mask_dir.glob("*.png")):
        raise ValueError(
            f"{trainer} does not support spatial loss masks; crop or exclude those samples"
        )
