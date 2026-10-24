"""The upscale-media service: admission of a finished upload, and its move into the run."""

from __future__ import annotations

import json
from pathlib import Path

import pytest
from fastapi.testclient import TestClient
from pydantic import ValidationError

from podagent.catalog import CATALOG, parse_params
from podagent.settings import Paths, Settings


@pytest.fixture
def paths(tmp_path: Path) -> Paths:
    return Paths(workspace=tmp_path / "workspace", prefix=tmp_path / "opt")


def staged(paths: Paths, name: str = "upscale-001", files: tuple[str, ...] = ("a.jpg",)) -> Path:
    folder = paths.uploads / name
    folder.mkdir(parents=True)
    for file in files:
        (folder / file).write_bytes(b"media")
    return folder


def params(**overrides: object) -> dict[str, object]:
    return {"run_id": "upscale-001", "upload": "upscale-001", **overrides}


def test_prepare_moves_the_upload_into_the_run(paths: Paths) -> None:
    staged(paths, files=("a.jpg", "b.mp4"))
    parsed = parse_params(
        "upscale-media", params(model="7b", resolution=768, hf_token="fresh-oauth-token"), paths
    )
    CATALOG["upscale-media"].prepare(parsed, paths)
    run = paths.run_dir("upscale-001")
    assert sorted(p.name for p in (run / "inputs").iterdir()) == ["a.jpg", "b.mp4"]
    assert not (paths.uploads / "upscale-001").exists()
    saved = json.loads((run / "upscale.json").read_text())
    assert "hf_token" not in saved
    assert "fresh-oauth-token" not in (run / "upscale.json").read_text()
    assert (saved["model"], saved["resolution"], saved["max_resolution"]) == ("7b", 768, 2048)
    argv = CATALOG["upscale-media"].argv(parsed, [0], paths)
    assert argv[-2:] == ["--run", str(run)]
    assert argv[0].endswith("venvs/seedvr2/bin/python")


@pytest.mark.parametrize("trainer", ["aitoolkit", "musubi", "ltx"])
def test_upscale_requires_the_trainers_shared_torch(paths: Paths, trainer: str) -> None:
    python = Path(paths.venv_bin("seedvr2", "python"))
    python.parent.mkdir(parents=True)
    python.touch()
    python.chmod(0o755)
    for entrypoint in (
        paths.scripts / "upscale_media.py",
        paths.prefix / "seedvr2/inference_cli.py",
    ):
        entrypoint.parent.mkdir(parents=True, exist_ok=True)
        entrypoint.touch()
    service = CATALOG["upscale-media"]
    assert not service.available(paths)  # Thin base has packages but no GPU runtime.

    source = paths.prefix / "venvs" / trainer / "lib/python3.12/site-packages/torch"
    source.mkdir(parents=True)
    (source / "__init__.py").touch()
    shared = python.parent.parent / "lib/python3.12/site-packages/torch"
    shared.parent.mkdir(parents=True)
    shared.symlink_to(source, target_is_directory=True)
    assert service.available(paths)

    (source / "__init__.py").unlink()
    assert not service.available(paths)


@pytest.mark.parametrize(
    ("setup", "overrides", "loc"),
    [
        ("none", {}, ("upload",)),
        ("partial", {}, ("upload",)),
        ("run", {}, ("run_id",)),
        ("ok", {"model": "13b"}, ("model",)),
        ("ok", {"resolution": 1024, "max_resolution": 512}, ()),
    ],
)
def test_refuses_what_cannot_be_upscaled(
    paths: Paths, setup: str, overrides: dict[str, object], loc: tuple[str, ...]
) -> None:
    if setup == "partial":
        staged(paths, files=("a.jpg", "b.mp4.part"))
    elif setup in {"ok", "run"}:
        staged(paths)
    if setup == "run":
        paths.run_dir("upscale-001").mkdir(parents=True)
    with pytest.raises(ValidationError) as error:
        parse_params("upscale-media", params(**overrides), paths)
    assert tuple(error.value.errors()[0]["loc"]) == loc


def test_upload_then_upscale_through_the_api(client: TestClient, settings: Settings) -> None:
    assert client.put("/uploads/upscale-002/a.png", content=b"png").status_code == 200
    response = client.post(
        "/services/upscale-media/start",
        json={"gpus": [0], "params": {"run_id": "upscale-002", "upload": "upscale-002"}},
    )
    assert response.status_code == 201, response.text
    inputs = settings.paths.run_dir("upscale-002") / "inputs"
    assert [p.name for p in inputs.iterdir()] == ["a.png"]
    again = client.post(
        "/services/upscale-media/start",
        json={"gpus": [1], "params": {"run_id": "upscale-003", "upload": "upscale-002"}},
    )
    assert again.status_code == 422
