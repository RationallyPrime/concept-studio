#!/usr/bin/env python3
"""run.json -> musubi-tuner dataset, caches and LoRA training, with log tee and loss scraping (POD-SPEC §4.3).

    launch_musubi.py --config /workspace/runs/<id>/run.json [--dry-run]

1. Validate run.json: an own copy of the RunConfig rules of POD-SPEC §4.1 (no podagent import).
   ``dataset.path`` must be an existing directory under ``<PODAGENT_WORKSPACE>/datasets``.
   ``base_model`` must be the ``model_ref`` of a musubi row in the model table: the row carries
   the architecture, the weight files and the recipe. ``regularization``, ``repa``,
   ``initialization`` and the ``TRAINER_SETTINGS`` belong to the AI Toolkit trainer, and
   musubi-tuner cannot continue a run (its step counter restarts on ``--resume``), so this wrapper
   refuses them and ``resume``. ``extra`` holds only ``args`` (``musubi_rules.py``).
2. Prepare the row's weight files (``trainer_options.weights``: ``dit``, ``vae``, ``text_encoder``
   and, when the run draws samples, ``sample_dit``), each from its pinned Hub revision into
   ``<workspace>/models/huggingface/<repo>/``; existing files are reused. A failure exits
   ``EXIT_MODEL_PREPARATION`` (69) before any run file is written. Skipped by ``--dry-run``.
3. Write ``<run>/dataset.jsonl`` (one ``{"image_path", "caption"}`` per captioned image; images
   without a ``<stem>.<caption_ext>`` sidecar are skipped and counted), ``<run>/dataset.toml``
   (one musubi dataset per resolution, bucketed, latents cached under ``<run>/cache/<resolution>``)
   and, when sampling, ``<run>/sample_prompts.txt``. ``--dry-run`` stops here with exit 0.
4. Cache latents and text-encoder outputs with ``<arch>_cache_latents.py`` and
   ``<arch>_cache_text_encoder_outputs.py`` (``--skip_existing``); a nonzero exit ends the run.
5. Train: ``python -m accelerate.commands.launch <arch>_train_network.py ...``: the row's
   ``trainer_options.args``, ``extra.args`` merged over them, then the flags this wrapper owns
   (weights, dataset, ``output_dir=<run>/output``, ``output_name=<run_id>``, TensorBoard in
   ``<run>/tensorboard``, length, learning rate, rank, alpha, seed, saving and sampling). Output is
   tee'd to stdout and musubi-tuner's ``avr_loss`` is scraped into ``<run>/tensorboard/`` as
   ``scraped/loss``. Samples are drawn on ``sample_dit`` with ``trainer_options.sample``
   (steps, CFG, and the flags sampling needs); musubi-tuner writes them to ``output/sample``, which
   is renamed ``output/samples`` when training ends, where the app and push_lora.py look.
6. On exit 0 with ``hub.push_on_finish``, run the sibling ``push_lora.py`` (agent venv).
7. Exit with the trainer's code; when the trainer succeeded but the push did not, with the
   push's code, so a nonzero exit always means something did not land.

Exit codes of the wrapper itself: ``2`` invalid run config (nothing written), ``69`` model
preparation failed (Hub unreachable, gated, licence not accepted, disk full; nothing written).
Any other code is a cache step's, the trainer's or the push's.

Checked against musubi-tuner at the commit ``images/Dockerfile.musubi`` pins: the script names, the
flags written here, the dataset config keys (``image_jsonl_file``, ``cache_directory``), the
checkpoint names (``<run_id>-step00000100.safetensors``, the last one ``<run_id>.safetensors``) and
the sample folder.

Environment: ``PODAGENT_WORKSPACE`` (default ``/workspace``), ``MUSUBI_TUNER_DIR`` (default
``/opt/musubi-tuner``), ``POD_AGENT_PYTHON`` (interpreter for push_lora.py; default
``/opt/venvs/agent/bin/python``, else this interpreter), ``HF_TOKEN`` (or ``hf_token`` in
run.json, passed to children through the environment only).

Standard library only at import time. The model table and the musubi rules shared with the agent
are read at import with runpy (``model_table.py`` beside this script,
``../agent/src/podagent/musubi_rules.py``), the layout the image recreates under ``/opt/pod``; a
missing copy therefore fails ``--help``, which the image build runs. The block between the
``shared`` markers is byte-identical in every launch_<trainer>.py (tests assert it): the scripts run
under ``python -I``, so sibling imports are not available.
"""

from __future__ import annotations

import argparse
import codecs
import contextlib
import json
import math
import os
import re
import runpy
import shlex
import signal
import subprocess
import sys
import threading
from pathlib import Path
from typing import Any, TextIO

SCRIPT_NAME = "launch_musubi"

# --- shared: byte-identical in every launch_<trainer>.py --------------------------------------

RUN_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
REPO_ID_RE = re.compile(r"^[\w.-]+/[\w.-]+$")
MODEL_ID_RE = re.compile(r"^[\w.-]+(?:/[\w.-]+)?$")  # Hub id: "owner/name" or a bare "name"
CAPTION_EXT_RE = re.compile(r"^\.?[A-Za-z0-9]{1,16}$")
DEFAULT_WORKSPACE = "/workspace"
DEFAULT_AGENT_PYTHON = "/opt/venvs/agent/bin/python"
DEFAULT_RESOLUTION = [512, 768, 1024]
CHILD_GRACE_SECONDS = 5.0  # SIGTERM -> this long -> SIGKILL, when the tee itself fails

# Trainer settings that override the model's own recipe (POD-SPEC 4.1). Absent or null means the
# recipe's value. AI Toolkit only: the LTX wrapper refuses them, as it refuses regularization.
TRAINER_SETTINGS = (
    "caption_dropout",
    "gradient_checkpointing",
    "optimizer",
    "lr_scheduler",
    "lr_warmup_steps",
)
OPTIMIZER_RE = re.compile(r"^[A-Za-z0-9_]{1,32}$")  # an ai-toolkit optimizer name
# The learning-rate schedules ai-toolkit builds from a name and the run's steps alone; only the
# warmup schedule takes a parameter, lr_warmup_steps.
LR_SCHEDULERS = ("constant", "constant_with_warmup", "cosine")
WARMUP_SCHEDULER = "constant_with_warmup"

_TOP_KEYS = frozenset(
    {
        *TRAINER_SETTINGS,
        "run_id",
        "dataset",
        "triggers",
        "profile",
        "base_model",
        "train_audio",
        "steps",
        "learning_rate",
        "rank",
        "alpha",
        "resolution",
        "batch_size",
        "gradient_accumulation",
        "seed",
        "save_every",
        "sample_every",
        "sample_prompts",
        "hub",
        "hf_token",
        "extra",
        "resume",
        "initialization",
        "regularization",
        "repa",
        "augmentation",
    }
)
_REQUIRED_KEYS = ("run_id", "dataset", "triggers", "base_model")
_DATASET_KEYS = frozenset({"path", "caption_ext"})
_HUB_KEYS = frozenset({"repo_id", "private", "push_on_finish"})


def say(message: str) -> None:
    """One line from the wrapper itself, on stdout like the trainer's output."""
    print(f"[{SCRIPT_NAME}] {message}", flush=True)


class ConfigError(ValueError):
    """run.json violates the RunConfig rules; the message lists every problem found."""


def _is_int(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def _is_number(value: Any) -> bool:
    return isinstance(value, int | float) and not isinstance(value, bool) and math.isfinite(value)


def _validate_dataset(
    value: Any, workspace: Path | None, errors: list[str], *, allow_missing: bool = False
) -> dict[str, str]:
    out = {"path": "", "caption_ext": "txt"}
    if not isinstance(value, dict):
        errors.append("dataset: must be an object with path and caption_ext")
        return out
    unknown = sorted(set(value) - _DATASET_KEYS)
    if unknown:
        errors.append("dataset: unknown keys: " + ", ".join(unknown))
    path = value.get("path")
    if not isinstance(path, str) or not path.strip():
        errors.append("dataset.path: must be a non-empty string")
    else:
        resolved = Path(path).expanduser().resolve()
        if workspace is not None:
            root = (workspace / "datasets").resolve()
            if not resolved.is_relative_to(root):
                errors.append(f"dataset.path: must resolve under {root}")
            elif not resolved.is_dir() and not (allow_missing and not resolved.exists()):
                errors.append(f"dataset.path: {resolved} is not a directory")
        out["path"] = str(resolved)
    ext = value.get("caption_ext", "txt")
    if not isinstance(ext, str) or not CAPTION_EXT_RE.match(ext):
        errors.append("dataset.caption_ext: must be a short alphanumeric extension")
    else:
        out["caption_ext"] = ext.lstrip(".")
    return out


def _validate_hub(value: Any, errors: list[str]) -> dict[str, Any] | None:
    if value is None:
        return None
    if not isinstance(value, dict):
        errors.append("hub: must be an object or null")
        return None
    unknown = sorted(set(value) - _HUB_KEYS)
    if unknown:
        errors.append("hub: unknown keys: " + ", ".join(unknown))
    repo_id = value.get("repo_id")
    if not isinstance(repo_id, str) or not REPO_ID_RE.match(repo_id):
        errors.append("hub.repo_id: must look like owner/name")
    out: dict[str, Any] = {"repo_id": repo_id, "private": True, "push_on_finish": False}
    for key in ("private", "push_on_finish"):
        flag = value.get(key, out[key])
        if isinstance(flag, bool):
            out[key] = flag
        else:
            errors.append(f"hub.{key}: must be true or false")
    return out


def _validate_trainer_settings(raw: dict[str, Any], errors: list[str]) -> dict[str, Any]:
    """``TRAINER_SETTINGS`` with null for each one run.json leaves to the model's recipe."""
    out: dict[str, Any] = dict.fromkeys(TRAINER_SETTINGS)
    dropout = raw.get("caption_dropout")
    if dropout is not None:
        if _is_number(dropout) and 0 <= dropout <= 1:
            out["caption_dropout"] = float(dropout)
        else:
            errors.append("caption_dropout: must be a number from 0 to 1, or null")
    checkpointing = raw.get("gradient_checkpointing")
    if checkpointing is not None:
        if isinstance(checkpointing, bool):
            out["gradient_checkpointing"] = checkpointing
        else:
            errors.append("gradient_checkpointing: must be true, false or null")
    optimizer = raw.get("optimizer")
    if optimizer is not None:
        if isinstance(optimizer, str) and OPTIMIZER_RE.match(optimizer):
            out["optimizer"] = optimizer
        else:
            errors.append("optimizer: must be an optimizer name such as adamw8bit, or null")
    scheduler = raw.get("lr_scheduler")
    if scheduler is not None:
        if scheduler in LR_SCHEDULERS:
            out["lr_scheduler"] = scheduler
        else:
            errors.append("lr_scheduler: must be one of " + ", ".join(LR_SCHEDULERS) + ", or null")
    warmup = raw.get("lr_warmup_steps")
    if warmup is not None:
        if _is_int(warmup) and warmup >= 0:
            out["lr_warmup_steps"] = warmup
        else:
            errors.append("lr_warmup_steps: must be an integer >= 0, or null")
    return out


def validate_run_config(
    raw: Any, workspace: Path | None = None, *, allow_missing_dataset: bool = False
) -> dict[str, Any]:
    """Validate a decoded run.json (POD-SPEC §4.1) and return it with defaults applied.

    ``alpha`` defaults to ``rank``; ``resolution`` is always a list; ``dataset.path`` is resolved
    and, when ``workspace`` is given, must be an existing directory under ``<workspace>/datasets``.
    Unknown keys are rejected, as the agent's pydantic model does. Raises ConfigError listing every
    violation at once.
    """
    if not isinstance(raw, dict):
        raise ConfigError("run config must be a JSON object")
    errors: list[str] = []
    unknown = sorted(set(raw) - _TOP_KEYS)
    if unknown:
        errors.append("unknown keys: " + ", ".join(unknown))
    for key in _REQUIRED_KEYS:
        if key not in raw:
            errors.append(f"{key}: required")

    def get_int(key: str, default: int, minimum: int) -> int:
        value = raw.get(key, default)
        if not _is_int(value) or value < minimum:
            errors.append(f"{key}: must be an integer >= {minimum}")
            return default
        return value

    def get_str_list(key: str, required: bool) -> list[str]:
        value = raw.get(key, [])
        if not isinstance(value, list) or not all(isinstance(v, str) and v.strip() for v in value):
            errors.append(f"{key}: must be a list of non-empty strings")
            return []
        if required and not value:
            errors.append(f"{key}: must not be empty")
        return list(value)

    cfg: dict[str, Any] = {}
    run_id = raw.get("run_id")
    if not isinstance(run_id, str) or not RUN_ID_RE.match(run_id):
        errors.append("run_id: must match ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
    cfg["run_id"] = run_id
    cfg["dataset"] = _validate_dataset(
        raw.get("dataset"), workspace, errors, allow_missing=allow_missing_dataset
    )
    cfg["triggers"] = get_str_list("triggers", required=True)
    profile = raw.get("profile")
    if profile is not None and not isinstance(profile, str):
        errors.append("profile: must be a string or null")
    cfg["profile"] = profile
    augmentation = raw.get("augmentation", "none")
    if augmentation not in ("none", "horizontal", "square"):
        errors.append("augmentation: must be none, horizontal or square")
    if augmentation != "none" and SCRIPT_NAME != "launch_aitoolkit":
        errors.append("augmentation: this trainer does not support training-time transforms")
    cfg["augmentation"] = augmentation
    base_model = raw.get("base_model")
    if not isinstance(base_model, str) or not base_model.strip():
        errors.append("base_model: must be a non-empty string")
    cfg["base_model"] = base_model
    cfg["train_audio"] = raw.get("train_audio", True)
    if not isinstance(cfg["train_audio"], bool):
        errors.append("train_audio: must be true or false")
    cfg["steps"] = get_int("steps", 2000, 1)
    learning_rate = raw.get("learning_rate", 1e-4)
    if not _is_number(learning_rate) or learning_rate <= 0:
        errors.append("learning_rate: must be a number > 0")
        learning_rate = 1e-4
    cfg["learning_rate"] = float(learning_rate)
    cfg["rank"] = get_int("rank", 16, 1)
    alpha = raw.get("alpha")
    if alpha is None:
        alpha = cfg["rank"]
    elif not _is_int(alpha) or alpha < 1:
        errors.append("alpha: must be an integer >= 1 or null")
        alpha = cfg["rank"]
    cfg["alpha"] = alpha
    resolution = raw.get("resolution", DEFAULT_RESOLUTION)
    if _is_int(resolution):
        resolution = [resolution]
    if (
        not isinstance(resolution, list)
        or not resolution
        or not all(_is_int(r) and r > 0 for r in resolution)
    ):
        errors.append("resolution: must be a positive integer or a non-empty list of them")
        resolution = DEFAULT_RESOLUTION
    cfg["resolution"] = list(resolution)
    cfg["batch_size"] = get_int("batch_size", 1, 1)
    cfg["gradient_accumulation"] = get_int("gradient_accumulation", 1, 1)
    cfg["seed"] = get_int("seed", 42, 0)
    cfg["save_every"] = get_int("save_every", 250, 1)
    cfg["sample_every"] = get_int("sample_every", 250, 0)
    cfg["sample_prompts"] = get_str_list("sample_prompts", required=False)
    cfg["hub"] = _validate_hub(raw.get("hub"), errors)
    token = raw.get("hf_token")
    if token is not None and (not isinstance(token, str) or not token):
        errors.append("hf_token: must be a non-empty string or null")
        token = None
    cfg["hf_token"] = token
    extra = raw.get("extra", {})
    if not isinstance(extra, dict):
        errors.append("extra: must be an object")
        extra = {}
    cfg["extra"] = extra
    cfg["initialization"] = raw.get("initialization")
    if cfg["initialization"] is not None:
        helper = runpy.run_path(str(Path(__file__).with_name("h3_recipe.py")))
        try:
            helper["validate_initialization"](cfg["initialization"])
        except ValueError as error:
            errors.append(str(error))
    cfg["resume"] = raw.get("resume", False)
    if not isinstance(cfg["resume"], bool):
        errors.append("resume: must be true or false")
    for key in ("regularization", "repa"):  # AI Toolkit only; its launcher checks the contents
        value = raw.get(key)
        if value is not None and not isinstance(value, dict):
            errors.append(f"{key}: must be an object or null")
            value = None
        cfg[key] = value
    cfg.update(_validate_trainer_settings(raw, errors))
    if errors:
        raise ConfigError("; ".join(errors))
    return cfg


def workspace_root() -> Path:
    """``PODAGENT_WORKSPACE`` (default ``/workspace``): where every trainer path has to live."""
    return Path(os.environ.get("PODAGENT_WORKSPACE") or DEFAULT_WORKSPACE).expanduser()


def is_under(value: Any, roots: tuple[Path, ...]) -> bool:
    """True when ``value`` is an absolute path string that resolves under one of ``roots``."""
    if not isinstance(value, str) or not value.startswith("/"):
        return False
    resolved = Path(value).resolve()
    return any(resolved.is_relative_to(root.resolve()) for root in roots)


def is_model_ref(value: Any, roots: tuple[Path, ...]) -> bool:
    """A Hub id (``owner/name`` or ``name``) or an absolute path under one of ``roots``."""
    if not isinstance(value, str) or not value:
        return False
    if value.startswith("/"):
        return is_under(value, roots)
    return bool(MODEL_ID_RE.match(value)) and all(
        segment not in {".", ".."} for segment in value.split("/")
    )


def _roots_text(roots: tuple[Path, ...]) -> str:
    return " or ".join(str(root) for root in roots)


def require_path(errors: list[str], label: str, value: Any, roots: tuple[Path, ...]) -> None:
    """Record an error unless ``value`` is an absolute path under one of ``roots``."""
    if not is_under(value, roots):
        errors.append(
            f"{label}: must be an absolute path under {_roots_text(roots)}, got {value!r}"
        )


def require_model_ref(errors: list[str], label: str, value: Any, roots: tuple[Path, ...]) -> None:
    """Record an error unless ``value`` is a Hub id or an absolute path under one of ``roots``."""
    if not is_model_ref(value, roots):
        errors.append(
            f"{label}: must be a Hub id ('owner/name') or an absolute path under "
            f"{_roots_text(roots)}, got {value!r}"
        )


def load_run(
    config_path: Path, *, restore_missing_dataset: bool = True
) -> tuple[Path, dict[str, Any]]:
    """run.json path -> (run directory, validated config). The run directory holds run.json."""
    config_path = config_path.expanduser().resolve()
    raw = json.loads(config_path.read_text(encoding="utf-8"))
    workspace = workspace_root()
    cfg = validate_run_config(
        raw,
        workspace,
        allow_missing_dataset=restore_missing_dataset
        and isinstance(raw, dict)
        and raw.get("resume") is True,
    )
    run_dir = config_path.parent
    restore = runpy.run_path(str(Path(__file__).with_name("restore_dataset.py")))["restore_dataset"]
    try:
        if restore_missing_dataset:
            restore(cfg, run_dir, workspace)
    except (OSError, ValueError) as error:
        raise ConfigError(str(error)) from error
    cfg = validate_run_config(cfg, workspace)
    if run_dir.name != cfg["run_id"]:
        say(f"note: run directory {run_dir} is not named after run_id {cfg['run_id']!r}")
    return run_dir, cfg


def deep_merge(base: dict[str, Any], override: dict[str, Any]) -> dict[str, Any]:
    """``base`` updated by ``override``: mappings merge recursively, anything else is replaced."""
    merged = dict(base)
    for key, value in override.items():
        current = merged.get(key)
        if isinstance(current, dict) and isinstance(value, dict):
            merged[key] = deep_merge(current, value)
        else:
            merged[key] = value
    return merged


# YAML: PyYAML when importable (the trainer venvs have it), else the emitter below. The emitter
# writes block style only, quotes every string (JSON escaping is a subset of YAML's double-quoted
# escaping) and formats floats so PyYAML reads them back as floats (``1.0e-05``, never ``1e-05``).

_PLAIN_KEY_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_.-]*$")
_RESERVED_KEYS = frozenset({"true", "false", "null", "yes", "no", "on", "off", "y", "n", "~"})


def _yaml_float(value: float) -> str:
    if math.isnan(value):
        return ".nan"
    if math.isinf(value):
        return ".inf" if value > 0 else "-.inf"
    text = repr(value)
    if "e" in text or "E" in text:
        mantissa, _, exponent = text.lower().partition("e")
        if "." not in mantissa:
            mantissa += ".0"
        if exponent[0] not in "+-":
            exponent = "+" + exponent
        return f"{mantissa}e{exponent}"
    if "." not in text:
        text += ".0"
    return text


def _yaml_scalar(value: Any) -> str:
    if value is None:
        return "null"
    if value is True:
        return "true"
    if value is False:
        return "false"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, float):
        return _yaml_float(value)
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=False)
    raise TypeError(f"cannot write {type(value).__name__} to YAML")


def _yaml_key(key: Any) -> str:
    text = str(key)
    if _PLAIN_KEY_RE.match(text) and text.lower() not in _RESERVED_KEYS:
        return text
    return json.dumps(text, ensure_ascii=False)


def _emit_mapping(node: dict[str, Any], indent: int, lines: list[str]) -> None:
    pad = "  " * indent
    for key, value in node.items():
        label = _yaml_key(key)
        if isinstance(value, dict):
            if value:
                lines.append(f"{pad}{label}:")
                _emit_mapping(value, indent + 1, lines)
            else:
                lines.append(f"{pad}{label}: {{}}")
        elif isinstance(value, list | tuple):
            if value:
                lines.append(f"{pad}{label}:")
                _emit_sequence(list(value), indent + 1, lines)
            else:
                lines.append(f"{pad}{label}: []")
        else:
            lines.append(f"{pad}{label}: {_yaml_scalar(value)}")


def _emit_sequence(node: list[Any], indent: int, lines: list[str]) -> None:
    pad = "  " * indent
    for item in node:
        if isinstance(item, dict | list | tuple):
            if not item:
                lines.append(f"{pad}- {{}}" if isinstance(item, dict) else f"{pad}- []")
                continue
            nested: list[str] = []
            if isinstance(item, dict):
                _emit_mapping(item, indent + 1, nested)
            else:
                _emit_sequence(list(item), indent + 1, nested)
            # the first nested line carries the dash in place of its indentation
            lines.append(f"{pad}- {nested[0][len(pad) + 2 :]}")
            lines.extend(nested[1:])
        else:
            lines.append(f"{pad}- {_yaml_scalar(item)}")


def dump_yaml(data: dict[str, Any]) -> str:
    """Serialise a JSON-shaped mapping as YAML; PyYAML when importable, else the emitter here."""
    try:
        import yaml
    except ImportError:
        yaml = None
    if yaml is not None:
        return yaml.safe_dump(
            data, sort_keys=False, default_flow_style=False, allow_unicode=True, width=1_000_000
        )
    lines: list[str] = []
    _emit_mapping(data, 0, lines)
    return "\n".join(lines) + "\n"


def write_yaml(path: Path, data: dict[str, Any], header: str) -> None:
    path.write_text(header + dump_yaml(data), encoding="utf-8")


# Log scraper. A line (or a \r-separated progress-bar redraw) yields scalars only when a step is
# known: from the same line, or from an earlier one. Lines before the first step (config echoes
# such as ``lr: 0.0001``) are ignored. One value per tag per step.

_NUM = r"[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?"
_SEP = r"[\"']?(?:\s*[=:]\s*|\s+)"
_STEP_TQDM_RE = re.compile(r"(?<![\w/.])(\d+)(?:/\d+|it)\s*\[")
_STEP_WORD_RE = re.compile(r"(?<![\w/])(?:global_)?step[\"']?\s*[=:]?\s*(\d+)\b", re.IGNORECASE)
_LOSS_RE = re.compile(r"(?<!\w)loss" + _SEP + "(" + _NUM + ")", re.IGNORECASE)
_LR_RE = re.compile(r"(?<!\w)(?:lr|learning[_ ]rate)" + _SEP + "(" + _NUM + ")", re.IGNORECASE)
_SCRAPED_TAGS = (("scraped/loss", _LOSS_RE), ("scraped/lr", _LR_RE))
_LINE_SPLIT_RE = re.compile(r"\r\n|\r|\n")


def find_step(line: str) -> int | None:
    """The training step a log line reports: tqdm ``N/M [`` / ``Nit [`` first, then ``step N``."""
    match = _STEP_TQDM_RE.search(line) or _STEP_WORD_RE.search(line)
    return int(match.group(1)) if match else None


class LogScraper:
    """Turns trainer output lines into ``(tag, step, value)`` scalars."""

    def __init__(self) -> None:
        self.last_step: int | None = None
        self.written = 0
        self._last_written: dict[str, int] = {}

    def feed(self, line: str) -> list[tuple[str, int, float]]:
        step = find_step(line)
        if step is not None:
            self.last_step = step
        if self.last_step is None:
            return []
        found: list[tuple[str, int, float]] = []
        for tag, pattern in _SCRAPED_TAGS:
            match = pattern.search(line)
            if match is None or self._last_written.get(tag) == self.last_step:
                continue
            try:
                value = float(match.group(1))
            except ValueError:
                continue
            self._last_written[tag] = self.last_step
            found.append((tag, self.last_step, value))
        self.written += len(found)
        return found


def open_writer(logdir: Path) -> Any | None:
    """A ``torch.utils.tensorboard.SummaryWriter`` on ``logdir``, or None when not importable."""
    try:
        from torch.utils.tensorboard import SummaryWriter
    except Exception as exc:  # ImportError, or torch present without tensorboard
        say(f"log scraper: torch.utils.tensorboard not importable ({exc}); scalars not written")
        return None
    logdir.mkdir(parents=True, exist_ok=True)
    return SummaryWriter(log_dir=str(logdir), filename_suffix=".scraped")


def _forward_sigterm(proc: subprocess.Popen[bytes]) -> Any:
    """Make SIGTERM to the wrapper terminate the child too; returns the previous handler."""
    if threading.current_thread() is not threading.main_thread():
        return None

    def handler(_signum: int, _frame: Any) -> None:
        with contextlib.suppress(ProcessLookupError):
            proc.terminate()

    return signal.signal(signal.SIGTERM, handler)


def _stop_child(proc: subprocess.Popen[bytes]) -> None:
    """End ``proc`` if it still runs: SIGTERM, ``CHILD_GRACE_SECONDS`` of patience, then SIGKILL."""
    if proc.poll() is not None:
        return
    with contextlib.suppress(ProcessLookupError):
        proc.terminate()
    try:
        proc.wait(timeout=CHILD_GRACE_SECONDS)
    except subprocess.TimeoutExpired:
        with contextlib.suppress(ProcessLookupError):
            proc.kill()


def tee(
    argv: list[str],
    *,
    cwd: Path,
    env: dict[str, str],
    out: TextIO,
    scraper: LogScraper | None = None,
    writer: Any | None = None,
) -> int:
    """Run ``argv``, copy its stdout+stderr to ``out`` line by line, scrape, return its exit code.

    ``\\r\\n``, ``\\r`` and ``\\n`` all end a line in the copy. A child killed by signal N
    returns 128+N. When the tee itself fails (``out`` or the event writer raising, say ENOSPC
    on the volume, or an interrupt) the child is stopped before the exception propagates:
    the supervisor files the wrapper's exit as the run's end and frees its GPUs, so a trainer
    must never outlive the wrapper. The child is always reaped.
    """
    proc = subprocess.Popen(
        argv,
        cwd=str(cwd),
        env=env,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    assert proc.stdout is not None
    decoder = codecs.getincrementaldecoder("utf-8")(errors="replace")
    pending = ""

    def emit(segment: str) -> bool:
        out.write(segment + "\n")
        if scraper is None:
            return False
        scalars = scraper.feed(segment)
        if writer is not None:
            for tag, step, value in scalars:
                writer.add_scalar(tag, value, step)
        return bool(scalars)

    previous = _forward_sigterm(proc)
    try:
        fd = proc.stdout.fileno()
        while True:
            chunk = os.read(fd, 65536)
            if not chunk:
                break
            pending += decoder.decode(chunk)
            parts = _LINE_SPLIT_RE.split(pending)
            pending = parts.pop()
            added = False
            for segment in parts:
                added = emit(segment) or added
            out.flush()
            if added and writer is not None:
                writer.flush()
        pending += decoder.decode(b"", final=True)
        if pending:
            emit(pending)
        out.flush()
        if writer is not None:
            writer.flush()
    except BaseException:
        _stop_child(proc)
        raise
    finally:
        if previous is not None:
            signal.signal(signal.SIGTERM, previous)
        proc.stdout.close()
        code = proc.wait()
    return 128 - code if code < 0 else code


def child_env(cfg: dict[str, Any]) -> dict[str, str]:
    """The agent's environment plus PYTHONUNBUFFERED and, from run.json, HF_TOKEN. Never argv."""
    env = dict(os.environ)
    env["PYTHONUNBUFFERED"] = "1"
    if cfg.get("hf_token"):
        env["HF_TOKEN"] = cfg["hf_token"]
    return env


def agent_python() -> str:
    """Interpreter for push_lora.py: POD_AGENT_PYTHON, else the agent venv, else this one."""
    candidate = os.environ.get("POD_AGENT_PYTHON") or DEFAULT_AGENT_PYTHON
    return candidate if Path(candidate).exists() else sys.executable


def push_lora_argv(run_dir: Path, cfg: dict[str, Any]) -> list[str]:
    """``push_lora.py --run-dir <run> --repo <id> [--private]`` (POD-SPEC §7.2), sibling script."""
    hub = cfg["hub"]
    script = Path(__file__).resolve().with_name("push_lora.py")
    argv = [agent_python(), str(script), "--run-dir", str(run_dir), "--repo", hub["repo_id"]]
    if hub["private"]:
        argv.append("--private")
    return argv


def run_trainer(cmd: list[str], run_dir: Path, cfg: dict[str, Any], out: TextIO) -> int:
    """Spawn the trainer with tee + scraper into ``<run>/tensorboard``; return its exit code."""
    (run_dir / "output").mkdir(exist_ok=True)
    logdir = run_dir / "tensorboard"
    logdir.mkdir(exist_ok=True)
    scraper = LogScraper()
    writer = open_writer(logdir)
    try:
        code = tee(cmd, cwd=run_dir, env=child_env(cfg), out=out, scraper=scraper, writer=writer)
    finally:
        if writer is not None:
            writer.close()
    say(f"trainer exited with code {code}; scraped {scraper.written} scalars")
    return code


def finish(run_dir: Path, cfg: dict[str, Any], code: int, out: TextIO) -> int:
    """After the trainer: push when asked and the run succeeded; pick the exit code."""
    hub = cfg["hub"]
    if hub is None or not hub["push_on_finish"]:
        return code
    if code != 0:
        say(f"not pushing to {hub['repo_id']}: trainer exited with {code}")
        return code
    cmd = push_lora_argv(run_dir, cfg)
    say(f"pushing to {hub['repo_id']}: {shlex.join(cmd)}")
    push_code = tee(cmd, cwd=run_dir, env=child_env(cfg), out=out)
    # This marker carries only a fixed outcome; telemetry failure must not fail training.
    marker_name = os.environ.get("PODAGENT_EXPORT_MARKER", "")
    if re.fullmatch(r"\.export-outcome-[0-9a-f]{32}", marker_name):
        with contextlib.suppress(OSError):
            fd = os.open(run_dir / marker_name, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, "w") as marker:
                marker.write("success" if push_code == 0 else "failed")
    if push_code != 0:
        say(f"push_lora.py exited with {push_code}")
    return push_code


# --- end shared ----------------------------------------------------------------------------------

MUSUBI_DIR_ENV = "MUSUBI_TUNER_DIR"
DEFAULT_MUSUBI_DIR = "/opt/musubi-tuner"
TRAINER = "musubi"
IMAGE_SUFFIXES = frozenset({".png", ".jpg", ".jpeg", ".webp", ".bmp", ".avif"})
MUSUBI_TRAINER_SETTINGS = "AI Toolkit settings; set musubi-tuner's own flags through extra.args"
NO_RESUME = "musubi-tuner cannot continue a run (its step counter restarts); start a new run with more steps"
EXIT_MODEL_PREPARATION = 69  # sysexits EX_UNAVAILABLE: the model source could not be prepared
_TABLE = runpy.run_path(str(Path(__file__).with_name("model_table.py")))
SHARED_RULES = (
    Path(__file__).resolve().parents[1] / "agent" / "src" / "podagent" / "musubi_rules.py"
)
_RULES = runpy.run_path(str(SHARED_RULES))
check_extra = _RULES["check_extra"]
flag_argv = _RULES["flag_argv"]
# The text-encoder cache step's own batching: it encodes captions, not training batches.
TEXT_ENCODER_CACHE_ARGS = ("--batch_size", "4", "--num_workers", "2")


def musubi_root() -> Path:
    return Path(os.environ.get(MUSUBI_DIR_ENV) or DEFAULT_MUSUBI_DIR)


def musubi_script(arch: str, task: str) -> Path:
    """``<musubi>/src/musubi_tuner/<arch>_<task>.py``, e.g. ``krea2_train_network.py``."""
    return musubi_root() / "src" / "musubi_tuner" / f"{arch}_{task}.py"


def run_row(cfg: dict[str, Any]) -> dict[str, Any]:
    """The musubi row whose ``model_ref`` is run.json's ``base_model``; there is no custom model."""
    row = _TABLE["exact_row"](cfg["base_model"], TRAINER)
    if row is None:
        names = [r["model_ref"] for r in _TABLE["pair_rows"]() if r["trainer"] == TRAINER]
        raise ConfigError("base_model: musubi-tuner trains " + ", ".join(names) + " only")
    return row


def sampling(cfg: dict[str, Any]) -> bool:
    return cfg["sample_every"] > 0 and bool(cfg["sample_prompts"])


def check_musubi_run(cfg: dict[str, Any]) -> dict[str, Any]:
    """The refusals of this trainer; returns the model row."""
    if cfg.get("initialization") is not None:
        raise ConfigError("External initial LoRA weights currently support AI Toolkit H3 only")
    if cfg.get("regularization") is not None or cfg.get("repa") is not None:
        raise ConfigError("regularization/repa are not available on the musubi-tuner trainer")
    settings = [key for key in TRAINER_SETTINGS if cfg.get(key) is not None]
    if settings:
        raise ConfigError(", ".join(settings) + ": " + MUSUBI_TRAINER_SETTINGS)
    if cfg["resume"]:
        raise ConfigError(NO_RESUME)
    try:
        check_extra(cfg["extra"])
    except ValueError as error:
        raise ConfigError(str(error)) from None
    return run_row(cfg)


def weight_roles(cfg: dict[str, Any]) -> tuple[str, ...]:
    return ("dit", "vae", "text_encoder", *(("sample_dit",) if sampling(cfg) else ()))


def weight_path(spec: dict[str, Any]) -> Path:
    return workspace_root() / "models" / "huggingface" / spec["repo"] / spec["file"]


def weight_paths(
    cfg: dict[str, Any], row: dict[str, Any], roles: tuple[str, ...] | None = None
) -> dict[str, Path]:
    """Local path of each weight role (the run's roles unless ``roles`` names others)."""
    weights = row["trainer_options"]["weights"]
    return {role: weight_path(weights[role]) for role in roles or weight_roles(cfg)}


def source_label(roles: tuple[str, ...], row: dict[str, Any]) -> str:
    """``repo@revision:file`` of each download, for log lines."""
    weights = row["trainer_options"]["weights"]
    return ", ".join(
        f"{weights[r]['repo']}@{weights[r]['revision'][:12]}:{weights[r]['file']}" for r in roles
    )


def download_weights(
    cfg: dict[str, Any], row: dict[str, Any], roles: tuple[str, ...] | None = None
) -> None:
    """Fetch each weight file from its pinned revision; files already in place are reused.

    ``roles`` defaults to the run's own (``weight_roles``); comparison generation names its own.
    """
    from huggingface_hub import hf_hub_download

    weights = row["trainer_options"]["weights"]
    roles = roles or weight_roles(cfg)
    say(f"preparing {cfg['base_model']} ({source_label(roles, row)}); existing files are reused")
    for role in roles:
        spec = weights[role]
        hf_hub_download(
            repo_id=spec["repo"],
            filename=spec["file"],
            revision=spec["revision"],
            local_dir=str(workspace_root() / "models" / "huggingface" / spec["repo"]),
            token=cfg.get("hf_token") or os.environ.get("HF_TOKEN"),
        )


def build_dataset_entries(dataset_dir: Path, caption_ext: str) -> tuple[list[dict[str, str]], int]:
    """``(entries, skipped)``: one entry per image with a non-empty caption sidecar."""
    rules = runpy.run_path(str(Path(__file__).with_name("training_transforms.py")))
    try:
        rules["reject_unsupported_masks"](dataset_dir, "musubi-tuner")
    except ValueError as error:
        raise ConfigError(str(error)) from error
    entries: list[dict[str, str]] = []
    skipped = 0
    for image in sorted(p for p in dataset_dir.rglob("*") if p.is_file()):
        if image.suffix.lower() not in IMAGE_SUFFIXES:
            continue
        sidecar = image.with_suffix("." + caption_ext)
        caption = sidecar.read_text(encoding="utf-8").strip() if sidecar.is_file() else ""
        if not caption:
            skipped += 1
            continue
        entries.append({"image_path": str(image), "caption": caption})
    # musubi-tuner names each cached latent after its image's file name.
    stems = [Path(e["image_path"]).stem for e in entries]
    clashes = sorted({s for s in stems if stems.count(s) > 1})
    if clashes:
        raise ConfigError("images in different folders share a name: " + ", ".join(clashes[:5]))
    return entries, skipped


def toml_value(value: Any) -> str:
    """A TOML scalar or list; strings are JSON-escaped, which TOML basic strings accept."""
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, list):
        return "[" + ", ".join(toml_value(v) for v in value) + "]"
    if isinstance(value, int | float):
        return repr(value)
    return json.dumps(str(value), ensure_ascii=False)


def dataset_toml(run_dir: Path, cfg: dict[str, Any]) -> str:
    """musubi-tuner's dataset config: one bucketed image dataset per training resolution."""
    lines = [
        "# musubi-tuner dataset config written by launch_musubi.py from run.json (POD-SPEC §4.3).",
        "[general]",
        f"batch_size = {toml_value(cfg['batch_size'])}",
        "enable_bucket = true",
        "bucket_no_upscale = false",
    ]
    for resolution in cfg["resolution"]:
        lines += [
            "",
            "[[datasets]]",
            f"image_jsonl_file = {toml_value(str(run_dir / 'dataset.jsonl'))}",
            f"resolution = {toml_value([resolution, resolution])}",
            f"cache_directory = {toml_value(str(run_dir / 'cache' / str(resolution)))}",
            "num_repeats = 1",
        ]
    return "\n".join(lines) + "\n"


def sample_lines(cfg: dict[str, Any], row: dict[str, Any]) -> list[str]:
    """One musubi-tuner prompt line per sample prompt: size, steps, CFG and a seed each."""
    sample = row["trainer_options"]["sample"]
    side = max(cfg["resolution"])
    lines = []
    for index, prompt in enumerate(cfg["sample_prompts"]):
        # `--` starts a musubi option inside the line; a prompt's own dashes must not.
        text = " ".join(prompt.replace("--", "-").split())
        lines.append(
            f"{text} --w {side} --h {side} --s {sample['steps']} --l {sample['cfg']:g}"
            f" --d {cfg['seed'] + index}"
        )
    return lines


def cache_argv(run_dir: Path, cfg: dict[str, Any], row: dict[str, Any]) -> list[list[str]]:
    arch = row["architecture"]["arch"]
    weights = weight_paths(cfg, row)
    config = str(run_dir / "dataset.toml")
    return [
        [
            sys.executable,
            str(musubi_script(arch, "cache_latents")),
            "--dataset_config", config,
            "--vae", str(weights["vae"]),
            "--skip_existing",
        ],
        [
            sys.executable,
            str(musubi_script(arch, "cache_text_encoder_outputs")),
            "--dataset_config", config,
            "--text_encoder", str(weights["text_encoder"]),
            *TEXT_ENCODER_CACHE_ARGS,
            "--skip_existing",
        ],
    ]  # fmt: skip


def train_args(run_dir: Path, cfg: dict[str, Any], row: dict[str, Any]) -> dict[str, Any]:
    """Every training flag in order: the row's, extra.args over them, then the wrapper's own."""
    recipe = row["recipe"]
    weights = weight_paths(cfg, row)
    args = {**row["trainer_options"]["args"], **cfg["extra"].get("args", {})}
    keep = recipe["checkpoints"]["keep"]
    args.update(
        {
            "dit": str(weights["dit"]),
            "vae": str(weights["vae"]),
            "text_encoder": str(weights["text_encoder"]),
            "dataset_config": str(run_dir / "dataset.toml"),
            "optimizer_type": args.get("optimizer_type", recipe["optimizer"]),
            "lr_scheduler": args.get("lr_scheduler", recipe["lr_scheduler"]),
            "learning_rate": f"{cfg['learning_rate']:g}",
            "network_dim": cfg["rank"],
            "network_alpha": cfg["alpha"],
            "gradient_accumulation_steps": cfg["gradient_accumulation"],
            "max_train_steps": cfg["steps"],
            "save_every_n_steps": cfg["save_every"],
            "save_last_n_steps": keep * cfg["save_every"] if keep else None,
            "seed": cfg["seed"],
            "output_dir": str(run_dir / "output"),
            "output_name": cfg["run_id"],
            "logging_dir": str(run_dir / "tensorboard"),
            "log_with": "tensorboard",
        }
    )
    if sampling(cfg):
        args.update(row["trainer_options"]["sample"].get("args", {}))
        args.update(
            {
                "turbo_dit": str(weights["sample_dit"]),
                "sample_prompts": str(run_dir / "sample_prompts.txt"),
                "sample_every_n_steps": cfg["sample_every"],
                "sample_at_first": True,
            }
        )
    return args


def trainer_argv(run_dir: Path, cfg: dict[str, Any], row: dict[str, Any]) -> list[str]:
    args = train_args(run_dir, cfg, row)
    return [
        sys.executable, "-m", "accelerate.commands.launch",
        "--num_cpu_threads_per_process", "1",
        "--mixed_precision", str(args.get("mixed_precision") or "no"),
        str(musubi_script(row["architecture"]["arch"], "train_network")),
        *flag_argv(args),
    ]  # fmt: skip


class MusubiLogScraper(LogScraper):
    """musubi-tuner's progress bar reports the moving-average loss as ``avr_loss=``."""

    def feed(self, line: str) -> list[tuple[str, int, float]]:
        return super().feed(line.replace("avr_loss=", "loss="))


def run_musubi(cmd: list[str], run_dir: Path, cfg: dict[str, Any], out: TextIO) -> int:
    """``run_trainer`` with musubi-tuner's loss name; samples move to ``output/samples`` after."""
    (run_dir / "output").mkdir(exist_ok=True)
    logdir = run_dir / "tensorboard"
    logdir.mkdir(exist_ok=True)
    scraper = MusubiLogScraper()
    writer = open_writer(logdir)
    try:
        code = tee(cmd, cwd=run_dir, env=child_env(cfg), out=out, scraper=scraper, writer=writer)
    finally:
        if writer is not None:
            writer.close()
    say(f"trainer exited with code {code}; scraped {scraper.written} scalars")
    drawn, samples = run_dir / "output" / "sample", run_dir / "output" / "samples"
    if drawn.is_dir() and not samples.exists():
        drawn.rename(samples)
    return code


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--config", required=True, help="path to run.json (its directory is the run)"
    )
    parser.add_argument(
        "--dry-run", action="store_true", help="write the dataset and prompt files, then exit"
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        run_dir, cfg = load_run(Path(args.config), restore_missing_dataset=not args.dry_run)
        row = check_musubi_run(cfg)
        entries, skipped = build_dataset_entries(
            Path(cfg["dataset"]["path"]), cfg["dataset"]["caption_ext"]
        )
        if not entries:
            raise ConfigError(f"no captioned images in {cfg['dataset']['path']}")
        caches = cache_argv(run_dir, cfg, row)
        cmd = trainer_argv(run_dir, cfg, row)
    except (OSError, ValueError, KeyError) as exc:
        say(f"invalid run config {args.config}: {exc}")
        return 2
    if not args.dry_run:
        # Before any run file exists: a failed download must not leave a run that looks prepared.
        try:
            download_weights(cfg, row)
        except Exception as error:
            status = getattr(getattr(error, "response", None), "status_code", None)
            detail = f" (HTTP {status})" if status is not None else ""
            reason = " ".join(str(error).split())[:300]
            say(
                f"model preparation failed for {source_label(weight_roles(cfg), row)}: "
                f"{type(error).__name__}{detail}" + (f": {reason}" if reason else "")
            )
            return EXIT_MODEL_PREPARATION
    jsonl = run_dir / "dataset.jsonl"
    jsonl.write_text(
        "".join(json.dumps(e, ensure_ascii=False) + "\n" for e in entries), encoding="utf-8"
    )
    say(f"wrote {jsonl}: {len(entries)} images, {skipped} without a caption skipped")
    (run_dir / "dataset.toml").write_text(dataset_toml(run_dir, cfg), encoding="utf-8")
    say(f"wrote {run_dir / 'dataset.toml'}")
    if sampling(cfg):
        prompts = run_dir / "sample_prompts.txt"
        prompts.write_text("\n".join(sample_lines(cfg, row)) + "\n", encoding="utf-8")
        say(f"wrote {prompts}")
    for step in caches:
        say(f"cache command: {shlex.join(step)}")
    say(f"trainer command: {shlex.join(cmd)}")
    if cfg["hub"] is not None and cfg["hub"]["push_on_finish"]:
        say(f"push on finish: {shlex.join(push_lora_argv(run_dir, cfg))}")
    if args.dry_run:
        say("dry run: nothing started")
        return 0
    for step in caches:
        code = tee(step, cwd=run_dir, env=child_env(cfg), out=sys.stdout)
        if code != 0:
            say(f"caching exited with code {code}; trainer not started")
            return code
    code = run_musubi(cmd, run_dir, cfg, sys.stdout)
    return finish(run_dir, cfg, code, sys.stdout)


if __name__ == "__main__":
    sys.exit(main())
