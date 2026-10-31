"""Low-frequency, opt-in training summaries; never export trainer output or paths."""

from __future__ import annotations

import json
import logging
import math
import re
import struct
import time
from typing import Any

from .checkpoints import checkpoint_step, latest_checkpoint
from .errors import AgentError
from .gpus import InventoryUnavailable
from .supervisor import Supervisor

log = logging.getLogger("podagent.progress")
INTERVAL_S = 60
STALE_S = 180
TAIL_BYTES = 65536
NUMBER = r"[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?"
STEP = re.compile(r"(?<![\w/.])(\d+)/(?:\d+)\s*\[")
LOSS = re.compile(r"(?<!\w)(?:avr_)?loss\s*[=:]\s*(" + NUMBER + r")", re.I)
LR = re.compile(r"(?<!\w)(?:lr|learning[_ ]rate)\s*[=:]\s*(" + NUMBER + r")", re.I)


def read_progress(path: Any) -> tuple[int, float | None, float | None] | None:
    # Only bounded bytes are read, and only a progress-bar line with a recognised
    # training scalar is accepted. Raw output never leaves this function.
    with path.open("rb") as stream:
        stream.seek(0, 2)
        stream.seek(max(0, stream.tell() - TAIL_BYTES))
        tail = stream.read(TAIL_BYTES).decode("utf-8", "replace")
    for line in reversed(tail.replace("\r", "\n").splitlines()):
        step = STEP.search(line)
        loss, lr = LOSS.search(line), LR.search(line)
        if step and (loss or lr):

            def scalar(match: Any) -> float | None:
                value = float(match.group(1)) if match else None
                return value if value is not None and math.isfinite(value) else None

            return int(step.group(1)), scalar(loss), scalar(lr)
    return None


class ProgressReporter:
    def __init__(self, supervisor: Supervisor) -> None:
        self.supervisor = supervisor
        self.previous: dict[tuple[str, str, str], tuple[int, float]] = {}
        self.checkpoints: dict[tuple[str, str, str], tuple[str, int, int]] = {}
        self.reported: dict[tuple[str, str, str], tuple[str, int, int]] = {}
        self.terminal_seen: set[tuple[str, str, str]] = set()

    def collect(self) -> None:
        all_states = [
            s
            for s in self.supervisor.states()
            if s.name.startswith("trainer-") and s.run_id and s.started_at
        ]
        current_keys = {(s.name, s.run_id, s.started_at.isoformat()) for s in all_states}
        self.terminal_seen.intersection_update(current_keys)
        for state in all_states:
            key = (state.name, state.run_id, state.started_at.isoformat())
            if (
                state.state in ("failed", "exited", "stopped")
                and not state.group_alive
                and key not in self.terminal_seen
            ):
                self._checkpoint(key, state, final=True)
                self.terminal_seen.add(key)
        states = [state for state in all_states if state.state == "running"]
        if not states:
            self.previous.clear()
            return
        try:
            gpu_by_index = {g.index: g for g in self.supervisor.backend.list_gpus()}
        except InventoryUnavailable:
            gpu_by_index = None
        active = set()
        for state in states:
            assert state.run_id is not None and state.started_at is not None
            key = (state.name, state.run_id, state.started_at.isoformat())
            active.add(key)
            attrs: dict[str, Any] = {
                "run_id": state.run_id,
                "service_name": state.name,
                "progress_status": "unknown",
                "step": None,
                "loss": None,
                "learning_rate": None,
                "seconds_per_step": None,
                "gpu_memory_used_mib": None,
                "gpu_memory_total_mib": None,
            }
            try:
                progress = read_progress(
                    self.supervisor.settings.paths.run_dir(state.run_id) / "trainer.log"
                )
                now = time.monotonic()
                if progress is not None:
                    step, loss, lr = progress
                    attrs.update(step=step, loss=loss, learning_rate=lr)
                    previous = self.previous.get(key)
                    if previous and step > previous[0]:
                        attrs["seconds_per_step"] = (now - previous[1]) / (step - previous[0])
                        attrs["progress_status"] = "current"
                        self.previous[key] = (step, now)
                    elif previous and step == previous[0]:
                        attrs["progress_status"] = (
                            "stale" if now - previous[1] > STALE_S else "unknown"
                        )
                    else:
                        self.previous[key] = (step, now)
            except OSError:
                pass
            if gpu_by_index is not None and all(i in gpu_by_index for i in state.gpus):
                attrs["gpu_memory_used_mib"] = sum(
                    gpu_by_index[i].memory_used_mib for i in state.gpus
                )
                attrs["gpu_memory_total_mib"] = sum(
                    gpu_by_index[i].memory_total_mib for i in state.gpus
                )
            log.info("training progress", extra=attrs)
            self._checkpoint(key, state)
        self.previous = {key: value for key, value in self.previous.items() if key in active}
        self.checkpoints = {key: value for key, value in self.checkpoints.items() if key in active}
        self.reported = {key: value for key, value in self.reported.items() if key in active}

    def _checkpoint(self, key: tuple[str, str, str], state: Any, *, final: bool = False) -> None:
        # A stable size and complete safetensors layout across two observations provide a
        # bounded indication that the file is complete, without reading tensor contents.
        trainer = state.name.removeprefix("trainer-")
        try:
            path = latest_checkpoint(
                self.supervisor.settings.paths.run_dir(state.run_id), trainer, state.run_id
            )
            if path is None:
                return
            info = path.stat()
            if info.st_mtime < state.started_at.timestamp():
                return
            identity = (str(path), info.st_size, info.st_mtime_ns)
            previous = self.checkpoints.get(key)
            self.checkpoints[key] = identity
            if (previous != identity and not final) or self.reported.get(key) == identity:
                return
            with path.open("rb") as stream:
                length = struct.unpack("<Q", stream.read(8))[0]
                if not 0 < length <= 16 * 1024 * 1024:
                    return
                header = json.loads(stream.read(length))
            if not isinstance(header, dict):
                return
            tensors = [value for name, value in header.items() if name != "__metadata__"]
            if not tensors:
                return
            if not all(
                isinstance(item, dict)
                and isinstance(item.get("data_offsets"), list)
                and len(item["data_offsets"]) == 2
                for item in tensors
            ):
                return
            ends = [item["data_offsets"][1] for item in tensors]
            if (
                not all(type(end) is int and end >= 0 for end in ends)
                or 8 + length + max(ends) != info.st_size
            ):
                return
            try:
                step = checkpoint_step(path, trainer)
            except ValueError:
                step = None
            self.reported[key] = identity
            log.info(
                "checkpoint observed",
                extra={
                    "run_id": state.run_id,
                    "service_name": state.name,
                    "step": step,
                    "size_bytes": info.st_size,
                },
            )
        except (
            AgentError,
            OSError,
            ValueError,
            TypeError,
            KeyError,
            struct.error,
            json.JSONDecodeError,
        ):
            return
