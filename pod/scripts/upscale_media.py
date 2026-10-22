#!/usr/bin/env python3
"""Upscale and restore training images and clips with SeedVR2 on the pod's GPU.

    upscale_media.py --run RUN_DIR   # the upscale-media service (GPU)

The app uploads the images and clips the person chose to a staging folder; the agent moves them to
``<run>/inputs/`` and writes the service's params to ``<run>/upscale.json``:

    {"run_id": "upscale-3f2a9c1e7b40", "upload": "upscale-3f2a9c1e7b40", "model": "3b",
     "resolution": 1024, "max_resolution": 2048, "seed": 42}

Each input becomes ``<run>/output/<stem>.png`` (an image) or ``<run>/output/<stem>.mp4`` (a clip),
where the agent's file routes serve it. ``resolution`` is the short side of the result and
``max_resolution`` caps its longer side; the aspect ratio is kept. A clip keeps its frame rate, its
frame count and its original audio track. SeedVR2 is a video restoration model, so an image is a
one-frame video.

The work is done by the SeedVR2 command line of numz/ComfyUI-SeedVR2_VideoUpscaler (Apache-2.0),
checked out at ``/opt/seedvr2`` in its own venv (``/opt/venvs/seedvr2``). Its weights download on
first use, with SHA-256 checks, to ``<workspace>/models/seedvr2`` on the network volume, so a
second pod on the same storage does not download them again. Images run as one directory pass with
the models kept loaded; each clip runs on its own, then has its audio put back with ffmpeg and its
frame count checked against the input.

Memory settings follow the GPU's memory (``memory_flags``): large cloud GPUs run the FP16 model as
it is; smaller ones tile the VAE and, below 24 GiB, swap transformer blocks to system memory
(BlockSwap, which only exists on CUDA hosts).

Prints ``[upscale] ready k/N`` as results land and ``[upscale] failed <name>: <reason>`` for an
input that produced no usable result, which the app reads from the log. Exit codes: 0 when at
least one result was written, 2 bad input (nothing was run), 1 when every input failed.

Standard library only; the SeedVR2 command line runs as a child process.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

PREFIX = Path(os.environ.get("PODAGENT_PREFIX", "/opt"))
CLI = PREFIX / "seedvr2" / "inference_cli.py"
PYTHON = PREFIX / "venvs" / "seedvr2" / "bin" / "python"
PARAMS_FILE = "upscale.json"
INPUT_DIR = "inputs"
OUTPUT_DIR = "output"  # what the agent serves from a run directory
WORK_DIR = "work"
# The FP16 weights of the two SeedVR2 sizes, as the command line names them.
MODELS = {"3b": "seedvr2_ema_3b_fp16.safetensors", "7b": "seedvr2_ema_7b_fp16.safetensors"}
# BlockSwap block counts that keep the FP16 transformer within a small GPU (the CLI allows 0-32 for
# 3B, 0-36 for 7B).
SWAP_BLOCKS = {"3b": 16, "7b": 24}
IMAGE_SUFFIXES = frozenset({".png", ".jpg", ".jpeg", ".webp"})
CLIP_SUFFIXES = frozenset({".mp4", ".mov", ".m4v"})
# Frames per clip batch: SeedVR2 needs 4n+1, and longer batches are more consistent over time.
# VERIFY on a pod: 21 frames at 1024 px on a 32 GB GPU with VAE tiling.
CLIP_BATCH = 21
CLIP_OVERLAP = 4
POLL_SECONDS = 2.0
SMALL_GPU_GIB = 24
TILED_VAE_BELOW_GIB = 48

EXIT_BAD_INPUT = 2
EXIT_FAILED = 1


def say(message: str) -> None:
    print(f"[upscale] {message}", flush=True)


def load_params(run_dir: Path) -> dict[str, Any]:
    params = json.loads((run_dir / PARAMS_FILE).read_text(encoding="utf-8"))
    if params.get("model") not in MODELS:
        raise ValueError(f"model must be one of {', '.join(sorted(MODELS))}")
    for key in ("resolution", "max_resolution", "seed"):
        if not isinstance(params.get(key), int) or isinstance(params.get(key), bool):
            raise ValueError(f"{key} must be an integer")
    return params


def split_inputs(folder: Path) -> tuple[list[Path], list[Path]]:
    """The staged images and clips, each sorted by name; anything else is bad input."""
    files = sorted((p for p in folder.iterdir() if p.is_file()), key=lambda p: p.name.encode())
    images = [p for p in files if p.suffix.lower() in IMAGE_SUFFIXES]
    clips = [p for p in files if p.suffix.lower() in CLIP_SUFFIXES]
    others = [p.name for p in files if p not in images and p not in clips]
    if others:
        raise ValueError(f"not an image or clip: {', '.join(others)}")
    stems = [p.stem for p in files]
    if len(set(stems)) != len(stems):
        raise ValueError("two inputs share a name; each result is named after its input")
    if not files:
        raise ValueError("no images or clips were uploaded")
    return images, clips


def gpu_memory_gib() -> float | None:
    """Total memory of the GPU this service was given, from nvidia-smi; None when unreadable."""
    visible = os.environ.get("CUDA_VISIBLE_DEVICES", "0").split(",")[0].strip() or "0"
    try:
        out = subprocess.run(
            [
                "nvidia-smi",
                "-i",
                visible,
                "--query-gpu=memory.total",
                "--format=csv,noheader,nounits",
            ],
            capture_output=True,
            text=True,
            check=True,
            timeout=30,
        ).stdout
        return float(out.strip().splitlines()[0]) / 1024
    except (OSError, subprocess.SubprocessError, ValueError, IndexError):
        return None


def memory_flags(total_gib: float | None, model: str) -> list[str]:
    """SeedVR2's memory savings for a GPU of ``total_gib``; unknown memory gets the safe settings."""
    flags: list[str] = []
    if total_gib is None or total_gib < TILED_VAE_BELOW_GIB:
        flags += ["--vae_encode_tiled", "--vae_decode_tiled"]
    if total_gib is None or total_gib < SMALL_GPU_GIB:
        flags += ["--blocks_to_swap", str(SWAP_BLOCKS[model]), "--swap_io_components"]
    return flags


def cli_argv(
    source: Path,
    output: Path,
    params: dict[str, Any],
    workspace: Path,
    *,
    clip: bool,
    memory: list[str],
) -> list[str]:
    argv = [
        str(PYTHON),
        str(CLI),
        str(source),
        "--output",
        str(output),
        "--model_dir",
        str(workspace / "models" / "seedvr2"),
        "--dit_model",
        MODELS[params["model"]],
        "--resolution",
        str(params["resolution"]),
        "--max_resolution",
        str(params["max_resolution"]),
        "--seed",
        str(params["seed"]),
        "--color_correction",
        "lab",
        # Idle models wait in system memory; required for BlockSwap and for keeping them loaded.
        "--dit_offload_device",
        "cpu",
        "--vae_offload_device",
        "cpu",
    ]
    if clip:
        argv += [
            "--batch_size",
            str(CLIP_BATCH),
            "--temporal_overlap",
            str(CLIP_OVERLAP),
            "--uniform_batch_size",
            "--video_backend",
            "ffmpeg",
            "--output_format",
            "mp4",
        ]
    else:
        argv += ["--batch_size", "1", "--output_format", "png", "--cache_dit", "--cache_vae"]
    return argv + memory


def run_cli(argv: list[str], *, watch: Path | None = None, ready: int = 0, total: int = 0) -> int:
    """Run the command line with its output in this log; report finished images while it runs."""
    process = subprocess.Popen(argv, stdin=subprocess.DEVNULL)
    seen = 0
    while process.poll() is None:
        time.sleep(POLL_SECONDS)
        if watch is not None and watch.is_dir():
            count = sum(1 for p in watch.iterdir() if p.suffix == ".png")
            if count != seen:
                seen = count
                say(f"ready {ready + count}/{total}")
    return process.returncode


def frame_count(path: Path) -> int | None:
    try:
        out = subprocess.run(
            [
                "ffprobe",
                "-v",
                "error",
                "-select_streams",
                "v:0",
                "-count_packets",
                "-show_entries",
                "stream=nb_read_packets",
                "-of",
                "csv=p=0",
                str(path),
            ],
            capture_output=True,
            text=True,
            check=True,
            timeout=600,
        ).stdout
        return int(out.strip().splitlines()[0])
    except (OSError, subprocess.SubprocessError, ValueError, IndexError):
        return None


def with_original_audio(video: Path, original: Path, target: Path) -> None:
    """The restored picture with the original clip's audio (if it has any), video stream copied."""
    subprocess.run(
        [
            "ffmpeg",
            "-nostdin",
            "-y",
            "-v",
            "error",
            "-i",
            str(video),
            "-i",
            str(original),
            "-map",
            "0:v:0",
            "-map",
            "1:a:0?",
            "-c:v",
            "copy",
            "-c:a",
            "aac",
            "-movflags",
            "+faststart",
            str(target),
        ],
        check=True,
        timeout=1800,
    )


def upscale_images(
    images: list[Path],
    run_dir: Path,
    params: dict[str, Any],
    workspace: Path,
    memory: list[str],
    total: int,
) -> int:
    if not images:
        return 0
    source = run_dir / WORK_DIR / "images"
    produced = run_dir / WORK_DIR / "images-out"
    source.mkdir(parents=True)
    for image in images:
        os.link(image, source / image.name)
    code = run_cli(
        cli_argv(source, produced, params, workspace, clip=False, memory=memory),
        watch=produced,
        total=total,
    )
    if code != 0:
        say(f"the image pass exited with {code}; keeping the images it finished")
    done = 0
    for image in images:
        result = produced / f"{image.stem}.png"
        if result.is_file() and result.stat().st_size > 0:
            os.replace(result, run_dir / OUTPUT_DIR / result.name)
            done += 1
        else:
            say(f"failed {image.name}: SeedVR2 wrote no result")
    return done


def upscale_clip(
    clip: Path, run_dir: Path, params: dict[str, Any], workspace: Path, memory: list[str]
) -> bool:
    work = run_dir / WORK_DIR / "clips"
    work.mkdir(parents=True, exist_ok=True)
    restored = work / f"{clip.stem}.mp4"
    code = run_cli(cli_argv(clip, restored, params, workspace, clip=True, memory=memory))
    if code != 0 or not restored.is_file():
        say(f"failed {clip.name}: SeedVR2 exited with {code}")
        return False
    expected, got = frame_count(clip), frame_count(restored)
    if expected is None or got != expected:
        say(f"failed {clip.name}: the result has {got} frames, the clip {expected}")
        return False
    target = run_dir / OUTPUT_DIR / f"{clip.stem}.mp4"
    partial = target.with_name(target.name + ".part.mp4")
    try:
        with_original_audio(restored, clip, partial)
    except (OSError, subprocess.SubprocessError) as error:
        partial.unlink(missing_ok=True)
        say(f"failed {clip.name}: could not restore its audio ({error})")
        return False
    os.replace(partial, target)
    return True


def run(run_dir: Path) -> int:
    try:
        params = load_params(run_dir)
        images, clips = split_inputs(run_dir / INPUT_DIR)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        say(f"bad input: {error}")
        return EXIT_BAD_INPUT
    if not CLI.is_file() or not PYTHON.is_file():
        say(f"bad input: SeedVR2 is not installed in this image ({CLI})")
        return EXIT_BAD_INPUT
    workspace = run_dir.parents[1]
    total = len(images) + len(clips)
    memory_gib = gpu_memory_gib()
    memory = memory_flags(memory_gib, params["model"])
    shown = "unknown" if memory_gib is None else f"{memory_gib:.0f} GiB"
    say(
        f"{len(images)} images and {len(clips)} clips with SeedVR2 {params['model'].upper()}, "
        f"short side {params['resolution']} px, GPU memory {shown}, flags {' '.join(memory) or 'none'}"
    )
    shutil.rmtree(run_dir / WORK_DIR, ignore_errors=True)
    (run_dir / OUTPUT_DIR).mkdir(parents=True, exist_ok=True)
    done = upscale_images(images, run_dir, params, workspace, memory, total)
    say(f"ready {done}/{total}")
    for clip in clips:
        if upscale_clip(clip, run_dir, params, workspace, memory):
            done += 1
        say(f"ready {done}/{total}")
    shutil.rmtree(run_dir / WORK_DIR, ignore_errors=True)
    return 0 if done > 0 else EXIT_FAILED


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--run", required=True, type=Path, help="the service's run directory")
    args = parser.parse_args(argv)
    return run(args.run.resolve())


if __name__ == "__main__":
    sys.exit(main())
