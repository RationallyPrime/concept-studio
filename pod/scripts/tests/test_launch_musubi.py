"""Tests for scripts/launch_musubi.py (POD-SPEC §4.3).

No GPU, no musubi-tuner, no network: weight downloads and the cache and trainer commands are
replaced, the TensorBoard writer by a recording fake. The block it shares with the other launchers
is tested in test_launch_wrappers.py.
"""

from __future__ import annotations

import importlib.util
import io
import json
import sys
from pathlib import Path
from types import ModuleType
from typing import Any

import pytest

SCRIPTS = Path(__file__).resolve().parents[1]
RUN_ID = "nora7-k2-001"
KREA = "krea/Krea-2-Raw"


def load_script(name: str) -> ModuleType:
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / f"{name}.py")
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


musubi = load_script("launch_musubi")
ROW = musubi._TABLE["exact_row"](KREA, "musubi")


@pytest.fixture
def workspace(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    """datasets/faces: two captioned images (one in a subfolder), one without, and a note."""
    root = tmp_path.resolve() / "workspace"
    dataset = root / "datasets" / "faces"
    (dataset / "more").mkdir(parents=True)
    (dataset / "0001.png").write_bytes(b"\x89PNG\r\n\x1a\n")
    (dataset / "0001.txt").write_text("NORA7, a woman, smiling\n", encoding="utf-8")
    (dataset / "more" / "0002.jpg").write_bytes(b"\xff\xd8\xff")
    (dataset / "more" / "0002.txt").write_text("NORA7, a woman, outdoors", encoding="utf-8")
    (dataset / "0003.png").write_bytes(b"\x89PNG\r\n\x1a\n")
    (dataset / "notes.md").write_text("not an image", encoding="utf-8")
    (root / "runs" / RUN_ID).mkdir(parents=True)
    monkeypatch.setenv("PODAGENT_WORKSPACE", str(root))
    return root


def run_config(workspace: Path, **overrides: Any) -> dict[str, Any]:
    cfg: dict[str, Any] = {
        "run_id": RUN_ID,
        "dataset": {"path": str(workspace / "datasets" / "faces"), "caption_ext": "txt"},
        "triggers": ["NORA7"],
        "profile": "plain",
        "base_model": KREA,
        "steps": 2000,
        "learning_rate": 0.0001,
        "rank": 32,
        "alpha": 32,
        "resolution": 1024,
        "batch_size": 1,
        "gradient_accumulation": 1,
        "seed": 42,
        "save_every": 100,
        "sample_every": 100,
        "sample_prompts": ["NORA7 -- a portrait"],
        "hub": None,
        "extra": {},
    }
    cfg.update(overrides)
    return cfg


def write_run_json(workspace: Path, cfg: dict[str, Any]) -> Path:
    path = workspace / "runs" / RUN_ID / "run.json"
    path.write_text(json.dumps(cfg), encoding="utf-8")
    return path


def flags(argv: list[str]) -> dict[str, str | bool]:
    """``--name value`` / ``--switch`` pairs after the training script in a trainer argv."""
    start = next(i for i, a in enumerate(argv) if a.endswith("_train_network.py")) + 1
    out: dict[str, str | bool] = {}
    for i, item in enumerate(argv[start:], start):
        if item.startswith("--"):
            nxt = argv[i + 1] if i + 1 < len(argv) else None
            out[item[2:]] = nxt if nxt is not None and not nxt.startswith("--") else True
    return out


def plan(workspace: Path, **overrides: Any) -> tuple[Path, dict[str, Any], list[str]]:
    path = write_run_json(workspace, run_config(workspace, **overrides))
    run_dir, cfg = musubi.load_run(path, restore_missing_dataset=False)
    row = musubi.check_musubi_run(cfg)
    return run_dir, cfg, musubi.trainer_argv(run_dir, cfg, row)


def test_row_is_the_measured_recipe() -> None:
    assert ROW["trainer"] == "musubi" and ROW["architecture"]["arch"] == "krea2"
    assert set(ROW["trainer_options"]["weights"]) == {"dit", "sample_dit", "vae", "text_encoder"}
    assert ROW["recipe"]["caption_dropout"] is None
    assert musubi._TABLE["trainer_resumes"]("musubi") is False


def test_trainer_argv_is_the_recipe(workspace: Path) -> None:
    run_dir, _, argv = plan(workspace)
    assert argv[:7] == [
        sys.executable, "-m", "accelerate.commands.launch",
        "--num_cpu_threads_per_process", "1", "--mixed_precision", "bf16",
    ]  # fmt: skip
    assert argv[7].endswith("/src/musubi_tuner/krea2_train_network.py")
    models = workspace / "models" / "huggingface"
    assert flags(argv) == {
        "sdpa": True,
        "mixed_precision": "bf16",
        "timestep_sampling": "krea2_shift",
        "weighting_scheme": "none",
        "network_module": "networks.lora_krea2",
        "max_data_loader_n_workers": "2",
        "persistent_data_loader_workers": True,
        "dit": str(models / "krea/Krea-2-Raw/raw.safetensors"),
        "vae": str(models / "krea/Krea-2-Raw/vae/diffusion_pytorch_model.safetensors"),
        "text_encoder": str(models / "krea/Krea-2-Raw/text_encoder/model.safetensors"),
        "dataset_config": str(run_dir / "dataset.toml"),
        "optimizer_type": "AdamW",
        "lr_scheduler": "constant",
        "learning_rate": "0.0001",
        "network_dim": "32",
        "network_alpha": "32",
        "gradient_accumulation_steps": "1",
        "max_train_steps": "2000",
        "save_every_n_steps": "100",
        "seed": "42",
        "output_dir": str(run_dir / "output"),
        "output_name": RUN_ID,
        "logging_dir": str(run_dir / "tensorboard"),
        "log_with": "tensorboard",
        "turbo_dit_cache": True,
        "turbo_dit": str(models / "krea/Krea-2-Turbo/turbo.safetensors"),
        "sample_prompts": str(run_dir / "sample_prompts.txt"),
        "sample_every_n_steps": "100",
        "sample_at_first": True,
    }


def test_without_samples_the_sample_model_is_left_out(workspace: Path) -> None:
    _, cfg, argv = plan(workspace, sample_every=0)
    assert not {"turbo_dit", "turbo_dit_cache", "sample_prompts"} & set(flags(argv))
    assert set(musubi.weight_paths(cfg, ROW)) == {"dit", "vae", "text_encoder"}


def test_extra_args_override_the_row(workspace: Path) -> None:
    extra = {"args": {"optimizer_type": "AdamW8bit", "sdpa": False, "fp8_base": True}}
    _, _, argv = plan(workspace, extra=extra)
    got = flags(argv)
    assert got["optimizer_type"] == "AdamW8bit" and got["fp8_base"] is True
    assert "sdpa" not in got


def test_dry_run_writes_dataset_files(workspace: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(musubi, "download_weights", lambda *_: pytest.fail("dry run downloaded"))
    path = write_run_json(workspace, run_config(workspace, resolution=[768, 1024]))
    assert musubi.main(["--config", str(path), "--dry-run"]) == 0
    run_dir = path.parent
    lines = (run_dir / "dataset.jsonl").read_text(encoding="utf-8").splitlines()
    assert [json.loads(line) for line in lines] == [
        {"image_path": str(workspace / "datasets/faces/0001.png"), "caption": "NORA7, a woman, smiling"},
        {"image_path": str(workspace / "datasets/faces/more/0002.jpg"), "caption": "NORA7, a woman, outdoors"},
    ]  # fmt: skip
    toml = (run_dir / "dataset.toml").read_text(encoding="utf-8")
    assert toml.count("[[datasets]]") == 2
    assert "resolution = [768, 768]" in toml and "resolution = [1024, 1024]" in toml
    assert f'cache_directory = "{run_dir / "cache" / "768"}"' in toml
    # The prompt's own `--` would start a musubi option; samples are drawn at the largest size.
    assert (run_dir / "sample_prompts.txt").read_text(encoding="utf-8") == (
        "NORA7 - a portrait --w 1024 --h 1024 --s 8 --l 1 --d 42\n"
    )


@pytest.mark.parametrize(
    ("overrides", "reason"),
    [
        ({"resume": True}, "cannot continue a run"),
        ({"caption_dropout": 0.1}, "AI Toolkit settings"),
        ({"regularization": {"source": "folder"}}, "regularization/repa"),
        ({"extra": {"train": {}}}, "holds only args"),
        ({"extra": {"args": {"output_dir": "x"}}}, "the wrapper sets this"),
        (
            {"base_model": "black-forest-labs/FLUX.1-dev"},
            "musubi-tuner trains krea/Krea-2-Raw only",
        ),
    ],
)
def test_refusals_write_nothing(
    workspace: Path, capsys: pytest.CaptureFixture[str], overrides: dict[str, Any], reason: str
) -> None:
    path = write_run_json(workspace, run_config(workspace, **overrides))
    assert musubi.main(["--config", str(path), "--dry-run"]) == 2
    assert reason in capsys.readouterr().out
    assert sorted(p.name for p in path.parent.iterdir()) == ["run.json"]


def test_images_sharing_a_name_are_refused(workspace: Path) -> None:
    dataset = workspace / "datasets" / "faces"
    (dataset / "more" / "0001.jpg").write_bytes(b"\xff\xd8\xff")
    (dataset / "more" / "0001.txt").write_text("NORA7", encoding="utf-8")
    with pytest.raises(musubi.ConfigError, match="share a name: 0001"):
        musubi.build_dataset_entries(dataset, "txt")


def test_failed_download_exits_69_before_any_run_file(
    workspace: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    def refuse(*_: Any) -> None:
        raise OSError("gated repo")

    monkeypatch.setattr(musubi, "download_weights", refuse)
    path = write_run_json(workspace, run_config(workspace))
    assert musubi.main(["--config", str(path)]) == musubi.EXIT_MODEL_PREPARATION
    assert sorted(p.name for p in path.parent.iterdir()) == ["run.json"]


def test_scraper_reads_musubi_loss() -> None:
    scraper = musubi.MusubiLogScraper()
    line = "steps:  10%|█         | 200/2000 [01:00<09:00,  3.33it/s, avr_loss=0.0123]"
    assert scraper.feed(line) == [("scraped/loss", 200, 0.0123)]


def test_run_scrapes_and_moves_samples(workspace: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    """The whole run with stand-ins: caches, a trainer that saves and samples, then the samples move."""
    writer_scalars: list[tuple[str, float, int]] = []

    class Writer:
        def add_scalar(self, tag: str, value: float, step: int) -> None:
            writer_scalars.append((tag, value, step))

        def flush(self) -> None: ...

        def close(self) -> None: ...

    monkeypatch.setattr(musubi, "download_weights", lambda *_: None)
    monkeypatch.setattr(musubi, "open_writer", lambda _: Writer())
    monkeypatch.setattr(
        musubi, "cache_argv", lambda *_: [[sys.executable, "-c", "print('cached')"]]
    )
    trainer = (
        "import pathlib; o = pathlib.Path('output'); (o / 'sample').mkdir(parents=True);"
        f"(o / 'sample' / '{RUN_ID}_000100_00.png').write_bytes(b'x');"
        f"(o / '{RUN_ID}-step00000100.safetensors').write_bytes(b'x');"
        "print('steps:  5%| | 100/2000 [00:30<09:00, 3.3it/s, avr_loss=0.25]')"
    )
    monkeypatch.setattr(musubi, "trainer_argv", lambda *_: [sys.executable, "-c", trainer])
    monkeypatch.setattr(sys, "stdout", io.StringIO())
    path = write_run_json(workspace, run_config(workspace))
    assert musubi.main(["--config", str(path)]) == 0
    output = path.parent / "output"
    assert sorted(p.name for p in output.iterdir()) == [
        f"{RUN_ID}-step00000100.safetensors",
        "samples",
    ]
    assert (output / "samples" / f"{RUN_ID}_000100_00.png").is_file()
    assert writer_scalars == [("scraped/loss", 0.25, 100)]
