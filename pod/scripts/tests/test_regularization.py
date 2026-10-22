"""Class-set admission, final native datasets and base-only H3 drawing; no GPU or network."""

import importlib.util
import sys
from contextlib import nullcontext
from pathlib import Path
from types import SimpleNamespace

import pytest


def load(name):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).parents[1] / f"{name}.py")
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


table = load("model_table")
regularization = load("regularization")
wrapper = load("launch_aitoolkit")
generation = load("generate_results")


def test_all_rows_declare_their_prior_preservation_support():
    rows = table.models()
    assert len(rows) == 25
    for row in rows:
        offer = row["regularization"]
        assert offer["mode"] in {"generate", "folder", "unsupported"}
        assert offer["note"]
        assert table.supports_regularization(row, "folder") == (row["trainer"] == "aitoolkit")
        assert table.supports_regularization(row, "generate") == (offer["mode"] == "generate")
    assert {r["id"] for r in rows if r["regularization"]["default_on"]} == {
        "flux1-dev",
        "z-image",
        "qwen-image-2.1",
        "minimax-h3",
    }


@pytest.mark.parametrize("model", ["Comfy-Org/MiniMax-H3", "black-forest-labs/FLUX.1-dev"])
def test_regularization_survives_final_custom_or_generic_dataset_config(
    tmp_path, monkeypatch, model
):
    monkeypatch.setenv("PODAGENT_WORKSPACE", str(tmp_path))
    subjects = tmp_path / "datasets/subjects"
    subjects.mkdir(parents=True)
    (subjects / "one.png").write_bytes(b"synthetic image boundary")
    (subjects / "one.txt").write_text("NORA7 in a park")
    classes = tmp_path / "datasets/classes"
    classes.mkdir()
    (classes / "one.png").write_bytes(b"synthetic class boundary")
    (classes / "one.txt").write_text("A person in a park")
    run = tmp_path / "runs/test"
    run.mkdir(parents=True)
    cfg = wrapper.validate_run_config(
        {
            "run_id": "test",
            "base_model": model,
            "dataset": {"path": str(subjects)},
            "triggers": ["NORA7"],
            "regularization": {"source": "folder", "path": str(classes), "weight": 0.7},
        },
        tmp_path,
    )
    assert wrapper.prepare_regularization(cfg, run) == 0
    process = wrapper.build_native_config(cfg, run)["config"]["process"][0]
    assert process["train"]["reg_weight"] == 0.7
    reg = [dataset for dataset in process["datasets"] if dataset.get("is_reg")]
    assert len(reg) == 1
    assert reg[0]["folder_path"] == str(run / "regularization")
    assert reg[0]["num_frames"] == 1 and reg[0]["do_audio"] is False
    assert reg[0]["cache_latents_to_disk"] == process["datasets"][0]["cache_latents_to_disk"]
    assert (run / "regularization/one.txt").read_text().strip() == "A person in a park"


def test_video_caption_supplies_a_still_class_prompt(tmp_path):
    (tmp_path / "one.mp4").write_bytes(b"synthetic video boundary")
    (tmp_path / "one.txt").write_text("NORA7 walks through a park.")
    prompts = regularization.subject_prompts(
        {
            "dataset": {"path": str(tmp_path), "caption_ext": "txt"},
            "regularization": {"class_nouns": {"NORA7": "person"}},
        },
        512,
        lambda *args: pytest.fail(str(args)),
    )
    assert len(prompts) == 1 and "NORA7" not in prompts[0]["prompt"]
    assert prompts[0]["width"] == prompts[0]["height"] == 512


def test_h3_class_drawing_uses_pinned_base_assets_without_training_adapter(tmp_path, monkeypatch):
    calls = {}

    class Config:
        def __init__(self, **kwargs):
            self.__dict__.update(kwargs)

    class Model:
        @staticmethod
        def get_train_scheduler():
            return "scheduler"

        def __init__(self, **kwargs):
            calls["model"] = kwargs["model_config"]

        def load_model(self):
            pass

        def generate_images(self, configs, sampler):
            calls["images"] = configs

    monkeypatch.setenv("PODAGENT_WORKSPACE", str(tmp_path))
    monkeypatch.setitem(
        sys.modules,
        "torch",
        SimpleNamespace(no_grad=nullcontext, cuda=SimpleNamespace(empty_cache=lambda: None)),
    )
    monkeypatch.setitem(
        sys.modules,
        "toolkit.config_modules",
        SimpleNamespace(ModelConfig=Config, GenerateImageConfig=Config),
    )
    monkeypatch.setitem(
        sys.modules, "toolkit.util.get_model", SimpleNamespace(get_model_class=lambda _: Model)
    )
    monkeypatch.setitem(
        sys.modules, "toolkit.sampler", SimpleNamespace(get_sampler=lambda *args, **kwargs: None)
    )
    rules = load("h3_recipe")
    real_run_path = generation.runpy.run_path

    def run_path(path):
        if str(path).endswith("h3_recipe.py"):
            return {
                "model_config": rules.model_config,
                "download_assets": lambda workspace, **kwargs: calls.update(download=kwargs),
            }
        return real_run_path(path)

    monkeypatch.setattr(generation.runpy, "run_path", run_path)
    generation.render_base(
        "Comfy-Org/MiniMax-H3",
        [
            {
                "prompt": "A person in a park",
                "seed": 1,
                "width": 512,
                "height": 512,
                "steps": 28,
                "guidance_scale": 1.0,
                "path": "one.png",
            }
        ],
        tmp_path,
    )
    assert calls["download"] == {"training_adapter": None}
    assert calls["model"].model_kwargs["partition"] == "fl2va_pruned"
    assert not hasattr(calls["model"], "assistant_lora_path")
    assert calls["images"][0].num_frames == 1
    assert calls["images"][0].output_ext == "png"


def test_class_images_do_not_inherit_subject_loss_masks(tmp_path):
    process = {
        "datasets": [
            {
                "folder_path": "subjects",
                "mask_path": "subject-masks",
                "alpha_mask": True,
                "invert_mask": True,
            }
        ]
    }
    wrapper.add_regularization_dataset(process, tmp_path)
    classes = process["datasets"][-1]
    assert classes["mask_path"] is None
    assert classes["alpha_mask"] is False and classes["invert_mask"] is False
    assert process["datasets"][0]["mask_path"] == "subject-masks"
