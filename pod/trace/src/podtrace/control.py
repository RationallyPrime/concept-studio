"""The control file: switches recording on and off per render without a restart.

``{"record": true, "label": "broken", "deep": ["*h3forge.context.*"]}``. Re-read when its mtime
changes. Missing file, ``record`` absent or false: recording is off.
"""

from __future__ import annotations

import json
import os
import threading
from dataclasses import dataclass, field
from typing import Any


@dataclass
class Control:
    path: str
    record: bool = False
    label: str | None = None
    deep: tuple[str, ...] = ()
    # Bumped when ``deep`` changes, so functions re-check whether they are on the list.
    deep_gen: int = 0
    # Bumped each time ``record`` turns on, so every recording is its own run.
    session: int = 0
    error: str | None = None
    _stamp: tuple[int, int] | None = field(default=None, repr=False)
    _lock: threading.Lock = field(default_factory=threading.Lock, repr=False)

    def refresh(self) -> bool:
        """Re-read the file if it changed; True when anything the recorder uses changed."""
        try:
            st = os.stat(self.path)
            stamp: tuple[int, int] | None = (st.st_mtime_ns, st.st_size)
        except OSError:
            stamp = None
        if stamp == self._stamp:
            return False
        with self._lock:
            if stamp == self._stamp:
                return False
            self._stamp = stamp
            return self._apply(stamp)

    def _apply(self, stamp: tuple[int, int] | None) -> bool:
        data: dict[str, Any] = {}
        if stamp is not None:
            try:
                with open(self.path, encoding="utf-8") as fh:
                    loaded = json.load(fh)
                if not isinstance(loaded, dict):
                    raise ValueError("control file must hold a JSON object")
                data = loaded
                self.error = None
            except (OSError, ValueError) as exc:
                # Keep what is in force; a half-written file is read again when it changes.
                self.error = f"{type(exc).__name__}: {exc}"
                self._stamp = None
                return False
        record = bool(data.get("record", False))
        label = data.get("label")
        label = None if label is None else str(label)
        deep_raw = data.get("deep", ())
        deep = tuple(str(p) for p in deep_raw) if isinstance(deep_raw, (list, tuple)) else ()
        changed = (record, label, deep) != (self.record, self.label, self.deep)
        if deep != self.deep:
            self.deep_gen += 1
        if record and not self.record:
            self.session += 1
        self.record, self.label, self.deep = record, label, deep
        return changed


def write_control(path: str, *, record: bool, label: str | None, deep: list[str]) -> None:
    """Atomically replace the control file (used by ``podtrace control``)."""
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    tmp = f"{path}.tmp{os.getpid()}"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump({"record": record, "label": label, "deep": deep}, fh, indent=2)
        fh.write("\n")
    os.replace(tmp, path)
