"""Shared fixtures: an isolated recorder per test, and helpers to write and load traced modules."""

from __future__ import annotations

import importlib.util
import json
import sys
import textwrap
from pathlib import Path
from typing import Any

import pytest

from podtrace import config, hook, registry, runtime


class Harness:
    def __init__(self, tmp_path: Path) -> None:
        self.tmp = tmp_path
        self.out = tmp_path / "runs"
        self.control = tmp_path / "control.json"
        self.pkg_dir = tmp_path / "traced"
        self.pkg_dir.mkdir()
        self._n = 0
        self.cfg: config.Config | None = None

    def start(self, include: list[dict[str, Any]] | None = None, **top: Any) -> config.Config:
        raw: dict[str, Any] = {
            "out_dir": str(self.out),
            "control_file": str(self.control),
            "control_poll_s": 0.05,
            "logfire": {"enabled": False},
            "include": include or [{"path": f"{self.pkg_dir.as_posix()}/**/*.py"}],
        }
        raw.update(top)
        self.cfg = config.from_dict(raw)
        self.record(True)
        hook.install(self.cfg)
        return self.cfg

    def record(self, on: bool, label: str | None = "t", deep: list[str] | None = None) -> None:
        self.control.write_text(json.dumps({"record": on, "label": label, "deep": deep or []}))
        if runtime.state.control is not None:
            # Make the change visible regardless of the file system's timestamp resolution.
            runtime.state.control._stamp = None
            runtime.state.control.refresh()
            runtime.state.on = runtime.state.control.record

    def module(self, source: str, name: str | None = None, via: str = "spec") -> Any:
        self._n += 1
        name = name or f"tmod{self._n}"
        path = self.pkg_dir / f"{name}.py"
        path.write_text(textwrap.dedent(source))
        if via == "import":
            sys.path.insert(0, str(self.pkg_dir))
            try:
                return importlib.import_module(name)
            finally:
                sys.path.remove(str(self.pkg_dir))
        spec = importlib.util.spec_from_file_location(f"odd.{name}", path)
        assert spec and spec.loader
        mod = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = mod
        spec.loader.exec_module(mod)
        return mod

    def run_dirs(self) -> list[Path]:
        return sorted(p for p in self.out.iterdir() if p.is_dir()) if self.out.exists() else []

    def records(self, run: int = -1) -> list[dict[str, Any]]:
        runtime.shutdown() if False else None
        if runtime.state.jsonl is not None:
            runtime.state.jsonl.flush()
        path = self.run_dirs()[run] / "records.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines() if line]

    def by_name(self, suffix: str, run: int = -1) -> list[dict[str, Any]]:
        return [r for r in self.records(run) if r["name"].endswith(suffix)]


@pytest.fixture
def h(tmp_path: Path):
    harness = Harness(tmp_path)
    yield harness
    runtime.shutdown()
    runtime._reset()
    hook.uninstall()
    registry.TABLES.clear()
    for name in [n for n in sys.modules if n.startswith(("odd.", "tmod"))]:
        del sys.modules[name]
