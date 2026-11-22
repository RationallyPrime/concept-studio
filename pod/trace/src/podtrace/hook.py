"""Load-time hook: compile instrumented source instead of the file's own bytecode.

``SourceFileLoader.get_code`` is the one place every file-based import goes through, whether it
came from the normal path finder or from ``spec_from_file_location`` + ``exec_module`` the way
ComfyUI loads custom nodes (which bypasses ``sys.meta_path`` for the package ``__init__``). The
hook is keyed on the file path, never on a module name.

A matching file is parsed, rewritten and compiled from source every time: no ``.pyc`` is read
for it and none is written. Any failure falls back to the loader's normal behaviour.
"""

from __future__ import annotations

import os
import sys
from importlib.machinery import SourceFileLoader
from typing import Any

from . import registry
from .config import Config

_orig_get_code: Any = None
_PKG_DIR = os.path.dirname(os.path.abspath(__file__)).replace("\\", "/") + "/"
_decided: list[bool | None] = [None]


def _process_ok(cfg: Config) -> bool:
    if _decided[0] is not None:
        return _decided[0]
    verdict = cfg.process_matches(list(getattr(sys, "argv", ())))
    if verdict is None:
        return False  # argv is not populated yet: look again at the next import
    _decided[0] = verdict
    return verdict


def _patched_get_code(self: SourceFileLoader, fullname: str) -> Any:
    cfg = registry.CONFIG
    try:
        if cfg is None or not _process_ok(cfg):
            return _orig_get_code(self, fullname)
        path = self.get_filename(fullname)
        if not path.endswith(".py") or os.path.abspath(path).replace("\\", "/").startswith(
            _PKG_DIR
        ):
            return _orig_get_code(self, fullname)
        rule = cfg.match_file(path)
    except Exception:
        return _orig_get_code(self, fullname)
    if rule is None:
        return _orig_get_code(self, fullname)
    try:
        from .transform import transform

        data = self.get_data(path)
        tree, _table = transform(data, path, rule)
        return self.source_to_code(tree, path)
    except Exception as exc:
        # Includes SyntaxError: the original path then raises the same error in the usual way.
        sys.stderr.write(f"podtrace: not instrumenting {path}: {type(exc).__name__}: {exc}\n")
        return _orig_get_code(self, fullname)


_patched_get_code.__dict__["__podtrace__"] = True


def install(cfg: Config) -> bool:
    """Activate the hook for this process. False when the process is not selected."""
    global _orig_get_code
    registry.CONFIG = cfg
    if cfg.process_matches(list(getattr(sys, "argv", ()))) is False:
        _decided[0] = False
        return False
    if getattr(SourceFileLoader.get_code, "__podtrace__", False):
        return True
    _orig_get_code = SourceFileLoader.get_code
    setattr(SourceFileLoader, "get_code", _patched_get_code)  # noqa: B010
    return True


def uninstall() -> None:
    """Remove the hook (tests)."""
    global _orig_get_code
    if getattr(SourceFileLoader.get_code, "__podtrace__", False) and _orig_get_code is not None:
        SourceFileLoader.get_code = _orig_get_code  # type: ignore[method-assign]
    _orig_get_code = None
    _decided[0] = None
    registry.CONFIG = None
