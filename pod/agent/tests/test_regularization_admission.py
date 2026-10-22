"""The agent admits the same model-row class-set modes the app and launcher expose."""

import runpy
from pathlib import Path

import pytest
from pydantic import ValidationError

from podagent.catalog import DrawRegularizationParams, RunConfig, parse_params
from podagent.settings import Paths

TABLE = runpy.run_path(str(Path(__file__).parents[2] / "scripts/model_table.py"))
ROWS = TABLE["models"]()


@pytest.mark.parametrize("row", ROWS, ids=lambda row: row["id"])
def test_folder_admission_matches_model_support(tmp_path, row):
    paths = Paths(workspace=tmp_path / "workspace", prefix=tmp_path / "opt")
    folder = paths.datasets / "classes"
    folder.mkdir(parents=True)
    raw = {
        "run_id": "new",
        "base_model": row["model_ref"],
        "dataset": {"path": str(paths.datasets / "subjects")},
        "triggers": ["NORA7"],
        "regularization": {"source": "folder", "path": str(folder), "weight": 1.0},
    }
    if row["regularization"]["mode"] == "unsupported":
        with pytest.raises(ValidationError, match="regularization/repa"):
            parse_params("trainer-" + row["trainer"], raw, paths)
    else:
        params = parse_params("trainer-" + row["trainer"], raw, paths)
        assert isinstance(params, RunConfig) and params.regularization is not None
        assert params.regularization.source == "folder"


@pytest.mark.parametrize(
    "row", [r for r in ROWS if r["trainer"] == "aitoolkit"], ids=lambda row: row["id"]
)
def test_drawing_admission_matches_registered_model_generation(tmp_path, row):
    paths = Paths(workspace=tmp_path / "workspace", prefix=tmp_path / "opt")
    raw = {
        "run_id": "draw",
        "base_model": row["model_ref"],
        "resolution": 512,
        "dataset": {"path": str(paths.datasets / "subjects")},
        "regularization": {
            "source": "generate",
            "images": 2,
            "weight": 1.0,
            "class_nouns": {"NORA7": "person"},
            "generation": {"steps": 28, "guidance_scale": 1.0, "seed": 0},
        },
    }
    if row["regularization"]["mode"] == "generate":
        params = parse_params("draw-regularization", raw, paths)
        assert isinstance(params, DrawRegularizationParams)
        assert params.base_model == row["model_ref"]
    else:
        with pytest.raises(ValidationError, match="Generated regularisation"):
            parse_params("draw-regularization", raw, paths)
