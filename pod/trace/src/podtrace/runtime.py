"""The recorder: wrappers that instrumented code calls, records, run directories.

Rules this module keeps:

* Nothing in here may change what the traced program does. Every recorder step runs with the
  per-thread ``busy`` flag set, so traced functions called by the recorder itself (through
  ``__len__``, properties and so on) pass straight through; any exception inside a step is caught,
  counted and reported once per kind as a ``mark`` record.
* With recording off, every wrapper is one boolean check and a direct call.
* No OpenTelemetry object is held while traced code runs: spans are built from finished records.
"""

from __future__ import annotations

import atexit
import contextvars
import functools
import inspect
import itertools
import os
import platform
import random
import sys
import threading
import time
from typing import Any

from . import __version__, deep
from .config import Config
from .control import Control
from .registry import TABLES, FileTable, SiteInfo
from .sinks import JsonlSink, LogfireSink
from .summary import Aliases, Summarizer, TensorCache, attr_items, clsname

SCHEMA_VERSION = 1
MAX_KEYED_ATTRS = 256
MAX_KEYED_ITEMS = 64
MAX_ARRAY_WATCH = 1 << 24  # numpy arrays up to this many elements are compared after each call


class _TLS(threading.local):
    busy = False
    alias = 0
    alias_owner: Any = None


_tls = _TLS()
_CTX: contextvars.ContextVar[Any] = contextvars.ContextVar("podtrace_ctx", default=None)
_SUPPRESS = (
    object()
)  # context value: a call over the per-parent cap; everything below passes through
_CAPPED = object()  # _begin result: the call is over the cap
_KEEP = object()  # async generators: leave the context alone


class _State:
    """Process-wide recorder state. ``on`` is the only attribute wrappers read when idle."""

    def __init__(self) -> None:
        self.on = False
        self.cfg: Config | None = None
        self.configured = False
        self.failed = False
        self.control: Control | None = None
        self.aliases = Aliases()
        self.cache = TensorCache()
        self.summ: Summarizer | None = None
        self.jsonl: JsonlSink | None = None
        self.logfire: LogfireSink | None = None
        self.seq = itertools.count(1)
        self.rng = random.Random(int.from_bytes(os.urandom(8), "little"))
        self.errors: dict[str, int] = {}
        self.error_marked: set[str] = set()
        self.run_ident: tuple[int, str | None] | None = None
        self.run_label: str | None = None
        self.run_started_ns = 0
        self.meta_dirty = False
        self.rotate_lock = threading.RLock()
        self.layout_providers: list[Any] = []
        self.init_hooks: list[Any] = []
        self.started_ns = time.time_ns()
        self.plugin_names: list[str] = []
        self.warned_deep = False
        self.stop = threading.Event()


state = _State()
_comp: list[Any] = [None]


def _stderr(msg: str) -> None:
    try:  # noqa: SIM105
        sys.stderr.write(f"podtrace: {msg}\n")
    except Exception:
        pass


# --------------------------------------------------------------------------------- configuration


def configure() -> bool:
    """Set the recorder up once, from the config the hook stored. False if unusable."""
    if state.configured:
        return not state.failed
    with state.rotate_lock:
        if state.configured:
            return not state.failed
        state.configured = True
        from . import registry

        cfg = registry.CONFIG
        if cfg is None:
            state.failed = True
            return False
        try:
            state.cfg = cfg
            state.control = Control(cfg.control_file)
            state.summ = Summarizer(cfg, state.aliases, state.cache)
            state.summ.on_error = report_error
            state.summ.layout_for = _layout_for
            state.jsonl = JsonlSink(cfg) if cfg.jsonl else None
            state.logfire = LogfireSink(cfg) if cfg.logfire else None
            for name in cfg.plugins:
                _load_plugin(name)
            state.control.refresh()
            state.on = state.control.record
            t = threading.Thread(
                target=_poll_control, args=(state.stop,), name="podtrace-control", daemon=True
            )
            t.start()
            atexit.register(shutdown)
            if hasattr(os, "register_at_fork"):
                os.register_at_fork(after_in_child=_after_fork)
        except Exception as exc:
            state.failed = True
            state.on = False
            _stderr(f"disabled, setup failed: {type(exc).__name__}: {exc}")
            return False
        return True


def _load_plugin(name: str) -> None:
    import importlib

    module = importlib.import_module(name if "." in name else f"podtrace.plugins.{name}")
    module.install(sys.modules[__name__])
    state.plugin_names.append(name)


def add_layout_provider(fn: Any) -> None:
    """Plugins: ``fn(shape) -> layout or None`` with ``axis``, ``edges`` and ``segments``."""
    state.layout_providers.append(fn)


def add_init_hook(fn: Any) -> None:
    """Plugins: ``fn(obj, name) -> dict or None``, called after each traced ``__init__``."""
    state.init_hooks.append(fn)


def _layout_for(shape: tuple[int, ...]) -> Any:
    for provider in state.layout_providers:
        try:
            found = provider(shape)
        except Exception as exc:
            report_error("plugin", exc)
            continue
        if found is not None:
            return found
    return None


def _poll_control(stop: threading.Event) -> None:
    cfg = state.cfg
    ctl = state.control
    assert cfg is not None and ctl is not None
    last_error: str | None = None
    while not stop.wait(cfg.control_poll_s):
        try:
            ctl.refresh()
            state.on = ctl.record and not state.failed
            if ctl.error and ctl.error != last_error:
                _stderr(f"control file ignored: {ctl.error}")
            last_error = ctl.error
        except Exception:
            pass


def _reset() -> None:
    """Return to the state before ``configure`` (tests; also drops the poller thread)."""
    state.stop.set()
    state.on = False
    state.__init__()  # type: ignore[misc]
    _comp[0] = None
    deep._reset()


def _after_fork() -> None:
    state.on = False
    state.jsonl = None
    state.logfire = None


# --------------------------------------------------------------------------------- errors and marks


def report_error(kind: str, exc: BaseException | str) -> None:
    """Count a recorder failure; the first of each kind becomes a ``mark`` record."""
    n = state.errors.get(kind, 0) + 1
    state.errors[kind] = n
    if kind in state.error_marked:
        return
    state.error_marked.add(kind)
    text = f"{type(exc).__name__}: {exc}" if isinstance(exc, BaseException) else str(exc)
    _stderr(f"recorder error ({kind}): {text[:200]}")
    try:  # noqa: SIM105
        _emit_mark(_CTX.get(), "podtrace.error", {"error": kind, "msg": text[:300]})
    except Exception:
        pass


def _thread_alias() -> int:
    """Small integer for this thread, in first-seen order (not the OS id, which is reused)."""
    owner = state.aliases
    if _tls.alias_owner is not owner:
        _tls.alias = owner.new_thread()
        _tls.alias_owner = owner
    return _tls.alias


def _emit_mark(parent: Any, name: str, attrs: dict[str, Any]) -> None:
    if state.jsonl is None and state.logfire is None:
        return
    if parent is _SUPPRESS or parent is None:
        parent = None
    now = time.time_ns()
    trace_id = parent.trace.id if parent is not None else _hex(state.rng.getrandbits(128), 32)
    rec = {
        "v": SCHEMA_VERSION,
        "kind": "mark",
        "seq": next(state.seq),
        "trace_id": trace_id,
        "span_id": _hex(state.rng.getrandbits(64) or 1, 16),
        "parent_id": parent.span_id if parent is not None else None,
        "name": name,
        "module": __name__,
        "file": __file__,
        "line": 0,
        "start_ns": now,
        "end_ns": now,
        "thread": _thread_alias(),
        "label": parent.label if parent is not None else state.run_label,
        "args": {},
        "ret": None,
        "exc": None,
        "state": [],
        "attrs": attrs,
    }
    _write(rec)


def _hex(value: int, width: int) -> str:
    return f"{value:0{width}x}"


def _write(rec: dict[str, Any]) -> None:
    if state.jsonl is not None:
        state.jsonl.write(rec)
    if state.logfire is not None and state.logfire.active:
        state.logfire.emit(rec)


# --------------------------------------------------------------------------------- runs


def _root_start() -> bool:
    """Called at the start of each root span: re-read the control file, rotate the run if needed."""
    ctl = state.control
    assert ctl is not None
    ctl.refresh()
    state.on = ctl.record and not state.failed
    if not state.on:
        return False
    ident = (ctl.session, ctl.label)
    if ident != state.run_ident:
        with state.rotate_lock:
            if ident != state.run_ident:
                _rotate(ident, ctl.label)
    return True


def _rotate(ident: tuple[int, str | None], label: str | None) -> None:
    """Close the current run and open a new one: fresh aliases, sequence and run directory.

    ``run_ident`` is set last: other threads that see it may start writing at once.
    """
    _close_run()
    state.run_ident = None
    state.aliases = Aliases()
    state.cache = TensorCache()
    assert state.summ is not None
    state.summ.aliases = state.aliases
    state.summ.cache = state.cache
    state.seq = itertools.count(1)
    state.errors = {}
    state.error_marked = set()
    state.run_label = label
    state.run_started_ns = time.time_ns()
    if state.jsonl is not None:
        state.jsonl.open_run(label)
        _write_meta()
    if state.logfire is not None and not state.logfire.active and state.logfire.reason == "":
        try:
            state.logfire.start()
        except Exception as exc:
            _stderr(f"Logfire export disabled: {type(exc).__name__}: {exc}")
            state.logfire = None
    state.run_ident = ident


def _close_run() -> None:
    if state.run_ident is None:
        return
    for kind, n in state.errors.items():
        if n > 1:
            try:  # noqa: SIM105
                _emit_mark(None, "podtrace.error.count", {"error": kind, "count": n})
            except Exception:
                pass
    if state.jsonl is not None:
        state.jsonl.flush()
        _write_meta()
        state.jsonl.close()
    if state.logfire is not None and state.logfire.active:
        try:
            state.logfire.flush()
        except Exception as exc:
            _stderr(f"Logfire flush failed: {type(exc).__name__}: {exc}")


def _versions() -> dict[str, str]:
    out = {}
    for name in ("torch", "numpy", "logfire", "comfy"):
        mod = sys.modules.get(name)
        if mod is not None:
            out[name] = str(getattr(mod, "__version__", "?"))
    return out


def _write_meta() -> None:
    if state.jsonl is None or state.cfg is None:
        return
    files = [
        {
            "path": t.path,
            "sha256": t.sha256,
            "include": t.rule.path,
            "stats": t.rule.stats,
            "sites": len(t.sites),
        }
        for t in list(TABLES.values())
    ]
    meta = {
        "schema": SCHEMA_VERSION,
        "podtrace": __version__,
        "python": sys.version,
        "platform": platform.platform(),
        "libraries": _versions(),
        "label": state.run_label,
        "started_ns": state.run_started_ns,
        "process_started_ns": state.started_ns,
        "pid": os.getpid(),
        "argv0": sys.argv[0] if sys.argv else "",
        "plugins": state.plugin_names,
        "config": _config_snapshot(state.cfg),
        "logfire": {
            "active": bool(state.logfire and state.logfire.active),
            "reason": state.logfire.reason if state.logfire else "disabled in config",
        },
        "deep_available": deep.available(),
        "files": files,
    }
    state.jsonl.write_meta(meta)
    state.meta_dirty = False


def _config_snapshot(cfg: Config) -> dict[str, Any]:
    raw = dict(cfg.raw)
    raw["_source"] = cfg.source
    return raw


def shutdown() -> None:
    """At exit: stop recording, flush and close everything."""
    state.on = False
    with state.rotate_lock:
        try:
            _close_run()
        except Exception as exc:
            _stderr(f"close failed: {type(exc).__name__}: {exc}")
        if state.logfire is not None:
            try:
                state.logfire.shutdown()
            except Exception as exc:
                _stderr(f"Logfire shutdown failed: {type(exc).__name__}: {exc}")
        state.run_ident = None


def end_of_root() -> None:
    if state.jsonl is not None:
        state.jsonl.flush()
        if state.meta_dirty:
            _write_meta()
    if state.logfire is not None and state.logfire.active:
        try:
            state.logfire.flush()
        except Exception as exc:
            report_error("logfire_flush", exc)


# --------------------------------------------------------------------------------- sites


class Site:
    """A traced ``def``, bound to the module it was executed in."""

    __slots__ = (
        "deep",
        "deep_gen",
        "file",
        "id",
        "is_init",
        "is_method",
        "kind",
        "line",
        "module",
        "name",
        "plan",
        "qual",
        "shape",
        "stats",
    )

    _ids = itertools.count(1)

    def __init__(self, info: SiteInfo, table: FileTable, module: str) -> None:
        self.id = next(Site._ids)
        self.qual = info.qualname
        self.name = f"{module}.{info.qualname}"
        self.module = module
        self.file = table.path
        self.line = info.lineno
        self.shape = info.shape
        self.is_method = info.is_method
        self.is_init = info.is_init
        self.kind = "init" if info.is_init else ("gen" if info.shape in "gca" else "call")
        self.stats = table.rule.stats
        self.deep = False
        self.deep_gen = -1
        self.plan: Any = None


class FileSites:
    """What ``__podtrace_s__`` is in an instrumented module: the decorator factory."""

    def __init__(self, table: FileTable, module: str) -> None:
        self.table = table
        self.module = module
        self._decos: dict[int, Any] = {}

    def d(self, idx: int) -> Any:
        deco = self._decos.get(idx)
        if deco is None:
            site = Site(self.table.sites[idx], self.table, self.module)
            deco = self._decos[idx] = _decorator_for(site)
        return deco

    def c(self, idx: int) -> Any:
        deco = self._decos.get(-1 - idx)
        if deco is None:
            info = self.table.sites[idx]
            site = Site(info, self.table, self.module)
            deco = self._decos[-1 - idx] = _class_decorator(site)
        return deco


class _NullSites:
    """Used when the recorder could not be set up: decorators that change nothing."""

    def d(self, idx: int) -> Any:
        return _identity

    c = d


def _identity(obj: Any) -> Any:
    return obj


def register(path: str, module: str) -> Any:
    """First statement of every instrumented module."""
    try:
        if not configure():
            return _NullSites()
        table = TABLES[path]
        state.meta_dirty = True
        return FileSites(table, module)
    except Exception as exc:
        _stderr(f"could not register {path}: {type(exc).__name__}: {exc}")
        return _NullSites()


# --------------------------------------------------------------------------------- argument binding


def _plan(fn: Any) -> tuple[Any, ...] | None:
    """Parameter names, taken from the code object, so binding costs a dict fill."""
    code = getattr(fn, "__code__", None)
    if code is None:
        return None
    n_pos = code.co_argcount
    n_kw = code.co_kwonlyargcount
    names = code.co_varnames[: n_pos + n_kw]
    idx = n_pos + n_kw
    vararg = code.co_varnames[idx] if code.co_flags & inspect.CO_VARARGS else None
    idx += 1 if vararg else 0
    varkw = code.co_varnames[idx] if code.co_flags & inspect.CO_VARKEYWORDS else None
    return (names, n_pos, vararg, varkw, fn.__defaults__ or (), fn.__kwdefaults__ or {})


def _bind(plan: Any, args: tuple[Any, ...], kwargs: dict[str, Any]) -> dict[str, Any]:
    names, n_pos, vararg, varkw, defaults, kwdefaults = plan
    bound: dict[str, Any] = {}
    for i in range(min(len(args), n_pos)):
        bound[names[i]] = args[i]
    extra: dict[str, Any] = {}
    for k, v in kwargs.items():
        if k in names and k not in bound:
            bound[k] = v
        else:
            extra[k] = v
    first_default = n_pos - len(defaults)
    for i, name in enumerate(names):
        if name in bound:
            continue
        if i < n_pos:
            if i >= first_default:
                bound[name] = defaults[i - first_default]
        elif name in kwdefaults:
            bound[name] = kwdefaults[name]
    out = {name: bound[name] for name in names if name in bound}
    if vararg:
        out[vararg] = tuple(args[n_pos:])
    if varkw:
        out[varkw] = extra
    return out


# --------------------------------------------------------------------------------- records in flight


class Trace:
    """One root span and everything under it: the id and what was already shown in full."""

    __slots__ = ("id", "seen")

    def __init__(self, trace_id: str) -> None:
        self.id = trace_id
        self.seen: set[Any] = set()


class Rec:
    __slots__ = (
        "arg_watch",
        "args",
        "bound",
        "caps",
        "deep",
        "label",
        "parent",
        "self_keys",
        "self_obj",
        "seq",
        "site",
        "span_id",
        "start_ns",
        "trace",
    )


def _skip_now() -> bool:
    """True while torch is compiling, scripting or symbolically tracing: pass straight through."""
    check = _comp[0]
    if check is None:
        torch = sys.modules.get("torch")
        if torch is None:
            return False
        check = _comp[0] = _make_compile_check(torch)
    return check()


def _make_compile_check(torch: Any) -> Any:
    funcs = []
    for path in (("compiler", "is_compiling"), ("jit", "is_scripting")):
        obj: Any = torch
        for part in path:
            obj = getattr(obj, part, None)
        if callable(obj):
            funcs.append(obj)
    # ``is_fx_tracing`` itself logs a warning on recent versions; use the quiet spelling only.
    fx = getattr(getattr(torch, "fx", None), "_symbolic_trace", None)
    fx_check = getattr(fx, "is_fx_tracing_symbolic_tracing", None)
    if callable(fx_check):
        funcs.append(fx_check)
    elif fx is not None and hasattr(fx, "_is_fx_tracing_flag"):
        funcs.append(lambda: bool(fx._is_fx_tracing_flag))

    def check() -> bool:
        try:
            return any(f() for f in funcs)
        except Exception:
            return False

    return check


def _begin(site: Site, fn: Any, args: tuple[Any, ...], kwargs: dict[str, Any], parent: Any) -> Any:
    """Start a record. Returns a ``Rec``, ``_CAPPED`` or None (not recorded)."""
    _tls.busy = True
    try:
        cfg = state.cfg
        assert cfg is not None and state.summ is not None
        if parent is None:
            if not _root_start():
                return None
            trace = Trace(_hex(state.rng.getrandbits(128) or 1, 32))
            label = state.control.label if state.control else None
        else:
            trace = parent.trace
            label = parent.label
            caps = parent.caps
            count = caps.get(site.id, 0) + 1
            caps[site.id] = count
            if count > cfg.per_parent_cap:
                if count == cfg.per_parent_cap + 1:
                    parent.caps[-site.id] = site.name  # remember the name for the mark
                return _CAPPED
        rec = Rec()
        rec.seq = next(state.seq)
        rec.span_id = _hex(state.rng.getrandbits(64) or 1, 16)
        rec.site = site
        rec.parent = parent
        rec.trace = trace
        rec.label = label
        rec.caps = {}
        rec.arg_watch = None
        rec.self_keys = None
        rec.self_obj = None
        rec.deep = False
        if site.plan is None:
            site.plan = _plan(fn) or ()
        bound = _bind(site.plan, args, kwargs) if site.plan else {}
        level = site.stats
        summ = state.summ
        seen = trace.seen
        summaries: dict[str, Any] = {}
        for name, value in bound.items():
            summaries[name] = summ.summarize(value, level, seen, _redact(name))
        rec.args = summaries
        rec.bound = bound
        first = next(iter(bound), None)
        if site.is_method and first is not None:
            obj = bound[first]
            rec.self_obj = obj
            if not site.is_init:
                rec.self_keys = _attr_keys(summ, obj, level)
        rec.arg_watch = _watch_args(summ, bound, summaries, site.is_method, level)
        ctl = state.control
        if ctl is not None and ctl.deep:
            if site.deep_gen != ctl.deep_gen:
                site.deep = _deep_match(site, ctl.deep)
                site.deep_gen = ctl.deep_gen
            if site.deep:
                if deep.available():
                    rec.deep = True
                elif not state.warned_deep:
                    state.warned_deep = True
                    report_error("deep_unavailable", "deep mode needs Python 3.12 or newer")
        rec.start_ns = time.time_ns()
        return rec
    except Exception as exc:
        report_error("begin", exc)
        return None
    finally:
        _tls.busy = False


def _redact(name: str) -> bool:
    from .summary import is_sensitive

    return is_sensitive(name)


def _deep_match(site: Site, patterns: tuple[str, ...]) -> bool:
    import fnmatch

    return any(
        fnmatch.fnmatchcase(site.name, p) or fnmatch.fnmatchcase(site.qual, p) for p in patterns
    )


def _attr_keys(summ: Summarizer, obj: Any, level: str) -> dict[str, Any] | None:
    try:
        items = attr_items(obj, MAX_KEYED_ATTRS)
    except Exception:
        return None
    return {name: summ.key(value, level) for name, value in items}


def _watch_args(
    summ: Summarizer, bound: dict[str, Any], summaries: dict[str, Any], is_method: bool, level: str
) -> list[Any] | None:
    """What to compare after the call for mutable arguments."""
    watch: list[Any] = []
    names = list(bound)
    if is_method and names:
        names = names[1:]
    for name in names:
        value = bound[name]
        t = type(value)
        if t is dict:
            if len(value) <= MAX_KEYED_ITEMS:
                watch.append(
                    ("dict", name, value, {k: summ.key(v, level) for k, v in list(value.items())})
                )
        elif t is list:
            if len(value) <= MAX_KEYED_ITEMS:
                watch.append(("list", name, value, [summ.key(v, level) for v in list(value)]))
        elif _is_tensor(value):
            watch.append(("tensor", name, value, _tensor_stamp(value, summ)))
        elif _is_ndarray(value) and value.size <= MAX_ARRAY_WATCH:
            watch.append(("tensor", name, value, ("n", None)))
    return watch or None


def _is_tensor(v: object) -> bool:
    from . import tensors

    return tensors.is_torch_tensor(v)


def _is_ndarray(v: object) -> bool:
    from . import tensors

    return tensors.is_numpy_array(v)


def _tensor_stamp(t: Any, summ: Summarizer) -> tuple[Any, ...]:
    """Version counter, or for inference tensors a probe (None when it cannot be taken)."""
    from . import tensors

    try:
        if t.is_inference():
            cfg = state.cfg
            mode = cfg.inference_check if cfg else "probe"
            if mode == "probe" and t.numel() > tensors.PROBE_MIN and t.is_contiguous():
                return ("p", tensors.torch_probe(t))
            return ("i", mode)
        return ("v", int(t._version))
    except Exception:
        return ("?", None)


def _deep_enter(rec: Rec, fn: Any, frame: Any = None) -> None:
    try:
        deep.enter(rec, fn, frame)
    except Exception as exc:
        report_error("deep", exc)


def _deep_leave(rec: Rec, exc: BaseException | None = None) -> None:
    try:
        deep.leave(rec, exc)
    except Exception as exc:
        report_error("deep", exc)


# --------------------------------------------------------------------------------- finishing


def _exc_dict(exc: BaseException) -> dict[str, Any]:
    try:
        msg = str(exc)
    except Exception:
        msg = "<unprintable>"
    return {"type": type(exc).__name__, "msg": msg[:200]}


def _finish(
    rec: Rec,
    result: Any,
    exc: BaseException | None,
    *,
    yields: int | None = None,
) -> None:
    """Complete a record and write it. Never raises."""
    end_ns = time.time_ns()
    _tls.busy = True
    try:
        _finish_inner(rec, result, exc, yields, end_ns)
    except Exception as err:
        report_error("finish", err)
    finally:
        _tls.busy = False
    if rec.parent is None:
        _tls.busy = True
        try:
            end_of_root()
        except Exception as err:
            report_error("flush", err)
        finally:
            _tls.busy = False


def _finish_inner(
    rec: Rec, result: Any, exc: BaseException | None, yields: int | None, end_ns: int
) -> None:
    site = rec.site
    summ = state.summ
    assert summ is not None
    level = site.stats
    seen = rec.trace.seen
    attrs: dict[str, Any] = {}
    states: list[dict[str, Any]] = []
    ret: dict[str, Any] | None = None
    exc_d: dict[str, Any] | None = None
    if exc is not None:
        exc_d = _exc_dict(exc)
    elif yields is not None:
        ret = {"t": "gen", "yields": yields}
        if result is not None:
            attrs["return"] = summ.summarize(result, level, seen)
    elif site.is_init:
        ret = {"t": "none"}
    else:
        ret = summ.summarize(result, level, seen)

    if site.is_init and rec.self_obj is not None:
        for name, value in attr_items(rec.self_obj, MAX_KEYED_ATTRS):
            states.append(
                {
                    "target": "self",
                    "attr": name,
                    "before": None,
                    "after": summ.summarize(value, level, seen, _redact(name)),
                }
            )
        for hook in state.init_hooks:
            try:
                extra = hook(rec.self_obj, site.name)
            except Exception as err:
                report_error("plugin", err)
                continue
            if extra:
                attrs.update(extra)
    elif rec.self_keys is not None and rec.self_obj is not None:
        states.extend(_diff_attrs(summ, rec, level, seen))
    if rec.arg_watch:
        states.extend(_diff_args(summ, rec, level, seen))

    record = {
        "v": SCHEMA_VERSION,
        "kind": site.kind,
        "seq": rec.seq,
        "trace_id": rec.trace.id,
        "span_id": rec.span_id,
        "parent_id": rec.parent.span_id if rec.parent is not None else None,
        "name": site.name,
        "module": site.module,
        "file": site.file,
        "line": site.line,
        "start_ns": rec.start_ns,
        "end_ns": end_ns,
        "thread": _thread_alias(),
        "label": rec.label,
        "args": rec.args,
        "ret": ret,
        "exc": exc_d,
        "state": states,
        "attrs": attrs,
    }
    _write(record)
    # Calls over the cap are reported under their parent when it ends.
    for key, value in list(rec.caps.items()):
        if key < 0:
            site_id = -key
            total = rec.caps.get(site_id, 0)
            cfg = state.cfg
            assert cfg is not None
            _emit_mark(
                rec,
                "podtrace.cap",
                {
                    "function": value,
                    "calls": total,
                    "recorded": cfg.per_parent_cap,
                    "skipped": total - cfg.per_parent_cap,
                },
            )


def _diff_attrs(summ: Summarizer, rec: Rec, level: str, seen: set[Any]) -> list[dict[str, Any]]:
    before = rec.self_keys or {}
    out: list[dict[str, Any]] = []
    items = dict(attr_items(rec.self_obj, MAX_KEYED_ATTRS))
    for name in before.keys() | items.keys():
        old = before.get(name)
        if name in items:
            new_key = summ.key(items[name], level)
            if old is not None and new_key == old:
                continue
            after = summ.summarize(items[name], level, seen, _redact(name))
        else:
            after = None
        out.append(
            {
                "target": "self",
                "attr": name,
                "before": summ.from_key(old, level) if old is not None else None,
                "after": after,
            }
        )
    out.sort(key=lambda e: e["attr"])
    return out


def _diff_args(summ: Summarizer, rec: Rec, level: str, seen: set[Any]) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    for kind, name, value, stamp in rec.arg_watch or ():
        target = f"arg:{name}"
        if kind == "dict":
            now = {k: summ.key(v, level) for k, v in list(value.items())}
            for k in stamp.keys() | now.keys():
                if stamp.get(k) == now.get(k):
                    continue
                out.append(
                    {
                        "target": target,
                        "attr": f"[{k}]",
                        "before": summ.from_key(stamp[k], level) if k in stamp else None,
                        "after": summ.summarize(value[k], level, seen) if k in now else None,
                    }
                )
        elif kind == "list":
            now_list = [summ.key(v, level) for v in list(value)]
            if now_list == stamp:
                continue
            for i in range(max(len(stamp), len(now_list))):
                a = stamp[i] if i < len(stamp) else None
                b = now_list[i] if i < len(now_list) else None
                if a == b:
                    continue
                out.append(
                    {
                        "target": target,
                        "attr": f"[{i}]",
                        "before": summ.from_key(a, level) if a is not None else None,
                        "after": summ.summarize(value[i], level, seen) if b is not None else None,
                    }
                )
        else:
            changed = _tensor_changed(summ, value, stamp, rec.args.get(name), level, seen)
            if changed is not None:
                out.append(
                    {
                        "target": target,
                        "attr": "",
                        "before": rec.args.get(name),
                        "after": changed,
                    }
                )
    return out


_STAT_KEYS = ("mean", "std", "absmean", "min", "max", "nan", "inf")


def _tensor_changed(
    summ: Summarizer, t: Any, stamp: tuple[Any, ...], before: Any, level: str, seen: set[Any]
) -> dict[str, Any] | None:
    """The new summary when the tensor was written in place during the call, else None.

    A tensor with a version counter is compared by it. One without (an inference tensor, or a
    numpy array) is compared by a sampled probe when it is large, else summarized again and
    compared by fingerprint (``full``) or statistics (``basic``).
    """
    from . import tensors

    kind = stamp[0]
    if kind == "v":
        try:
            if int(t._version) == stamp[1]:
                return None
        except Exception:
            return None
        return summ.summarize(t, level, seen)
    if level == "shape" or kind == "?" or (kind == "i" and stamp[1] == "trust"):
        return None
    if kind == "p" and tensors.torch_probe(t) == stamp[1]:
        return None
    if not isinstance(before, dict) or before.get("t") not in ("tensor", "ndarray"):
        return None
    after = summ.summarize(t, level, seen)
    if "fp" in before and "fp" in after:
        return after if before["fp"] != after["fp"] else None
    if any(before.get(k) != after.get(k) for k in _STAT_KEYS):
        return after
    return None


# --------------------------------------------------------------------------------- wrappers


def _decorator_for(site: Site) -> Any:
    shape = site.shape
    if shape == "f":
        return _plain_decorator(site)
    if shape == "g":
        return _gen_decorator(site)
    if shape == "c":
        return _coro_decorator(site)
    return _agen_decorator(site)


def _mark_wrapper(wrapper: Any, site: Site) -> Any:
    try:  # noqa: SIM105
        wrapper.__podtrace__ = site.name
    except Exception:
        pass
    return wrapper


def _plain_decorator(site: Site) -> Any:
    def decorate(fn: Any) -> Any:
        @functools.wraps(fn)
        def wrapper(*args: Any, **kwargs: Any) -> Any:
            if not state.on:
                return fn(*args, **kwargs)
            if _tls.busy or _skip_now():
                return fn(*args, **kwargs)
            parent = _CTX.get()
            if parent is _SUPPRESS:
                return fn(*args, **kwargs)
            rec = _begin(site, fn, args, kwargs, parent)
            if rec is None:
                return fn(*args, **kwargs)
            if rec is _CAPPED:
                _CTX.set(_SUPPRESS)
                try:
                    return fn(*args, **kwargs)
                finally:
                    _CTX.set(parent)
            _CTX.set(rec)
            if rec.deep:
                _deep_enter(rec, fn)
            try:
                result = fn(*args, **kwargs)
            except BaseException as exc:
                _CTX.set(parent)
                if rec.deep:
                    _deep_leave(rec, exc)
                _finish(rec, None, exc)
                raise
            _CTX.set(parent)
            if rec.deep:
                _deep_leave(rec)
            _finish(rec, result, None)
            return result

        return _mark_wrapper(wrapper, site)

    return decorate


def _delegate(inner: Any, ctx: Any, counter: list[int]) -> Any:
    """Drive a generator by hand so the span context is set only while its body runs."""
    sent: Any = None
    pending: BaseException | None = None
    while True:
        prev = _CTX.get()
        _CTX.set(ctx)
        try:
            if pending is not None:
                err, pending = pending, None
                value = inner.throw(err)
            else:
                value = inner.send(sent)
        except StopIteration as stop:
            return stop.value
        finally:
            _CTX.set(prev)
        counter[0] += 1
        try:
            sent = yield value
        except GeneratorExit:
            inner.close()
            raise
        except BaseException as err:
            pending, sent = err, None


def _gen_decorator(site: Site) -> Any:
    def decorate(fn: Any) -> Any:
        @functools.wraps(fn)
        def wrapper(*args: Any, **kwargs: Any) -> Any:
            if not state.on or _tls.busy or _skip_now():
                return (yield from fn(*args, **kwargs))
            parent = _CTX.get()
            if parent is _SUPPRESS:
                return (yield from fn(*args, **kwargs))
            rec = _begin(site, fn, args, kwargs, parent)
            if rec is None:
                return (yield from fn(*args, **kwargs))
            counter = [0]
            if rec is _CAPPED:
                return (yield from _delegate(fn(*args, **kwargs), _SUPPRESS, counter))
            inner = fn(*args, **kwargs)
            if rec.deep:
                _deep_enter(rec, fn, getattr(inner, "gi_frame", None))
            try:
                value = yield from _delegate(inner, rec, counter)
            except GeneratorExit:
                _end_gen(rec, counter[0], None, None)
                raise
            except BaseException as exc:
                _end_gen(rec, counter[0], None, exc)
                raise
            _end_gen(rec, counter[0], value, None)
            return value

        return _mark_wrapper(wrapper, site)

    return decorate


def _end_gen(rec: Rec, yields: int, value: Any, exc: BaseException | None) -> None:
    if rec.deep:
        _deep_leave(rec, exc)
    _finish(rec, value, exc, yields=yields)


def _coro_decorator(site: Site) -> Any:
    def decorate(fn: Any) -> Any:
        @functools.wraps(fn)
        async def wrapper(*args: Any, **kwargs: Any) -> Any:
            if not state.on or _tls.busy or _skip_now():
                return await fn(*args, **kwargs)
            parent = _CTX.get()
            if parent is _SUPPRESS:
                return await fn(*args, **kwargs)
            rec = _begin(site, fn, args, kwargs, parent)
            if rec is None:
                return await fn(*args, **kwargs)
            if rec is _CAPPED:
                _CTX.set(_SUPPRESS)
                try:
                    return await fn(*args, **kwargs)
                finally:
                    _CTX.set(parent)
            _CTX.set(rec)
            coro = fn(*args, **kwargs)
            if rec.deep:
                _deep_enter(rec, fn, getattr(coro, "cr_frame", None))
            try:
                value = await coro
            except BaseException as exc:
                _CTX.set(parent)
                _end_gen(rec, 0, None, exc)
                raise
            _CTX.set(parent)
            _end_gen(rec, 0, value, None)
            return value

        return _mark_wrapper(wrapper, site)

    return decorate


def _agen_decorator(site: Site) -> Any:
    def decorate(fn: Any) -> Any:
        @functools.wraps(fn)
        async def wrapper(*args: Any, **kwargs: Any) -> Any:
            rec = None
            ctx: Any = _KEEP
            if state.on and not _tls.busy and not _skip_now():
                parent = _CTX.get()
                if parent is _SUPPRESS:
                    ctx = _SUPPRESS
                else:
                    began = _begin(site, fn, args, kwargs, parent)
                    if began is _CAPPED:
                        ctx = _SUPPRESS
                    elif began is not None:
                        rec = ctx = began
            inner = fn(*args, **kwargs)
            if rec is not None and rec.deep:
                _deep_enter(rec, fn, getattr(inner, "ag_frame", None))
            yields = 0
            sent: Any = None
            pending: BaseException | None = None
            error: BaseException | None = None
            try:
                while True:
                    prev = _CTX.get()
                    if ctx is not _KEEP:
                        _CTX.set(ctx)
                    try:
                        if pending is not None:
                            err, pending = pending, None
                            value = await inner.athrow(err)
                        else:
                            value = await inner.asend(sent)
                    except StopAsyncIteration:
                        break
                    finally:
                        if ctx is not _KEEP:
                            _CTX.set(prev)
                    yields += 1
                    try:
                        sent = yield value
                    except GeneratorExit:
                        await inner.aclose()
                        raise
                    except BaseException as err:
                        pending, sent = err, None
            except GeneratorExit:
                raise
            except BaseException as exc:
                error = exc
                raise
            finally:
                if rec is not None:
                    _end_gen(rec, yields, None, error)

        return _mark_wrapper(wrapper, site)

    return decorate


# --------------------------------------------------------------------------------- classes


def _class_decorator(site: Site) -> Any:
    def decorate(cls: Any) -> Any:
        try:
            _wrap_generated_init(cls, site)
        except Exception as exc:
            _stderr(f"class {site.qual}: {type(exc).__name__}: {exc}")
        return cls

    return decorate


def _wrap_generated_init(cls: Any, site: Site) -> None:
    """Give dataclass-style generated ``__init__`` methods an ``init`` record."""
    import dataclasses
    import types

    init = cls.__dict__.get("__init__")
    if not isinstance(init, types.FunctionType) or getattr(init, "__podtrace__", None):
        return
    if not dataclasses.is_dataclass(cls) and not hasattr(cls, "__attrs_attrs__"):
        return
    if not init.__code__.co_filename.startswith("<"):
        return
    info = SiteInfo(
        idx=-1,
        shape="f",
        qualname=f"{cls.__qualname__}.__init__",
        lineno=site.line,
        is_method=True,
        is_init=True,
    )
    table = TABLES.get(site.file)
    if table is None:
        return
    init_site = Site(info, table, site.module)
    cls.__init__ = _plain_decorator(init_site)(init)


__all__ = [
    "Rec",
    "Site",
    "add_init_hook",
    "add_layout_provider",
    "clsname",
    "configure",
    "register",
    "report_error",
    "shutdown",
    "state",
]


def emit_line(rec: Rec, line: int, entries: list[dict[str, Any]], now: int) -> None:
    """A ``line`` record for deep mode: local variables that changed on one executed line."""
    site = rec.site
    record = {
        "v": SCHEMA_VERSION,
        "kind": "line",
        "seq": next(state.seq),
        "trace_id": rec.trace.id,
        "span_id": _hex(state.rng.getrandbits(64) or 1, 16),
        "parent_id": rec.span_id,
        "name": site.name,
        "module": site.module,
        "file": site.file,
        "line": line,
        "start_ns": now,
        "end_ns": now,
        "thread": _thread_alias(),
        "label": rec.label,
        "args": {},
        "ret": None,
        "exc": None,
        "state": entries,
        "attrs": {},
    }
    _write(record)
