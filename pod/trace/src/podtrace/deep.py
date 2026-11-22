"""Deep mode: one ``line`` record per executed line of chosen functions, via ``sys.monitoring``.

After each line, the local variables whose value changed are reported with the same summaries as
arguments. Python 3.12 or newer; on 3.11 ``available()`` is False and the recorder says so once.

Change detection uses the same shallow keys as the state diffs: a local counts as changed when it
is rebound, when a primitive changes value, when a tensor's version counter moves, or when a
container's length or item identities change. A write into an inference tensor (which has no
version counter) is not seen here.
"""

from __future__ import annotations

import sys
import threading
import time
from typing import Any

_TOOL_NAMES = ("podtrace",)


def available() -> bool:
    return hasattr(sys, "monitoring")


class _FrameState:
    __slots__ = ("keys", "line", "rec")

    def __init__(self, rec: Any) -> None:
        self.rec = rec
        self.keys: dict[str, Any] | None = None
        self.line = 0


class _Pending(threading.local):
    def __init__(self) -> None:
        self.items: list[list[Any]] = []


_pending = _Pending()
_frames: dict[int, _FrameState] = {}
_active: dict[int, tuple[Any, list[int]]] = {}
_codes: set[Any] = set()
_tool: list[int | None] = [None]
_lock = threading.Lock()


def _events() -> int:
    ev = _mon().events
    return ev.LINE | ev.PY_RETURN | ev.PY_YIELD


def _ensure_tool() -> int:
    tool = _tool[0]
    if tool is not None:
        return tool
    with _lock:
        if _tool[0] is not None:
            return _tool[0]
        mon = _mon()
        for candidate in (3, 4, 5):
            try:
                mon.use_tool_id(candidate, _TOOL_NAMES[0])
            except ValueError:
                continue
            ev = mon.events
            mon.register_callback(candidate, ev.LINE, _on_line)
            mon.register_callback(candidate, ev.PY_RETURN, _on_return)
            mon.register_callback(candidate, ev.PY_YIELD, _on_yield)
            _tool[0] = candidate
            return candidate
    raise RuntimeError("no free _mon() tool id")


def enter(rec: Any, fn: Any, frame: Any = None) -> None:
    """Start reporting lines for the call ``rec`` is about to run (``fn`` is the raw function)."""
    code = getattr(fn, "__code__", None)
    if code is None:
        return
    tool = _ensure_tool()
    if code not in _codes:
        _mon().set_local_events(tool, code, _events())
        _codes.add(code)
    st = _FrameState(rec)
    if frame is not None:
        _frames[id(frame)] = st
        _active[id(rec)] = (rec, [id(frame)])
    else:
        _pending.items.append([code, st, False])
        _active[id(rec)] = (rec, [])


def leave(rec: Any, exc: BaseException | None = None) -> None:
    """End deep reporting for ``rec``; when the call raised, report the last line from its traceback.

    ``PY_UNWIND`` cannot be a local event, so the frame of a function that raised is reached
    through the exception's traceback instead.
    """
    if exc is not None:
        tb = exc.__traceback__
        while tb is not None:
            st = _frames.get(id(tb.tb_frame))
            if st is not None and st.rec is rec:
                _final_flush(tb.tb_frame, st)
            tb = tb.tb_next
    entry = _active.pop(id(rec), None)
    if entry is not None:
        for fid in entry[1]:
            _frames.pop(fid, None)
    items = _pending.items
    for i in range(len(items) - 1, -1, -1):
        if items[i][1].rec is rec:
            del items[i]
    if not _active:
        from . import runtime

        ctl = runtime.state.control
        if (ctl is None or not ctl.deep) and _tool[0] is not None:
            for code in list(_codes):
                try:  # noqa: SIM105
                    _mon().set_local_events(_tool[0], code, 0)
                except Exception:
                    pass
            _codes.clear()


def _state_for(frame: Any, code: Any) -> _FrameState | None:
    st = _frames.get(id(frame))
    if st is not None:
        return st
    items = _pending.items
    for i in range(len(items) - 1, -1, -1):
        item = items[i]
        if item[0] is code and not item[2]:
            item[2] = True
            _frames[id(frame)] = item[1]
            entry = _active.get(id(item[1].rec))
            if entry is not None:
                entry[1].append(id(frame))
            return item[1]
    return None


def _snapshot(frame: Any, st: _FrameState) -> dict[str, Any]:
    from . import runtime

    summ = runtime.state.summ
    assert summ is not None
    level = st.rec.site.stats
    out = {}
    for name, value in list(frame.f_locals.items()):
        if name.startswith("__"):
            continue
        out[name] = (summ.key(value, level), value)
    return out


def _flush(frame: Any, st: _FrameState, final: bool = False) -> None:
    """Report what changed since the previous event, attributed to the line that just ran."""
    from . import runtime
    from .summary import is_sensitive

    snap = _snapshot(frame, st)
    prev = st.keys
    st.keys = {k: v[0] for k, v in snap.items()}
    if prev is None or not st.line:
        return
    summ = runtime.state.summ
    assert summ is not None
    level = st.rec.site.stats
    seen = st.rec.trace.seen
    entries = []
    for name in sorted(prev.keys() | snap.keys()):
        old = prev.get(name)
        new = snap.get(name)
        if new is not None and old == new[0]:
            continue
        redact = is_sensitive(name)
        entries.append(
            {
                "target": "local",
                "attr": name,
                "before": summ.from_key(old, level, redact) if old is not None else None,
                "after": summ.summarize(new[1], level, seen, redact) if new is not None else None,
            }
        )
    if entries:
        runtime.emit_line(st.rec, st.line, entries, time.time_ns())


def _final_flush(frame: Any, st: _FrameState) -> None:
    from . import runtime

    tls = runtime._tls
    tls.busy = True
    try:
        _flush(frame, st)
    finally:
        tls.busy = False


def _handle(code: Any, line: int | None, drop: bool) -> None:
    from . import runtime

    tls = runtime._tls
    if tls.busy:
        return
    frame = sys._getframe(2)
    st = _state_for(frame, code)
    if st is None:
        return
    tls.busy = True
    try:
        _flush(frame, st)
        if line is not None:
            st.line = line
        if drop:
            _frames.pop(id(frame), None)
    except Exception as exc:
        runtime.report_error("deep", exc)
    finally:
        tls.busy = False


def _on_line(code: Any, line: int) -> None:
    _handle(code, line, False)


def _on_return(code: Any, offset: int, retval: Any) -> None:
    _handle(code, None, True)


def _on_yield(code: Any, offset: int, value: Any) -> None:
    _handle(code, None, False)


def _mon() -> Any:
    return getattr(sys, "monitoring")  # noqa: B009 - absent before Python 3.12


def _reset() -> None:
    """Forget every bound frame and release local events (tests)."""
    if _tool[0] is not None:
        for code in list(_codes):
            try:  # noqa: SIM105
                _mon().set_local_events(_tool[0], code, 0)
            except Exception:
                pass
    _codes.clear()
    _frames.clear()
    _active.clear()
    _pending.items.clear()
