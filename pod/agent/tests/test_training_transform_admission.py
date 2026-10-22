"""The public service accepts native transforms only on the supported trainer."""

import pytest
from pydantic import ValidationError

from podagent.catalog import LtxRunConfig, MusubiRunConfig, RunConfig


@pytest.mark.parametrize("mode", ["horizontal", "square"])
def test_ai_toolkit_admits_explicit_augmentation_and_other_trainers_refuse(mode):
    raw = {
        "run_id": "test",
        "dataset": {"path": "/workspace/datasets/test"},
        "triggers": ["PERSON8"],
        "base_model": "test/model",
        "augmentation": mode,
    }
    assert RunConfig.model_validate(raw).augmentation == mode
    for config in (LtxRunConfig, MusubiRunConfig):
        with pytest.raises(ValidationError, match="does not support training-time augmentation"):
            config.model_validate(raw)
