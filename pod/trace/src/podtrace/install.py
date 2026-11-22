"""Install, remove and inspect the ``.pth`` file that activates podtrace in another interpreter."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any

from .config import (
    DEFAULT_CONFIG_PATH,
    DEFAULT_CONTROL_PATH,
    ConfigError,
    config_path_from_env,
)
from .config import load as load_config

PTH_NAME = "podtrace.pth"
PTH_LINE = "import podtrace.bootstrap\n"

_PROBE = (
    "import sysconfig, json\n"
    "try:\n"
    "    import podtrace\n"
    "    v = podtrace.__version__\n"
    "except Exception as e:\n"
    "    v = None\n"
    "print(json.dumps({'purelib': sysconfig.get_paths()['purelib'], 'podtrace': v}))\n"
)


class InstallError(RuntimeError):
    pass


def probe(python: str) -> dict[str, Any]:
    """Where the interpreter keeps site-packages and whether it can import podtrace."""
    if not os.path.exists(python):
        raise InstallError(f"no such interpreter: {python}")
    env = dict(os.environ, PODTRACE_DISABLE="1")
    try:
        out = subprocess.run(
            [python, "-c", _PROBE], capture_output=True, text=True, timeout=60, env=env, check=True
        )
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, OSError) as exc:
        detail = getattr(exc, "stderr", "") or str(exc)
        raise InstallError(f"could not run {python}: {detail.strip()[:300]}") from exc
    return json.loads(out.stdout.strip().splitlines()[-1])


def pth_path(python: str) -> Path:
    return Path(probe(python)["purelib"]) / PTH_NAME


def install(python: str, config: str | None = None, config_dest: str | None = None) -> list[str]:
    info = probe(python)
    notes = []
    if info["podtrace"] is None:
        notes.append(
            f"warning: {python} cannot import podtrace; run "
            f"`uv pip install --python {python} <path to pod/trace>` first, or the "
            "podtrace.pth line will fail (harmlessly) at every start"
        )
    target = Path(info["purelib"]) / PTH_NAME
    target.write_text(PTH_LINE, encoding="utf-8")
    notes.append(f"wrote {target}")
    if config:
        dest = Path(config_dest or DEFAULT_CONFIG_PATH)
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(config, dest)
        notes.append(f"copied {config} to {dest}")
    return notes


def uninstall(python: str) -> list[str]:
    target = pth_path(python)
    if target.exists():
        target.unlink()
        return [f"removed {target}"]
    return [f"nothing to remove: {target} does not exist"]


def status(python: str | None) -> dict[str, Any]:
    """Everything useful to know about the installation, as plain data."""
    out: dict[str, Any] = {}
    if python:
        try:
            info = probe(python)
            target = Path(info["purelib"]) / PTH_NAME
            out["python"] = python
            out["site_packages"] = info["purelib"]
            out["podtrace_importable"] = info["podtrace"] is not None
            out["podtrace_version"] = info["podtrace"]
            out["pth"] = str(target)
            out["pth_present"] = target.exists()
            if target.exists():
                out["pth_content"] = target.read_text(encoding="utf-8").strip()
        except InstallError as exc:
            out["error"] = str(exc)
    cfg_path = config_path_from_env()
    out["config_path"] = cfg_path
    out["config_from_env"] = bool(os.environ.get("PODTRACE_CONFIG"))
    out["config_present"] = os.path.isfile(cfg_path)
    out["disabled_by_env"] = bool(os.environ.get("PODTRACE_DISABLE"))
    control_path = DEFAULT_CONTROL_PATH
    if out["config_present"]:
        try:
            cfg = load_config(cfg_path)
            control_path = cfg.control_file
            out["include_rules"] = len(cfg.rules)
            out["argv_glob"] = list(cfg.argv_glob)
            out["plugins"] = list(cfg.plugins)
            out["out_dir"] = cfg.out_dir
            out["jsonl"] = cfg.jsonl
            out["logfire"] = cfg.logfire
            out["logfire_token_in_env"] = bool(os.environ.get("LOGFIRE_TOKEN", "").strip())
            out["logfire_credentials_dir"] = cfg.credentials_dir or None
            runs = Path(cfg.out_dir)
            if runs.is_dir():
                dirs = sorted(
                    (d for d in runs.iterdir() if d.is_dir()), key=lambda d: d.stat().st_mtime
                )
                out["runs"] = [d.name for d in dirs[-5:]]
        except ConfigError as exc:
            out["config_error"] = str(exc)
    out["control_path"] = control_path
    try:
        with open(control_path, encoding="utf-8") as fh:
            out["control"] = json.load(fh)
    except FileNotFoundError:
        out["control"] = None
    except (OSError, ValueError) as exc:
        out["control_error"] = str(exc)
    out["running_python"] = sys.version.split()[0]
    return out
