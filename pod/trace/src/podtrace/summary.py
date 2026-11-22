"""Value summaries and cheap change keys.

A summary is a small JSON-ready dict describing a value (never its contents for tensors, never
long text). A *key* is a small hashable tuple that changes when a value is replaced or, for the
shallow cases listed below, mutated; keys are how the recorder notices state changes without
holding references to old values.
"""

from __future__ import annotations

import enum
import hashlib
import itertools
import pathlib
import sys
import threading
import types
import weakref
from collections import OrderedDict
from functools import partial
from math import isfinite
from typing import Any

from . import tensors as tn


class Aliases:
    """First-seen small integers for objects, tensors and threads. Never an address."""

    def __init__(self) -> None:
        self.table: dict[int, tuple[int, weakref.ref[Any] | None]] = {}
        self._objects = itertools.count(1)
        self._threads = itertools.count(1)
        self._lock = threading.Lock()

    def alias(self, obj: object) -> int:
        k = id(obj)
        entry = self.table.get(k)
        if entry is not None:
            ref = entry[1]
            if ref is None or ref() is obj:
                return entry[0]
        n = next(self._objects)
        table = self.table

        def _drop(_ref: object, k: int = k, n: int = n) -> None:
            e = table.get(k)
            if e is not None and e[0] == n:
                table.pop(k, None)

        try:
            ref = weakref.ref(obj, _drop)
        except TypeError:
            ref = None
        table[k] = (n, ref)
        return n

    def new_thread(self) -> int:
        with self._lock:
            return next(self._threads)


class TensorCache:
    """Computed tensor summaries by ``(alias, version key)``, oldest dropped first."""

    def __init__(self, limit: int = 4096) -> None:
        self.limit = limit
        self.data: OrderedDict[Any, Any] = OrderedDict()

    def get(self, key: Any) -> Any:
        return self.data.get(key)

    def put(self, key: Any, value: Any) -> None:
        self.data[key] = value
        if len(self.data) > self.limit:
            for _ in range(self.limit // 8):
                self.data.popitem(last=False)


class Walk:
    """Budget of one top-level summary, so a huge argument cannot make a huge record."""

    __slots__ = ("nodes", "tensors")

    def __init__(self, nodes: int, tensors: int) -> None:
        self.nodes = nodes
        self.tensors = tensors


_SENSITIVE = (
    "token",
    "secret",
    "passw",
    "api_key",
    "apikey",
    "api-key",
    "auth",
    "credential",
    "bearer",
    "cookie",
    "private_key",
)


def is_sensitive(name: object) -> bool:
    s = str(name).lower()
    return any(p in s for p in _SENSITIVE)


def clsname(t: type) -> str:
    return f"{getattr(t, '__module__', '?')}.{getattr(t, '__qualname__', t.__name__)}"


def callable_name(v: Any) -> str:
    if isinstance(v, partial):
        return f"functools.partial({callable_name(v.func)})"
    inner = getattr(v, "__func__", v)
    mod = getattr(inner, "__module__", None) or getattr(
        getattr(v, "__self__", None), "__module__", ""
    )
    qn = (
        getattr(inner, "__qualname__", None) or getattr(inner, "__name__", None) or clsname(type(v))
    )
    return f"{mod}.{qn}" if mod else str(qn)


def sha12(data: bytes | str) -> str:
    raw = data.encode("utf-8", "surrogatepass") if isinstance(data, str) else data
    return hashlib.sha256(raw).hexdigest()[:12]


def attr_items(obj: Any, limit: int | None = None) -> list[tuple[str, Any]]:
    """Plain attributes of an object: ``__dict__`` and ``__slots__``; for nn.Module only public ones."""
    items: list[tuple[str, Any]] = []
    torch = sys.modules.get("torch")
    module_cls = getattr(getattr(torch, "nn", None), "Module", None)
    is_module = module_cls is not None and isinstance(obj, module_cls)
    d = getattr(obj, "__dict__", None)
    if isinstance(d, dict):
        for name, value in list(d.items()):
            if not isinstance(name, str) or name.startswith("__"):
                continue
            if is_module and name.startswith("_"):
                continue
            items.append((name, value))
            if limit is not None and len(items) >= limit:
                return items
    for klass in type(obj).__mro__:
        slots = klass.__dict__.get("__slots__", ())
        if isinstance(slots, str):
            slots = (slots,)
        for name in slots:
            if name in ("__dict__", "__weakref__") or name.startswith("__"):
                continue
            try:
                items.append((name, getattr(obj, name)))
            except AttributeError:
                continue
            if limit is not None and len(items) >= limit:
                return items
    return items


_PRIM_NAMES = {type(None): "none", bool: "bool", int: "int", float: "float"}


class Summarizer:
    def __init__(self, cfg: Any, aliases: Aliases, cache: TensorCache) -> None:
        self.cfg = cfg
        self.aliases = aliases
        self.cache = cache
        self.layout_for: Any = None  # set by plugins: shape -> layout or None
        self.on_error: Any = None

    # ------------------------------------------------------------------ summaries

    def summarize(
        self, value: Any, level: str, seen: set[Any], redact: bool = False
    ) -> dict[str, Any]:
        walk = Walk(self.cfg.max_nodes, self.cfg.max_tensors)
        return self._s(value, level, seen, walk, 0, redact)

    def _str(self, v: str, redact: bool) -> dict[str, Any]:
        out: dict[str, Any] = {"t": "str", "len": len(v), "sha": sha12(v)}
        if not redact and (len(v) <= 64 or self.cfg.text):
            out["v"] = v
        return out

    def _s(
        self, v: Any, level: str, seen: set[Any], w: Walk, depth: int, redact: bool
    ) -> dict[str, Any]:
        t = type(v)
        if v is None:
            return {"t": "none"}
        if t is bool:
            return {"t": "bool", "v": v}
        if t is int:
            return {"t": "int", "v": v}
        if t is float:
            return {
                "t": "float",
                "v": v if isfinite(v) else ("nan" if v != v else ("inf" if v > 0 else "-inf")),
            }
        if t is str:
            return self._str(v, redact)
        w.nodes -= 1
        if w.nodes < 0:
            return {"t": "cut", "cls": clsname(t)}
        if t is bytes or t is bytearray:
            return {"t": "bytes", "len": len(v), "sha": sha12(bytes(v))}
        if tn.is_torch_tensor(v):
            w.tensors -= 1
            if w.tensors < 0:
                return {"t": "cut", "cls": clsname(t)}
            return self._tensor(v, level, seen)
        mod = t.__module__
        if mod == "numpy":
            np = sys.modules.get("numpy")
            if np is not None:
                if isinstance(v, np.ndarray):
                    w.tensors -= 1
                    if w.tensors < 0:
                        return {"t": "cut", "cls": clsname(t)}
                    return tn.summarize_numpy(
                        v, level, self.aliases.alias(v), self.cfg, seen, self.layout_for
                    )
                if isinstance(v, np.generic):
                    return self._s(v.item(), level, seen, w, depth, redact)
        if isinstance(v, (list, tuple, set, frozenset)):
            return self._seq(v, level, seen, w, depth, redact)
        if isinstance(v, dict):
            return self._dict(v, level, seen, w, depth, redact)
        if isinstance(v, enum.Enum):
            return self._obj_repr(v, {"name": self._str(str(v.name), False)})
        if isinstance(v, pathlib.PurePath):
            return self._obj_repr(v, {"v": self._str(str(v), redact)})
        if mod == "torch" and t.__name__ in ("dtype", "device"):
            return self._obj_repr(v, {"v": self._str(str(v), False)})
        if isinstance(
            v, (types.FunctionType, types.BuiltinFunctionType, types.MethodType, partial)
        ):
            return {"t": "fn", "name": callable_name(v)}
        if isinstance(v, type):
            return {"t": "fn", "name": clsname(v)}
        if isinstance(v, types.ModuleType):
            return {"t": "obj", "cls": "builtins.module", "id": self.aliases.alias(v)}
        return self._obj(v, level, seen, w, depth, redact)

    def _obj_repr(self, v: Any, fields: dict[str, Any]) -> dict[str, Any]:
        return {
            "t": "obj",
            "cls": clsname(type(v)),
            "id": self.aliases.alias(v),
            "fields": fields,
        }

    def _tensor(self, v: Any, level: str, seen: set[Any]) -> dict[str, Any]:
        alias = self.aliases.alias(v)
        try:
            return tn.summarize_torch(v, level, alias, self.cfg, self.cache, seen, self.layout_for)
        except Exception as exc:
            if self.on_error is not None:
                self.on_error("tensor", exc)
            return tn.summarize_torch(v, "shape", alias, self.cfg, self.cache, seen, None)

    def _seq(
        self, v: Any, level: str, seen: set[Any], w: Walk, depth: int, redact: bool
    ) -> dict[str, Any]:
        if isinstance(v, (set, frozenset)):
            kind = "set"
        elif isinstance(v, tuple):
            kind = "tuple"
        else:
            kind = "list"
        n = len(v)
        if depth >= self.cfg.max_depth:
            return {"t": "cut", "cls": clsname(type(v)), "len": n}
        if kind == "set":
            try:
                chosen: list[Any] = sorted(itertools.islice(v, 32), key=repr)[: self.cfg.items]
            except Exception:
                chosen = []
        else:
            chosen = list(itertools.islice(v, self.cfg.items))
        return {
            "t": kind,
            "len": n,
            "items": [self._s(x, level, seen, w, depth + 1, redact) for x in chosen],
        }

    def _dict(
        self, v: dict[Any, Any], level: str, seen: set[Any], w: Walk, depth: int, redact: bool
    ) -> dict[str, Any]:
        n = len(v)
        if depth >= self.cfg.max_depth:
            return {"t": "cut", "cls": clsname(type(v)), "len": n}
        items: dict[str, Any] = {}
        for k, x in itertools.islice(list(v.items()), self.cfg.dict_items):
            ks = str(k) if isinstance(k, (str, int, float, bool)) else _short(k)
            items[ks] = self._s(x, level, seen, w, depth + 1, redact or is_sensitive(ks))
        return {"t": "dict", "len": n, "items": items}

    def _obj(
        self, v: Any, level: str, seen: set[Any], w: Walk, depth: int, redact: bool
    ) -> dict[str, Any]:
        out: dict[str, Any] = {"t": "obj", "cls": clsname(type(v)), "id": self.aliases.alias(v)}
        if depth == 0 and self.cfg.fields > 0:
            fields: dict[str, Any] = {}
            for name, x in attr_items(v, self.cfg.fields):
                fields[name] = self._s(x, level, seen, w, 1, redact or is_sensitive(name))
            if fields:
                out["fields"] = fields
        return out

    # ------------------------------------------------------------------ keys

    def key(self, v: Any, level: str) -> tuple[Any, ...]:
        """A small hashable stand-in for ``v``'s identity and shallow state."""
        t = type(v)
        name = _PRIM_NAMES.get(t)
        if name is not None:
            if t is float and v != v:
                return (0, name, "nan")
            return (0, name, v)
        if t is str:
            return (1, v) if len(v) <= 4096 else (1, len(v), hash(v))
        if t is bytes or t is bytearray:
            return (1, len(v), hash(bytes(v)))
        if tn.is_torch_tensor(v):
            alias = self.aliases.alias(v)
            try:
                inference = bool(v.is_inference())
                ver = None if inference else int(v._version)
            except Exception:
                ver = None
            return (
                2,
                alias,
                ver,
                tuple(v.shape),
                str(v.dtype).removeprefix("torch."),
                str(v.device),
            )
        if t.__module__ == "numpy" and tn.is_numpy_array(v):
            return (2, self.aliases.alias(v), None, tuple(v.shape), str(v.dtype), "cpu")
        if isinstance(v, (list, tuple)):
            sample = tuple(_item_key(x) for x in itertools.islice(v, 32))
            return (3, self.aliases.alias(v), t.__name__, len(v), sample)
        if isinstance(v, (set, frozenset)):
            return (3, self.aliases.alias(v), t.__name__, len(v), ())
        if isinstance(v, dict):
            sample = tuple(
                (_hash(k), _item_key(x)) for k, x in itertools.islice(list(v.items()), 32)
            )
            return (4, self.aliases.alias(v), "dict", len(v), sample)
        if isinstance(
            v, (types.FunctionType, types.BuiltinFunctionType, types.MethodType, partial, type)
        ):
            return (6, callable_name(v) if not isinstance(v, type) else clsname(v), id(v))
        return (5, self.aliases.alias(v), clsname(t))

    def from_key(self, key: tuple[Any, ...], level: str) -> dict[str, Any]:
        """Best available summary of a value that is gone, rebuilt from its key."""
        kind = key[0]
        if kind == 0:
            return self._s(_prim(key), level, set(), Walk(4, 0), 0, False)
        if kind == 1:
            if isinstance(key[1], str) and len(key) == 2:
                return self._str(key[1], False)
            return {"t": "str", "len": key[1]}
        if kind == 2:
            _, alias, ver, shape, dtype, device = key
            hit = self.cache.get((alias, ("v", ver))) if ver is not None else None
            body = hit[1] if hit else {}
            out: dict[str, Any] = {
                "t": "tensor",
                "id": alias,
                "ver": ver or 0,
                "shape": list(shape),
                "dtype": dtype,
                "device": device,
            }
            for k, x in body.items():
                if k not in ("profile", "segments"):
                    out[k] = x
            return out
        if kind == 3:
            return {"t": key[2] if key[2] in ("list", "tuple", "set") else "list", "len": key[3]}
        if kind == 4:
            return {"t": "dict", "len": key[3]}
        if kind == 6:
            return {"t": "fn", "name": key[1]}
        return {"t": "obj", "cls": key[2], "id": key[1]}


def _prim(key: tuple[Any, ...]) -> Any:
    name, value = key[1], key[2]
    if name == "float" and value == "nan":
        return float("nan")
    return value


def _hash(k: Any) -> int:
    try:
        return hash(k)
    except TypeError:
        return 0


def _short(k: Any) -> str:
    text = str(k)
    return text if len(text) <= 80 else text[:77] + "..."


def _item_key(x: Any) -> Any:
    t = type(x)
    if t in _PRIM_NAMES:
        if t is float and x != x:
            return (t.__name__, "nan")
        return (t.__name__, x)
    return id(x)
