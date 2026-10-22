"""upscale_media.py with a stand-in for the SeedVR2 command line: what lands where, and what fails."""

import importlib.util
import json
import sys
from pathlib import Path

import pytest

spec = importlib.util.spec_from_file_location(
    "upscale_media", Path(__file__).parents[1] / "upscale_media.py"
)
upscale = importlib.util.module_from_spec(spec)
spec.loader.exec_module(upscale)

# Writes <output>/<stem>.png for every image in the input folder except those named "skip*",
# or the --output file itself for a clip: what the real command line does with these arguments.
STAND_IN = """
import sys
from pathlib import Path
source, output = Path(sys.argv[1]), Path(sys.argv[sys.argv.index("--output") + 1])
if source.is_dir():
    output.mkdir(parents=True, exist_ok=True)
    for image in source.iterdir():
        if not image.name.startswith("skip"):
            (output / (image.stem + ".png")).write_bytes(b"restored " + image.read_bytes())
else:
    output.write_bytes(b"restored clip")
"""


@pytest.fixture
def run_dir(tmp_path, monkeypatch):
    cli = tmp_path / "opt/seedvr2/inference_cli.py"
    cli.parent.mkdir(parents=True)
    cli.write_text(STAND_IN)
    monkeypatch.setattr(upscale, "CLI", cli)
    monkeypatch.setattr(upscale, "PYTHON", Path(sys.executable))
    monkeypatch.setattr(upscale, "POLL_SECONDS", 0.01)
    monkeypatch.setattr(upscale, "gpu_memory_gib", lambda: 96.0)
    run = tmp_path / "workspace/runs/upscale-001"
    (run / "inputs").mkdir(parents=True)
    params = {"model": "3b", "resolution": 1024, "max_resolution": 2048, "seed": 42}
    (run / "upscale.json").write_text(json.dumps(params))
    return run


def test_images_land_in_output_and_a_missing_result_is_reported(run_dir, capsys):
    for name in ("a.jpg", "b.webp", "skip.png"):
        (run_dir / "inputs" / name).write_bytes(name.encode())
    assert upscale.run(run_dir) == 0
    output = run_dir / "output"
    assert sorted(p.name for p in output.iterdir()) == ["a.png", "b.png"]
    assert (output / "a.png").read_bytes() == b"restored a.jpg"
    log = capsys.readouterr().out
    assert "[upscale] failed skip.png: SeedVR2 wrote no result" in log
    assert "[upscale] ready 2/3" in log
    assert not (run_dir / "work").exists()


def test_a_clip_with_a_different_frame_count_is_not_kept(run_dir, monkeypatch, capsys):
    (run_dir / "inputs" / "walk.mp4").write_bytes(b"clip")
    monkeypatch.setattr(
        upscale, "frame_count", lambda path: 49 if path.parent.name == "inputs" else 52
    )
    assert upscale.run(run_dir) == upscale.EXIT_FAILED
    assert list((run_dir / "output").iterdir()) == []
    assert "the result has 52 frames, the clip 49" in capsys.readouterr().out


def test_a_clip_keeps_its_audio(run_dir, monkeypatch):
    (run_dir / "inputs" / "walk.mp4").write_bytes(b"clip")
    monkeypatch.setattr(upscale, "frame_count", lambda path: 49)
    muxed = []

    def mux(video, original, target):
        muxed.append((video.read_bytes(), original.name))
        target.write_bytes(b"with audio")

    monkeypatch.setattr(upscale, "with_original_audio", mux)
    assert upscale.run(run_dir) == 0
    assert muxed == [(b"restored clip", "walk.mp4")]
    assert (run_dir / "output/walk.mp4").read_bytes() == b"with audio"


@pytest.mark.parametrize(
    ("files", "reason"),
    [
        (("a.jpg", "a.png"), "share a name"),
        (("notes.txt",), "not an image or clip"),
        ((), "no images or clips"),
    ],
)
def test_bad_inputs_run_nothing(run_dir, capsys, files, reason):
    for name in files:
        (run_dir / "inputs" / name).write_bytes(b"x")
    assert upscale.run(run_dir) == upscale.EXIT_BAD_INPUT
    assert reason in capsys.readouterr().out
    assert not (run_dir / "output").exists()


def test_small_gpus_get_the_memory_savings():
    assert upscale.memory_flags(96.0, "7b") == []
    assert upscale.memory_flags(32.0, "7b") == ["--vae_encode_tiled", "--vae_decode_tiled"]
    assert "--blocks_to_swap" in upscale.memory_flags(16.0, "3b")
    assert "--blocks_to_swap" in upscale.memory_flags(None, "3b")
