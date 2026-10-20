"""musubi-tuner rules shared by the agent and the isolated launch wrapper: one file, two readers.

The image copies this stdlib-only file beside the agent source layout under /opt/pod, so
``scripts/launch_musubi.py`` loads the same values with runpy under ``python -I``; the agent imports
it. It decides what ``extra`` may hold on a musubi-tuner run:

- ``extra`` has one key, ``args``: musubi-tuner training flags merged over the row's
  ``trainer_options.args`` (``{"optimizer_type": "AdamW8bit"}``; ``true`` passes a switch, ``false``
  or ``null`` leaves the flag out);
- the flags the wrapper sets itself (model files, dataset, output, logging, length, sampling,
  saving, Resume and Hub upload) cannot be set there, and a string value cannot name a path.
"""

from __future__ import annotations

import re
from typing import Any

EXTRA_KEYS = frozenset({"args"})
ARG_NAME_RE = re.compile(r"^[a-z][a-z0-9_]{0,63}$")
# Flags of krea2_train_network.py (musubi-tuner v0.3.4) that the wrapper writes from run.json and
# the model row. Paths stay inside the run, and the run's length, saving and sampling follow run.json.
WRAPPER_ARGS = frozenset(
    {
        "dit",
        "turbo_dit",
        "vae",
        "text_encoder",
        "dataset_config",
        "output_dir",
        "output_name",
        "logging_dir",
        "log_with",
        "log_prefix",
        "log_tracker_name",
        "log_config",
        "sample_prompts",
        "sample_every_n_steps",
        "sample_every_n_epochs",
        "sample_at_first",
        "max_train_steps",
        "max_train_epochs",
        "save_every_n_steps",
        "save_every_n_epochs",
        "save_last_n_steps",
        "save_last_n_epochs",
        "save_state",
        "save_state_on_train_end",
        "save_last_n_steps_state",
        "save_last_n_epochs_state",
        "resume",
        "network_weights",
        "learning_rate",
        "network_dim",
        "network_alpha",
        "seed",
        "gradient_accumulation_steps",
        "config_file",
    }
)
EXTRA_MESSAGE = "extra on a musubi-tuner run holds only args (musubi-tuner training flags)"


def check_extra(extra: Any) -> None:
    """Raise ValueError when ``extra`` is not a musubi-tuner ``{"args": {...}}`` override."""
    if not isinstance(extra, dict):
        raise ValueError("extra must be a mapping")
    unknown = sorted(str(key) for key in set(extra) - EXTRA_KEYS)
    if unknown:
        raise ValueError(f"{EXTRA_MESSAGE}; not {', '.join(unknown)}")
    args = extra.get("args", {})
    if not isinstance(args, dict):
        raise ValueError("extra.args must be a mapping of flag names to values")
    for name, value in args.items():
        if not isinstance(name, str) or not ARG_NAME_RE.match(name):
            raise ValueError(f"extra.args: {name!r} is not a musubi-tuner flag name")
        if name in WRAPPER_ARGS:
            raise ValueError(f"extra.args.{name}: the wrapper sets this from run.json")
        if value is not None and not isinstance(value, bool | int | float | str):
            raise ValueError(f"extra.args.{name}: must be a string, number, true, false or null")
        if isinstance(value, str) and ("/" in value or "\\" in value or not value.strip()):
            raise ValueError(f"extra.args.{name}: must not be empty or name a path")


def flag_argv(args: dict[str, Any]) -> list[str]:
    """``{"sdpa": True, "network_dim": 32, "fp8_base": False}`` -> ``["--sdpa", "--network_dim", "32"]``."""
    argv: list[str] = []
    for name, value in args.items():
        if value is None or value is False:
            continue
        argv.append(f"--{name}")
        if value is not True:
            argv.append(str(value))
    return argv
