"""Source of the synthetic package used by the end-to-end tests (written to disk by the test)."""

INIT = '''
"""A synthetic package: closures from a factory, methods, a dataclass, a contextmanager, an Enum,
in-place tensor writes and a function that raises."""
from __future__ import annotations

import contextlib
import dataclasses
import enum

from . import helper

try:
    import torch
except ImportError:  # pragma: no cover
    torch = None
import numpy as np


class Mode(enum.Enum):
    FAST = "fast"
    SLOW = "slow"

    def label(self):
        return self.value.upper()


@dataclasses.dataclass
class Settings:
    scale: float
    mode: Mode = Mode.FAST
    tags: tuple = ()


def make_scaler(factor):
    def scale(values):
        def one(v):
            return v * factor
        return [one(v) for v in values]
    return scale


class Accumulator:
    def __init__(self, settings):
        self.settings = settings
        self.total = 0.0
        self.log = []
        self.buffer = np.zeros(4, dtype=np.float32)

    def add(self, x):
        self.total += x
        self.log.append(x)
        self.buffer[len(self.log) % 4] += x
        return self.total

    @property
    def mean(self):
        return self.total / max(len(self.log), 1)

    @staticmethod
    def clamp(x, lo=0.0, hi=10.0):
        return max(lo, min(hi, x))

    @classmethod
    def default(cls):
        return cls(Settings(scale=1.0))


@contextlib.contextmanager
def timer(name):
    state = {"name": name, "ticks": 0}
    yield state
    state["ticks"] += 1


def numbers(n):
    for i in range(n):
        yield i * i
    return "end"


def write_in_place(arr, bump):
    arr[0] += bump
    arr[1:3] *= 2
    return float(arr.sum())


def tensors():
    if torch is None:
        return 0.0
    t = torch.arange(24, dtype=torch.float32).reshape(1, 2, 3, 4, 1)
    helper.touch(t)
    with torch.inference_mode():
        u = torch.ones(2, 5, 3)
        helper.touch(u)
    return float(t.sum() + u.sum())


def fails(kind):
    if kind == "value":
        raise ValueError("bad value")
    return kind


def run():
    out = {}
    acc = Accumulator.default()
    scaler = make_scaler(3)
    for v in scaler([1, 2, 3]):
        acc.add(v)
    out["total"] = acc.total
    out["mean"] = acc.mean
    out["clamp"] = Accumulator.clamp(42)
    with timer("t") as st:
        out["gen"] = list(numbers(4))
    out["ticks"] = st["ticks"]
    arr = np.arange(6, dtype=np.float32)
    out["write"] = write_in_place(arr, 5)
    out["mode"] = Mode.SLOW.label()
    out["tensors"] = tensors()
    try:
        fails("value")
    except ValueError as exc:
        out["error"] = str(exc)
    out["ok"] = fails("fine")
    out["helper"] = helper.double(21)
    return out
'''

HELPER = """
def double(x):
    return x * 2


def touch(t):
    t.add_(1)
    return t
"""

DRIVER = """
import importlib.util
import json
import os
import sys

mode, root = sys.argv[1], sys.argv[2]
if os.environ.get("SCENARIO_TRACE") == "1":
    import podtrace.bootstrap  # what podtrace.pth runs
if mode == "import":
    sys.path.insert(0, root)
    import e2e_pkg as module
else:
    name = "my-pack v2!"
    path = os.path.join(root, "e2e_pkg", "__init__.py")
    spec = importlib.util.spec_from_file_location(
        name, path, submodule_search_locations=[os.path.dirname(path)]
    )
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
print(json.dumps(module.run(), sort_keys=True))
"""
