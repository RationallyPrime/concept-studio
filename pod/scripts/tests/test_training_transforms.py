"""App-shaped mask metadata survives installation; native training sees targets, never masks."""

import importlib.util
import json
import sys
from pathlib import Path

import pytest
from PIL import Image


def load(name):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).parents[1] / f"{name}.py")
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


pull = load("pull_dataset")
wrapper = load("launch_aitoolkit")
transforms = load("training_transforms")


def png(path, size=(32, 32)):
    path.parent.mkdir(parents=True, exist_ok=True)
    Image.new("RGB", size, "white").save(path)


@pytest.mark.parametrize("flat", [False, True])
@pytest.mark.parametrize("model", ["black-forest-labs/FLUX.1-dev", "Comfy-Org/MiniMax-H3"])
def test_mask_publication_or_flat_upload_reaches_native_trainer(tmp_path, monkeypatch, flat, model):
    monkeypatch.setenv("PODAGENT_WORKSPACE", str(tmp_path))
    source = tmp_path / "source"
    png(source / "photo.png")
    mask_name = "training-mask-70686f746f.png" if flat else "training_masks/photo.png"
    png(source / mask_name)
    (source / "metadata.jsonl").write_text(
        json.dumps(
            {
                "file_name": "photo.png",
                "caption": "PERSON8 outdoors",
                "training_mask": mask_name,
            }
        )
        + "\n"
    )
    entries = pull.collect_imagefolder(source, split=None, caption_column="caption")
    assert len(entries) == 1
    installed = tmp_path / "datasets/subject"
    pull.write_entries(entries, installed)
    assert (installed / "training_masks/photo.png").read_bytes() == (
        source / mask_name
    ).read_bytes()
    run = tmp_path / "runs/test"
    run.mkdir(parents=True)
    cfg = wrapper.validate_run_config(
        {
            "run_id": "test",
            "base_model": model,
            "dataset": {"path": str(installed)},
            "triggers": ["PERSON8"],
            "augmentation": "horizontal",
        },
        tmp_path,
    )
    process = wrapper.build_native_config(cfg, run)["config"]["process"][0]
    assert process["train"]["inverted_mask_prior"] is False
    dataset = process["datasets"][0]
    assert dataset["mask_path"] == str(installed / "training_masks")
    assert dataset["mask_min_value"] == 0
    assert dataset["flip_x"] is True
    assert list(json.loads(Path(dataset["folder_path"]).read_text())) == [
        str(installed / "photo.png")
    ]


def test_side_captions_never_flip_and_square_mode_does_not_rotate_masks_or_rectangles(tmp_path):
    root = tmp_path / "dataset"
    root.mkdir()
    captions = {
        "square": "STYLE8 bright sky",
        "left": "STYLE8 on the LEFT.",
        "right": "STYLE8 to the right",
        "masked": "STYLE8 scene",
        "wide": "STYLE8 landscape",
    }
    for name, caption in captions.items():
        png(root / (name + ".png"), (64, 32) if name == "wide" else (32, 32))
        (root / (name + ".txt")).write_text(caption)
    png(root / "training_masks/masked.png")
    (root / "job.yaml").write_text("concepts:\n- trigger: STYLE8\n  target_concept: style\n")
    process = {"datasets": [{"folder_path": str(root), "cache_latents_to_disk": True}], "train": {}}
    transforms.native_transforms(
        {"dataset": {"path": str(root)}, "augmentation": "square"}, tmp_path, process
    )
    by_names = {
        tuple(sorted(Path(p).stem for p in json.loads(Path(d["folder_path"]).read_text()))): d
        for d in process["datasets"]
    }
    still = by_names[("left", "right")]
    assert not still["flip_x"] and not still["flip_y"] and still["augmentations"] == []
    assert by_names[("masked", "wide")]["flip_x"] is True
    square = by_names[("square",)]
    assert [a["method"] for a in square["augmentations"]] == ["RandomRotate90", "HorizontalFlip"]
    assert square["cache_latents_to_disk"] is False
    assert not list(tmp_path.glob("*.png"))


def test_square_mode_refuses_person_job_and_other_trainers_refuse_masks(tmp_path):
    png(tmp_path / "training_masks/photo.png")
    (tmp_path / "job.yaml").write_text(
        "concepts:\n- trigger: PERSON8\n  target_concept: facial_identity\n"
    )
    with pytest.raises(ValueError, match="style-only"):
        transforms.native_transforms(
            {"dataset": {"path": str(tmp_path)}, "augmentation": "square"}, tmp_path, {}
        )
    for name in ("launch_ltx", "launch_musubi"):
        trainer = load(name)
        with pytest.raises(trainer.ConfigError, match="does not support spatial loss masks"):
            trainer.build_dataset_entries(tmp_path, "txt")


def test_class_set_drops_subject_transform_and_mask_inheritance(tmp_path):
    process = {
        "datasets": [
            {
                "folder_path": "subjects",
                "flip_x": True,
                "flip_y": True,
                "augmentations": [{"method": "RandomRotate90"}],
                "augments": ["legacy"],
                "mask_path": "subject-masks",
                "mask_min_value": 0,
            }
        ],
        "train": {},
    }
    wrapper.add_regularization_dataset(process, tmp_path)
    reg = process["datasets"][-1]
    assert not reg["flip_x"] and not reg["flip_y"]
    assert not reg["augmentations"] and not reg["augments"] and reg["mask_path"] is None
