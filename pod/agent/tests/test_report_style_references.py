"""Report reference snapshots stay in their generation run and never redirect file access."""

import json

import pytest
from pydantic import ValidationError

from podagent.catalog import CATALOG, StyleReferences, parse_params
from podagent.settings import Paths


@pytest.mark.parametrize(
    "filename", ["../photo.png", "/photo.png", "nested/photo.png", "photo.txt", "x\\photo.png"]
)
def test_style_references_accept_only_flat_image_names(filename):
    with pytest.raises(ValidationError, match="basenames"):
        StyleReferences(upload="style-one", groups={"STYLE7": [filename]})


def test_generation_keeps_a_private_immutable_copy_of_style_references(tmp_path):
    paths = Paths(workspace=tmp_path / "workspace", prefix=tmp_path / "opt")
    source = paths.run_dir("trained")
    (source / "output").mkdir(parents=True)
    (source / "output/final.safetensors").write_bytes(b"synthetic checkpoint")
    (source / "run.json").write_text(json.dumps({"base_model": "black-forest-labs/FLUX.1-dev"}))
    stage = paths.uploads / "style-one"
    stage.mkdir(parents=True)
    (stage / "reference.png").write_bytes(b"synthetic reference")
    raw = {
        "run_id": "report",
        "source_run_id": "trained",
        "checkpoint": "final.safetensors",
        "prompts": ["A teapot in STYLE7"],
        "seeds": [42],
        "style_references": {"upload": "style-one", "groups": {"STYLE7": ["reference.png"]}},
    }
    params = parse_params("generate-aitoolkit", raw, paths)
    CATALOG["generate-aitoolkit"].prepare(params, paths)
    (stage / "reference.png").write_bytes(b"changed after capture")
    captured = paths.run_dir("report") / "style-references/reference.png"
    assert captured.read_bytes() == b"synthetic reference"
    request = json.loads((paths.run_dir("report") / "generation.json").read_text())
    assert request["style_references"] == raw["style_references"]
    assert not (paths.run_dir("report") / "output/reference.png").exists()
