"""Offline inference-boundary tests; generated test bytes are explicitly synthetic."""

import hashlib
import importlib.util
import json
import os
import runpy
import select
import signal
import subprocess
import sys
from pathlib import Path
from types import SimpleNamespace

import pytest

spec = importlib.util.spec_from_file_location(
    "generate_results", Path(__file__).parents[1] / "generate_results.py"
)
generation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(generation)
publication = runpy.run_path(str(Path(__file__).parents[1] / "push_lora.py"))


def published_source(tmp_path, monkeypatch, weights, *, declared=None, card_run="source"):
    destination = tmp_path / "runs/comparison"
    destination.mkdir(parents=True)
    repo_files = tmp_path / "published"
    repo_files.mkdir()
    files = {
        "run.json": json.dumps({"run_id": "source", "base_model": "krea/Krea-2-Raw"}).encode(),
        "config.yaml": b"job: extension\nconfig:\n  process: []\n",
        **weights,
    }
    if declared is not None:
        files["README.md"] = publication["model_card"](
            {"base_model": "krea/Krea-2-Raw"},
            run_id=card_run,
            weights=declared,
            samples=0,
            dataset={},
            version="fixture",
        ).encode()
    for name, contents in files.items():
        file = repo_files / name
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_bytes(contents)
    calls = []

    def download(repo, name, *, revision):
        calls.append((repo, name, revision))
        return str(repo_files / name)

    info = SimpleNamespace(
        sha="fixed-commit", siblings=[SimpleNamespace(rfilename=name) for name in files]
    )
    monkeypatch.setitem(
        sys.modules,
        "huggingface_hub",
        SimpleNamespace(
            HfApi=lambda: SimpleNamespace(model_info=lambda repo: info), hf_hub_download=download
        ),
    )
    request = {
        "source_run_id": "source",
        "checkpoint": "published.safetensors",
        "source": {"repo": "fixture/lora", "config": {"base_model": "krea/Krea-2-Raw"}},
    }
    return destination, request, files, calls


def test_published_source_fetches_exact_commit_without_original_storage(tmp_path, monkeypatch):
    destination, request, files, calls = published_source(
        tmp_path,
        monkeypatch,
        {"output/source/source.safetensors": b"published synthetic LoRA"},
        declared=["output/source/source.safetensors"],
    )
    generation.fetch_published_source(request, destination)
    assert (destination / "selected-checkpoint.safetensors").read_bytes() == files[
        "output/source/source.safetensors"
    ]
    assert json.loads((destination / "source-native-config.json").read_text())["job"] == "extension"
    assert request["source_revision"] == "fixed-commit"
    assert all(revision == "fixed-commit" for _, _, revision in calls)
    request["source_run_id"] = "different-run"
    with pytest.raises(ValueError, match="different training run"):
        generation.fetch_published_source(request, destination)


@pytest.mark.parametrize(
    "declared",
    [
        ["output/source/source.safetensors"],
        [
            "output/source/source_000000250.safetensors",
            "output/source/source_000000500.safetensors",
            "output/source/source.safetensors",
        ],
        # A resumed checkpoint can be newer than the final file: reuse the publisher's order.
        ["output/source/source.safetensors", "output/source/source_000000500.safetensors"],
    ],
)
def test_published_source_uses_matching_publication_among_retained_runs(
    tmp_path, monkeypatch, declared
):
    weights = {
        "output/earlier/earlier.safetensors": b"earlier run",
        "output/another/another.safetensors": b"another run",
        "output/source/source_000000250.safetensors": b"first checkpoint",
        "output/source/source_000000500.safetensors": b"resumed checkpoint",
        "output/source/source.safetensors": b"final checkpoint",
    }
    destination, request, _, calls = published_source(
        tmp_path, monkeypatch, weights, declared=declared
    )
    generation.fetch_published_source(request, destination)
    assert (destination / "selected-checkpoint.safetensors").read_bytes() == weights[declared[-1]]
    assert [name for _, name, _ in calls if name.endswith(".safetensors")] == [declared[-1]]
    assert all(revision == "fixed-commit" for _, _, revision in calls)


@pytest.mark.parametrize(
    "selected", ["source/source_000000250.safetensors", "earlier/earlier.safetensors"]
)
def test_specific_published_checkpoint_must_belong_to_current_publication(
    tmp_path, monkeypatch, selected
):
    destination, request, _, _ = published_source(
        tmp_path,
        monkeypatch,
        {
            "output/earlier/earlier.safetensors": b"earlier run",
            "output/source/source_000000250.safetensors": b"first checkpoint",
            "output/source/source.safetensors": b"final checkpoint",
        },
        declared=["output/source/source_000000250.safetensors", "output/source/source.safetensors"],
    )
    request["checkpoint"] = selected
    if selected.startswith("earlier/"):
        with pytest.raises(ValueError, match="not published for this run"):
            generation.fetch_published_source(request, destination)
        assert not (destination / "selected-checkpoint.safetensors").exists()
    else:
        generation.fetch_published_source(request, destination)
        assert (destination / "selected-checkpoint.safetensors").read_bytes() == b"first checkpoint"


@pytest.mark.parametrize(
    "invalid", ["wrong-run", "missing-weight", "duplicate-weight", "edited-card"]
)
def test_published_source_refuses_mismatched_or_ambiguous_weight_declaration(
    tmp_path, monkeypatch, invalid
):
    weight = "output/source/source.safetensors"
    declared = [weight]
    if invalid == "missing-weight":
        declared = ["output/source/missing.safetensors"]
    elif invalid == "duplicate-weight":
        declared *= 2
    destination, request, _, _ = published_source(
        tmp_path,
        monkeypatch,
        {weight: b"final checkpoint"},
        declared=declared,
        card_run="earlier" if invalid == "wrong-run" else "source",
    )
    if invalid == "edited-card":
        (tmp_path / "published/README.md").write_text("# source\n\nA custom model card.\n")
    with pytest.raises(ValueError, match="Publish this run again"):
        generation.fetch_published_source(request, destination)
    assert not (destination / "selected-checkpoint.safetensors").exists()


@pytest.mark.parametrize(
    "weight", ["output/source/source.safetensors", "output/source.safetensors"]
)
def test_older_publication_without_card_uses_only_matching_run_weight(
    tmp_path, monkeypatch, weight
):
    destination, request, _, _ = published_source(
        tmp_path,
        monkeypatch,
        {weight: b"older published LoRA", "output/earlier.safetensors": b"earlier run"},
    )
    generation.fetch_published_source(request, destination)
    assert (destination / "selected-checkpoint.safetensors").read_bytes() == b"older published LoRA"


def test_no_card_never_uses_another_runs_only_weight(tmp_path, monkeypatch):
    destination, request, _, _ = published_source(
        tmp_path, monkeypatch, {"output/earlier.safetensors": b"earlier run"}
    )
    with pytest.raises(ValueError, match="Publish this run again"):
        generation.fetch_published_source(request, destination)
    assert not (destination / "selected-checkpoint.safetensors").exists()


def test_inaccessible_published_source_has_actionable_error(tmp_path, monkeypatch):
    def unavailable(repo):
        raise OSError("403 unavailable")

    monkeypatch.setitem(
        sys.modules,
        "huggingface_hub",
        SimpleNamespace(
            HfApi=lambda: SimpleNamespace(model_info=unavailable), hf_hub_download=None
        ),
    )
    with pytest.raises(
        ValueError, match="Check Hugging Face access or use the copy saved on this Mac"
    ):
        generation.fetch_published_source({"source": {"repo": "fixture/private"}}, tmp_path)


def setup(tmp_path, monkeypatch):
    monkeypatch.setenv("PODAGENT_WORKSPACE", str(tmp_path))
    source = tmp_path / "runs/source"
    (source / "output").mkdir(parents=True)
    (source / "run.json").write_text(json.dumps({"base_model": "black-forest-labs/FLUX.1-dev"}))
    (source / "output/chosen.safetensors").write_bytes(b"synthetic checkpoint")
    target = tmp_path / "runs/comparison"
    target.mkdir()
    request = {
        "run_id": "comparison",
        "source_run_id": "source",
        "checkpoint": "chosen.safetensors",
        "prompts": ["NORA7 at a desk", "NORA7 outdoors"],
        "seeds": [42, 7],
        "width": 512,
        "height": 512,
        "inference_steps": 20,
        "guidance_scale": 4,
        "num_frames": 1,
        "frame_rate": 24,
    }
    request["checkpoint_sha256"] = hashlib.sha256(b"synthetic checkpoint").hexdigest()
    (target / "source-run.json").write_text((source / "run.json").read_text())
    (target / "selected-checkpoint.safetensors").write_bytes(b"synthetic checkpoint")
    path = target / "generation.json"
    path.write_text(json.dumps(request))
    return path, request


def test_manifest_pairs_same_exact_prompts_and_seeds_with_selected_checkpoint(
    tmp_path, monkeypatch
):
    path, request = setup(tmp_path, monkeypatch)
    calls = []

    def fake_inference(cfg, checkpoint, params, rows, out):
        calls.append((cfg, checkpoint, params))
        for row in rows:
            for key in ("base_path", "lora_path"):
                (out / row[key]).write_bytes(b"synthetic output")

    monkeypatch.setattr(generation, "flux_generate", fake_inference)
    assert generation.generate(path, "aitoolkit") == 0
    manifest = json.loads((path.parent / "output/comparison.json").read_text())
    assert manifest["state"] == "complete"
    assert [(p["prompt"], p["seed"]) for p in manifest["pairs"]] == [
        (p, s) for p in request["prompts"] for s in request["seeds"]
    ]
    assert calls[0][1].name == "selected-checkpoint.safetensors"
    assert manifest["checkpoint_sha256"] == request["checkpoint_sha256"]
    assert not calls[0][1].exists()
    assert len({p[k] for p in manifest["pairs"] for k in ("base_path", "lora_path")}) == 8


def test_missing_or_interrupted_outputs_never_report_complete(tmp_path, monkeypatch):
    path, _ = setup(tmp_path, monkeypatch)
    monkeypatch.setattr(generation, "flux_generate", lambda *args: None)
    with pytest.raises(ValueError, match="expected output files"):
        generation.generate(path, "aitoolkit")
    manifest = json.loads((path.parent / "output/comparison.json").read_text())
    assert manifest["state"] == "failed"


def test_ltx_argv_preserves_pair_settings_and_loads_lora_only_on_trained_side(tmp_path):
    encoder = tmp_path / "encoder"
    encoder.mkdir()
    model = {"model_path": str(tmp_path / "base.safetensors"), "text_encoder_path": str(encoder)}
    request = {
        "width": 512,
        "height": 512,
        "num_frames": 17,
        "frame_rate": 24,
        "inference_steps": 20,
        "guidance_scale": 4,
    }
    row = {"prompt": "NORA7 walks", "seed": 42, "base_path": "base.mp4", "lora_path": "lora.mp4"}
    cp = tmp_path / "chosen.safetensors"
    base = generation.ltx_command(model, cp, request, row, "base", tmp_path)
    trained = generation.ltx_command(model, cp, request, row, "lora", tmp_path)
    assert base[1:3] == ["-m", "ltx_pipelines.ti2vid_one_stage"]
    assert "--lora" not in base
    assert trained[-3:] == ["--lora", str(cp), "1.0"]
    for flag in (
        "--prompt",
        "--seed",
        "--width",
        "--height",
        "--num-frames",
        "--num-inference-steps",
    ):
        assert base[base.index(flag) + 1] == trained[trained.index(flag) + 1]


def test_ltx_argv_names_each_component_of_a_split_pack(tmp_path):
    model = {
        "model_path": str(tmp_path / "transformer.safetensors"),
        "text_encoder_path": str(tmp_path / "gemma4.safetensors"),
        "video_vae_path": str(tmp_path / "video-vae.safetensors"),
        "audio_vae_path": str(tmp_path / "audio-vae.safetensors"),
    }
    request = {
        "width": 512,
        "height": 512,
        "num_frames": 17,
        "frame_rate": 24,
        "inference_steps": 20,
        "guidance_scale": 4,
    }
    row = {"prompt": "NORA7 walks", "seed": 42, "base_path": "base.mp4", "lora_path": "lora.mp4"}
    argv = generation.ltx_command(model, tmp_path / "c.safetensors", request, row, "base", tmp_path)
    assert "--checkpoint-path" not in argv and "--gemma-root" not in argv
    for flag, key in (
        ("--transformer-path", "model_path"),
        ("--text-encoder-path", "text_encoder_path"),
        ("--video-vae-path", "video_vae_path"),
        ("--audio-vae-path", "audio_vae_path"),
    ):
        assert argv[argv.index(flag) + 1] == model[key]


def test_ltx_argv_keeps_a_unified_checkpoint_with_a_vae_override(tmp_path):
    encoder = tmp_path / "gemma"
    encoder.mkdir()
    model = {
        "model_path": str(tmp_path / "ltx-2.3-22b-dev.safetensors"),
        "text_encoder_path": str(encoder),
        "video_vae_path": str(tmp_path / "other-vae.safetensors"),
    }
    request = {
        "width": 512,
        "height": 512,
        "num_frames": 17,
        "frame_rate": 24,
        "inference_steps": 20,
        "guidance_scale": 4,
    }
    row = {"prompt": "NORA7 walks", "seed": 42, "base_path": "base.mp4", "lora_path": "lora.mp4"}
    argv = generation.ltx_command(model, tmp_path / "c.safetensors", request, row, "base", tmp_path)
    assert argv[argv.index("--checkpoint-path") + 1] == model["model_path"]
    assert "--transformer-path" not in argv
    assert argv[argv.index("--gemma-root") + 1] == str(encoder)
    assert argv[argv.index("--video-vae-path") + 1] == model["video_vae_path"]


def test_checkpoint_escape_fails_before_inference(tmp_path, monkeypatch):
    path, request = setup(tmp_path, monkeypatch)
    request["checkpoint"] = "../run.json"
    path.write_text(json.dumps(request))
    with pytest.raises(ValueError, match="relative"):
        generation.generate(path, "aitoolkit")
    assert not (path.parent / "output").exists()


def test_resume_replacing_original_config_and_weights_cannot_change_chosen_generation(
    tmp_path, monkeypatch
):
    path, _ = setup(tmp_path, monkeypatch)
    source = tmp_path / "runs/source"
    # Simulate a resume on another GPU after prepare, before base then LoRA sampling.
    (source / "run.json").write_text(json.dumps({"base_model": "some/different-model", "steps": 3}))
    (source / "output/chosen.safetensors").write_bytes(b"new resumed checkpoint")
    seen = []

    def fake_inference(cfg, checkpoint, params, rows, out):
        seen.append((cfg["base_model"], checkpoint.read_bytes()))
        for row in rows:
            for key in ("base_path", "lora_path"):
                (out / row[key]).write_bytes(b"synthetic output")

    monkeypatch.setattr(generation, "flux_generate", fake_inference)
    assert generation.generate(path, "aitoolkit") == 0
    manifest = json.loads((path.parent / "output/comparison.json").read_text())
    assert seen == [("black-forest-labs/FLUX.1-dev", b"synthetic checkpoint")]
    assert manifest["source_config"]["base_model"] == "black-forest-labs/FLUX.1-dev"
    assert manifest["checkpoint_sha256"] == hashlib.sha256(b"synthetic checkpoint").hexdigest()
    assert not (path.parent / "selected-checkpoint.safetensors").exists()
    assert (source / "output/chosen.safetensors").read_bytes() == b"new resumed checkpoint"


def test_changed_snapshot_fails_before_inference(tmp_path, monkeypatch):
    path, _ = setup(tmp_path, monkeypatch)
    (path.parent / "selected-checkpoint.safetensors").write_bytes(b"changed copy")
    with pytest.raises(ValueError, match="snapshot checksum changed"):
        generation.generate(path, "aitoolkit")
    assert not (path.parent / "output").exists()
    assert not (path.parent / "selected-checkpoint.safetensors").exists()


@pytest.mark.parametrize("failure", ["request", "source", "family"])
def test_early_failures_remove_private_copy_and_preserve_source(tmp_path, monkeypatch, failure):
    path, _ = setup(tmp_path, monkeypatch)
    if failure == "request":
        path.write_text("not json")
    elif failure == "source":
        (path.parent / "source-run.json").unlink()
    else:
        (path.parent / "source-run.json").write_text(json.dumps({"base_model": "unsupported"}))
    with pytest.raises((OSError, ValueError)):
        generation.generate(path, "aitoolkit")
    assert not (path.parent / "selected-checkpoint.safetensors").exists()
    assert (
        tmp_path / "runs/source/output/chosen.safetensors"
    ).read_bytes() == b"synthetic checkpoint"


def test_real_sigterm_finalizes_failed_manifest_and_keeps_partial_outputs(tmp_path, monkeypatch):
    path, _ = setup(tmp_path, monkeypatch)
    script = """
import runpy, sys, time
from pathlib import Path
module = runpy.run_path(sys.argv[1])
generate = module['generate']
def wait(cfg, checkpoint, request, rows, output):
    (output / rows[0]['base_path']).write_bytes(b'partial output')
    print('ready', flush=True)
    time.sleep(30)
generate.__globals__['flux_generate'] = wait
try:
    generate(Path(sys.argv[2]), 'aitoolkit')
except InterruptedError:
    sys.exit(1)
"""
    proc = subprocess.Popen(
        [sys.executable, "-c", script, str(Path(generation.__file__)), str(path)],
        env={**os.environ, "PODAGENT_WORKSPACE": str(tmp_path)},
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    try:
        assert select.select([proc.stdout], [], [], 5)[0], "synthetic inference did not start"
        assert proc.stdout.readline().strip() == "ready"
        proc.send_signal(signal.SIGTERM)
        proc.communicate(timeout=5)
        assert proc.returncode == 1
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.communicate(timeout=5)
    manifest = json.loads((path.parent / "output/comparison.json").read_text())
    assert manifest["state"] == "failed"
    assert (path.parent / "output/pair-000-base.png").read_bytes() == b"partial output"
    assert not (path.parent / "selected-checkpoint.safetensors").exists()
    assert (
        tmp_path / "runs/source/output/chosen.safetensors"
    ).read_bytes() == b"synthetic checkpoint"


def test_ltx_generation_uses_retained_config_without_pruned_training_inputs(tmp_path, monkeypatch):
    monkeypatch.setenv("PODAGENT_WORKSPACE", str(tmp_path))
    wrapper = generation.runpy.run_path(str(Path(generation.__file__).with_name("launch_ltx.py")))
    calls = []
    wrapper["download_hub_model"] = lambda _: None  # model preparation is outside this CPU witness
    monkeypatch.setattr(generation.runpy, "run_path", lambda _: wrapper)
    monkeypatch.setattr(generation.subprocess, "run", lambda argv, **_: calls.append(argv))
    cfg = {
        "run_id": "source",
        "dataset": {"path": str(tmp_path / "datasets/pruned")},
        "triggers": ["NORA7"],
        "base_model": "Lightricks/LTX-2.3",
        "steps": 2,
    }
    request = {
        "width": 512,
        "height": 512,
        "num_frames": 49,
        "frame_rate": 24,
        "inference_steps": 2,
        "guidance_scale": 4,
    }
    row = {"prompt": "NORA7 moves", "seed": 42, "base_path": "base.mp4", "lora_path": "lora.mp4"}
    checkpoint = tmp_path / "runs/comparison/selected-checkpoint.safetensors"
    generation.ltx_generate(cfg, checkpoint, request, [row], tmp_path)
    assert len(calls) == 2
    assert "--lora" not in calls[0] and str(checkpoint) in calls[1]
    assert not Path(cfg["dataset"]["path"]).exists()  # no restore/pull for inference


def test_musubi_krea2_renders_both_sides_on_the_rows_generation_weights(tmp_path, monkeypatch):
    """Turbo built twice (plain, then with the LoRA merged), the request's settings, Turbo's mu."""
    import argparse
    import types

    monkeypatch.setenv("PODAGENT_WORKSPACE", str(tmp_path))
    wrapper = generation.runpy.run_path(
        str(Path(generation.__file__).with_name("launch_musubi.py"))
    )
    downloads, builds, renders = [], [], []
    wrapper["download_weights"] = lambda cfg, row, roles: downloads.append(roles)
    monkeypatch.setattr(generation.runpy, "run_path", lambda _: wrapper)

    def parse_args():
        parser = argparse.ArgumentParser()
        for flag in ("--dit", "--vae", "--text_encoder", "--save_path"):
            parser.add_argument(flag)
        parser.add_argument("prompt")
        return argparse.Namespace(
            **vars(parser.parse_args(sys.argv[1:])),
            device="cuda", attn_mode="torch", steps=28, guidance_scale=5.5, mu=None,
        )  # fmt: skip

    class Image:
        def save(self, path):
            Path(path).write_bytes(b"synthetic output")

    def build_pipeline(dit, vae, **options):
        builds.append((dit, options["lora_weights"]))
        return object(), object()

    def generate(args, dit, ae, encoder, device, dtype, te_device):
        renders.append(vars(args).copy())
        return [Image()]

    krea2 = types.SimpleNamespace(
        parse_args=parse_args,
        load_text_encoder=lambda path, dtype: object(),
        build_pipeline=build_pipeline,
        apply_overrides=lambda args, overrides: argparse.Namespace(**{**vars(args), **overrides}),
        generate=generate,
    )
    package = types.ModuleType("musubi_tuner")
    package.krea2_generate_image = krea2
    fake_torch = types.SimpleNamespace(
        bfloat16="bf16", cuda=types.SimpleNamespace(empty_cache=lambda: None)
    )
    monkeypatch.setitem(sys.modules, "musubi_tuner", package)
    monkeypatch.setitem(sys.modules, "musubi_tuner.krea2_generate_image", krea2)
    monkeypatch.setitem(sys.modules, "torch", fake_torch)

    cfg = {"base_model": "krea/Krea-2-Raw", "sample_every": 0, "sample_prompts": []}
    request = {"width": 1024, "height": 1024, "inference_steps": 8, "guidance_scale": 1.0}
    rows = generation.pairs({"prompts": ["NORA7 at a desk"], "seeds": [42, 7]}, "musubi")
    checkpoint = tmp_path / "runs/comparison/selected-checkpoint.safetensors"
    generation.musubi_krea2_generate(cfg, checkpoint, request, rows, tmp_path)

    assert downloads == [("sample_dit", "vae", "text_encoder")]
    turbo = str(tmp_path / "models/huggingface/krea/Krea-2-Turbo/turbo.safetensors")
    assert builds == [(turbo, None), (turbo, [str(checkpoint)])]
    assert [
        (r["prompt"], r["seed"], r["steps"], r["guidance_scale"], r["mu"]) for r in renders
    ] == [("NORA7 at a desk", seed, 8, 1.0, 1.15) for seed in (42, 7)] * 2
    assert all((tmp_path / row[key]).read_bytes() == b"synthetic output"
               for row in rows for key in ("base_path", "lora_path"))  # fmt: skip
    assert rows[0]["base_path"].endswith(".png")


@pytest.mark.parametrize("scoring_fails", [False, True])
def test_style_report_preserves_renders_and_records_actual_scores_or_error(
    tmp_path, monkeypatch, scoring_fails
):
    path, request = setup(tmp_path, monkeypatch)
    request["style_references"] = {"upload": "style-one", "groups": {"STYLE7": ["reference.png"]}}
    path.write_text(json.dumps(request))

    def inference(cfg, checkpoint, params, rows, out):
        for row in rows:
            for key in ("base_path", "lora_path"):
                (out / row[key]).write_bytes(b"synthetic output")

    def scores(groups, references, outputs, workspace):
        assert groups == {"STYLE7": ["reference.png"]}
        assert references == path.parent / "style-references"
        if scoring_fails:
            raise ValueError("synthetic unavailable encoder")
        return {
            "method": "test-only",
            "scores": {output.name: {"STYLE7": 0.75} for output in outputs},
        }

    original = generation.runpy.run_path

    def helper(file):
        return (
            {"score_outputs": scores}
            if str(file).endswith("style_embedding.py")
            else original(file)
        )

    monkeypatch.setattr(generation, "flux_generate", inference)
    monkeypatch.setattr(generation.runpy, "run_path", helper)
    assert generation.generate(path, "aitoolkit") == 0
    manifest = json.loads((path.parent / "output/comparison.json").read_text())
    assert manifest["state"] == "complete"
    if scoring_fails:
        assert "style" not in manifest
        assert "synthetic unavailable encoder" in manifest["style_error"]
    else:
        assert manifest["style"]["scores"]["pair-000-lora.png"]["STYLE7"] == 0.75
        assert "style_error" not in manifest
