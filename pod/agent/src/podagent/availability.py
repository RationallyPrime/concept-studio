"""Installed programs behind the catalog, without importing trainer/GPU libraries or weights."""

from __future__ import annotations

import os
import runpy
from pathlib import Path
from typing import Any

from .settings import Paths


def executable(path: str | Path) -> bool:
    return Path(path).is_file() and os.access(path, os.X_OK)


def command(paths: Paths, venv: str, binary: str) -> bool:
    return executable(paths.venv_bin(venv, "python")) and executable(paths.venv_bin(venv, binary))


def script(paths: Paths, venv: str, name: str) -> bool:
    return executable(paths.venv_bin(venv, "python")) and (paths.scripts / name).is_file()


def _launcher(paths: Paths, trainer: str) -> dict[str, Any]:
    # The launchers are stdlib-only at import time. Their own path helpers preserve environment
    # overrides and defaults; no second set of trainer-path rules lives in the agent.
    return runpy.run_path(str(paths.scripts / f"launch_{trainer}.py"))


def trainer(paths: Paths, name: str) -> bool:
    if not script(paths, name, f"launch_{name}.py"):
        return False
    try:
        launcher = _launcher(paths, name)
        if name == "aitoolkit":
            entrypoints = [Path(launcher["trainer_argv"](paths.workspace, {})[1])]
        elif name == "ltx":
            entrypoints = [launcher["preprocess_script"](), launcher["train_script"]()]
        else:
            table = launcher["_TABLE"]
            rows = table["pair_rows"](table["load"](paths.scripts / "model-table.json"))
            architectures = {row["architecture"]["arch"] for row in rows if row["trainer"] == name}
            entrypoints = [
                launcher["musubi_script"](architecture, task)
                for architecture in architectures
                for task in ("cache_latents", "cache_text_encoder_outputs", "train_network")
            ]
        return bool(entrypoints) and all(path.is_file() for path in entrypoints)
    except (OSError, ImportError, SyntaxError, KeyError, ValueError):
        # A partial image can contain the launcher while lacking its shared rules/model table.
        return False


def generation(paths: Paths, trainer: str) -> bool:
    if not script(paths, trainer, "generate_results.py"):
        return False
    try:
        renderer = runpy.run_path(str(paths.scripts / "generate_results.py"))
        # Every generator dispatches through the installed model table; do not use checkout fallbacks.
        renderer["model_table"]()["load"](paths.scripts / "model-table.json")
        if trainer == "aitoolkit":
            root = Path(renderer["aitoolkit_directory"]())
            return all(
                (root / module).is_file()
                for module in (
                    "toolkit/config_modules.py",
                    "toolkit/stable_diffusion_model.py",
                    "toolkit/sampler.py",
                    "toolkit/util/get_model.py",
                )
            )
        # Both renderers load their launcher for config/weight handling before native inference.
        _launcher(paths, trainer)
        # These packages are installed editable by the trainer Dockerfiles. Generation imports the
        # installed package; LTX_TRAINER_DIR/MUSUBI_TUNER_DIR override training scripts, not imports.
        if trainer == "ltx":
            return (
                paths.prefix / "ltx-2/packages/ltx-pipelines/src/ltx_pipelines/ti2vid_one_stage.py"
            ).is_file()
        return (paths.prefix / "musubi-tuner/src/musubi_tuner/krea2_generate_image.py").is_file()
    except (OSError, ImportError, SyntaxError, KeyError, ValueError):
        return False


def regularization(paths: Paths) -> bool:
    return (paths.scripts / "regularization.py").is_file() and generation(paths, "aitoolkit")


def upscale(paths: Paths) -> bool:
    return (
        script(paths, "seedvr2", "upscale_media.py")
        and (paths.prefix / "seedvr2/inference_cli.py").is_file()
        and any(
            module.is_file()
            for module in (paths.prefix / "venvs/seedvr2/lib").glob(
                "python*/site-packages/torch/__init__.py"
            )
        )
    )
