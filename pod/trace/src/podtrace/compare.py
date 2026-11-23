"""Find where two podtrace recordings first part.

Usage: ``podtrace diff A B`` or ``podtrace diff --summary A``. See ``main``.

The module has three layers that can be used on their own:

* ``load_run(path)`` reads one run (``records.jsonl`` plus ``meta.json``) into a compact call tree.
* ``align_runs(a, b)`` matches the calls of two runs, top down, sibling list by sibling list.
* ``diff_runs(a, b, ...)`` compares every matched pair of calls and collects the differences.

Everything that walks a tree or a summary uses an explicit stack, because recorded call trees can
be several hundred levels deep.
"""

from __future__ import annotations

import argparse
import gzip
import json
import math
import os
import re
import statistics
import sys
import textwrap
import zlib
from array import array
from collections import Counter
from difflib import SequenceMatcher
from fnmatch import fnmatchcase
from pathlib import Path
from typing import Any

__all__ = [
    "Alignment",
    "Change",
    "DiffResult",
    "Difference",
    "InputError",
    "Run",
    "align_runs",
    "call_path",
    "diff_runs",
    "load_run",
    "main",
    "summarize_run",
]

DEFAULT_RTOL = 1e-3
DEFAULT_ATOL = 1e-6
DEFAULT_MAX = 40
DRIFT_ROWS = 30
# Sibling lists whose unmatched middle is larger than this many (a * b) element pairs are matched
# with a linear greedy resynchronisation instead of SequenceMatcher, whose running time grows with
# the product when the same few names repeat thousands of times.
_EXACT_MATCH_LIMIT = 1_000_000
_RESYNC_WINDOW = 6
_RESYNC_SKIP = 2000


class InputError(Exception):
    """A run could not be found or read, or the options are unusable (exit code 2)."""


# ---------------------------------------------------------------------------------------------
# Loading
# ---------------------------------------------------------------------------------------------


class Rec:
    """One parsed record, reduced to what comparison needs."""

    __slots__ = (
        "args",
        "attrs",
        "end_ns",
        "exc",
        "kind",
        "label",
        "name",
        "parent_id",
        "ret",
        "retval",
        "seq",
        "span_id",
        "start_ns",
        "state",
        "tens",
    )

    def __init__(
        self,
        seq: int,
        kind: str,
        name: str,
        span_id: str | None,
        parent_id: str | None,
        start_ns: int | None,
        end_ns: int | None,
        label: str | None,
        args: Any,
        ret: Any,
        exc: Any,
        state: Any,
        attrs: Any,
        tens: bool,
        retval: Any = None,
    ) -> None:
        self.seq = seq
        self.kind = kind
        self.name = name
        self.span_id = span_id
        self.parent_id = parent_id
        self.start_ns = start_ns
        self.end_ns = end_ns
        self.label = label
        self.args = args
        self.ret = ret
        self.exc = exc
        self.state = state
        self.attrs = attrs
        self.tens = tens
        self.retval = retval


class Run:
    """One recording: records in file order, plus the call tree over their indices."""

    def __init__(self, source: str, records_path: Path, meta_path: Path | None) -> None:
        self.source = source
        self.records_path = records_path
        self.meta_path = meta_path
        self.meta: dict[str, Any] = {}
        self.meta_error: str | None = None
        self.recs: list[Rec] = []
        self.parent = array("i")  # index of the parent record, -1 for roots
        self.kids: dict[int, list[int]] = {}  # index -> child indices ordered by seq
        self.roots: list[int] = []
        self.orphans = 0  # roots whose parent_id names a record that is not in the file
        self.bad_lines = 0  # unparseable lines that were not the last line
        self.truncated = False  # the last line (or the compressed stream) was cut off
        self.kinds: Counter[str] = Counter()
        self.labels: Counter[str] = Counter()
        self._ordinals: array[int] | None = None

    def __len__(self) -> int:
        return len(self.recs)

    # -- reading ---------------------------------------------------------------------------

    def _read(self) -> None:
        path = self.records_path
        try:
            fh = gzip.open(path, "rb") if path.suffix == ".gz" else open(path, "rb")  # noqa: SIM115
        except OSError as exc:
            raise InputError(f"cannot open {path}: {exc}") from exc
        recs = self.recs
        last_bad = False
        try:
            with fh:
                for raw in fh:
                    raw = raw.strip()
                    if not raw:
                        continue
                    try:
                        obj = json.loads(raw)
                    except (ValueError, RecursionError):
                        obj = None
                    rec = _make_rec(obj, raw) if isinstance(obj, dict) else None
                    if rec is None:
                        if last_bad:
                            self.bad_lines += 1
                        last_bad = True
                        continue
                    if last_bad:
                        self.bad_lines += 1
                        last_bad = False
                    recs.append(rec)
        except (EOFError, zlib.error, gzip.BadGzipFile) as exc:
            self.truncated = True
            if not recs and not last_bad:
                raise InputError(f"cannot read {path}: {exc}") from exc
        except OSError as exc:
            raise InputError(f"cannot read {path}: {exc}") from exc
        if last_bad:
            self.truncated = True

    def _build_tree(self) -> None:
        recs = self.recs
        n = len(recs)
        ids: dict[str, int] = {}
        for i, r in enumerate(recs):
            if r.span_id is not None:
                ids[r.span_id] = i
        self.parent = array("i", [-1]) * n
        kids: dict[int, list[int]] = {}
        roots: list[int] = []
        for i, r in enumerate(recs):
            p = r.parent_id
            if p:
                j = ids.get(p)
                if j is None or j == i:
                    roots.append(i)
                    self.orphans += 1
                else:
                    self.parent[i] = j
                    kids.setdefault(j, []).append(i)
            else:
                roots.append(i)
            self.kinds[r.kind] += 1
            if r.label:
                self.labels[r.label] += 1
        for r in recs:
            r.span_id = None
            r.parent_id = None
        seqs = [r.seq for r in recs]
        for lst in kids.values():
            lst.sort(key=seqs.__getitem__)
        roots.sort(key=seqs.__getitem__)
        self.kids = kids
        self.roots = roots

    # -- helpers ---------------------------------------------------------------------------

    def ordinals(self) -> array[int]:
        """For every record, how many earlier siblings have the same kind and name."""
        if self._ordinals is None:
            out = array("i", [0]) * len(self.recs)
            groups: list[list[int]] = [self.roots, *self.kids.values()]
            for lst in groups:
                seen: dict[tuple[str, str], int] = {}
                for i in lst:
                    r = self.recs[i]
                    key = (r.kind, r.name)
                    out[i] = seen.get(key, 0)
                    seen[key] = out[i] + 1
            self._ordinals = out
        return self._ordinals

    def info(self) -> dict[str, Any]:
        return {
            "source": self.source,
            "records_file": str(self.records_path),
            "records": len(self.recs),
            "kinds": dict(self.kinds),
            "labels": dict(self.labels),
            "roots": len(self.roots),
            "orphans": self.orphans,
            "bad_lines": self.bad_lines,
            "truncated": self.truncated,
        }


def _return_value(attrs: Any) -> Any:
    """What a coroutine or generator returned: the recorder keeps it in ``attrs["return"]``."""
    return attrs.get("return") if isinstance(attrs, dict) else None


def _make_rec(obj: dict[str, Any], raw: bytes) -> Rec | None:
    seq = obj.get("seq")
    name = obj.get("name")
    if not isinstance(seq, int) or isinstance(seq, bool) or not isinstance(name, str):
        return None
    kind = obj.get("kind")
    kind = sys.intern(kind) if isinstance(kind, str) else "call"
    span_id = obj.get("span_id")
    parent_id = obj.get("parent_id")
    start_ns = obj.get("start_ns")
    end_ns = obj.get("end_ns")
    label = obj.get("label")
    return Rec(
        seq=seq,
        kind=kind,
        name=sys.intern(name),
        span_id=span_id if isinstance(span_id, str) else None,
        parent_id=parent_id if isinstance(parent_id, str) else None,
        start_ns=start_ns if isinstance(start_ns, int) else None,
        end_ns=end_ns if isinstance(end_ns, int) else None,
        label=sys.intern(label) if isinstance(label, str) else None,
        args=obj.get("args"),
        ret=obj.get("ret"),
        exc=obj.get("exc"),
        state=obj.get("state"),
        attrs=obj.get("attrs") if kind == "mark" else None,
        tens=b'"tensor"' in raw or b'"ndarray"' in raw,
        retval=_return_value(obj.get("attrs")),
    )


def resolve_run_path(p: str | os.PathLike[str]) -> tuple[Path, Path | None]:
    """Return (records file, meta.json or None) for a run directory or a records file."""
    path = Path(p)
    if path.is_dir():
        for name in ("records.jsonl", "records.jsonl.gz"):
            if (path / name).is_file():
                meta = path / "meta.json"
                return path / name, meta if meta.is_file() else None
        raise InputError(f"{path} is a directory but holds no records.jsonl")
    if path.is_file():
        meta = path.parent / "meta.json"
        return path, meta if meta.is_file() else None
    raise InputError(f"{path} does not exist")


def load_run(path: str | os.PathLike[str]) -> Run:
    """Load a run directory or a ``records.jsonl`` / ``records.jsonl.gz`` file."""
    records_path, meta_path = resolve_run_path(path)
    run = Run(str(path), records_path, meta_path)
    if meta_path is not None:
        try:
            meta = json.loads(meta_path.read_text(encoding="utf-8"))
            if isinstance(meta, dict):
                run.meta = meta
            else:
                run.meta_error = "meta.json is not a JSON object"
        except (OSError, ValueError) as exc:
            run.meta_error = f"meta.json could not be read: {exc}"
    run._read()
    run._build_tree()
    return run


def call_path(run: Run, idx: int) -> list[tuple[str, int, int]]:
    """Path from the root to ``idx`` as (name, ordinal among same-named siblings, seq)."""
    ords = run.ordinals()
    out: list[tuple[str, int, int]] = []
    i = idx
    while i >= 0:
        r = run.recs[i]
        out.append((r.name, ords[i], r.seq))
        i = run.parent[i]
    out.reverse()
    return out


def _selected_subtrees(run: Run, idx: int, filt: _Filter) -> list[int]:
    """The calls to report for an unmatched subtree rooted at ``idx``.

    Without filters that is the root alone. With ``--only`` or ``--ignore`` a root that is not
    selected is looked through: the topmost selected calls below it are reported instead.
    """
    if filt.call_selected(run.recs[idx].name):
        return [idx]
    if not (filt.only or filt.ignore):
        return []
    out: list[int] = []
    stack = [idx]
    while stack:
        i = stack.pop()
        if filt.call_selected(run.recs[i].name):
            out.append(i)
        else:
            stack.extend(reversed(run.kids.get(i, ())))
    out.sort(key=lambda i: run.recs[i].seq)
    return out


def subtree_size(run: Run, idx: int) -> int:
    count = 0
    stack = [idx]
    kids = run.kids
    while stack:
        i = stack.pop()
        count += 1
        k = kids.get(i)
        if k:
            stack.extend(k)
    return count


# ---------------------------------------------------------------------------------------------
# Alignment
# ---------------------------------------------------------------------------------------------


class Alignment:
    """Result of matching two call trees.

    ``pairs`` holds (index in A, index in B, index of the parent pair or -1); a pair is always
    listed after its parent pair. ``only_a`` holds (index in A, parent pair); ``only_b`` holds
    (index in B, parent pair, seq in A of the closest matched sibling before it or -1).
    """

    def __init__(self) -> None:
        self.pairs: list[tuple[int, int, int]] = []
        self.only_a: list[tuple[int, int]] = []
        self.only_b: list[tuple[int, int, int]] = []


def _greedy_blocks(ka: list[int], kb: list[int]) -> list[tuple[int, int, int]]:
    """Linear matching for very long sibling lists: after a mismatch, skip ahead on one side
    until the next few elements agree again."""
    na, nb = len(ka), len(kb)
    blocks: list[tuple[int, int, int]] = []
    i = j = 0
    w = _RESYNC_WINDOW

    def agree(x: int, y: int) -> bool:
        return x < na and y < nb and ka[x : x + w] == kb[y : y + w]

    while i < na and j < nb:
        if ka[i] == kb[j]:
            start_i, start_j = i, j
            while i < na and j < nb and ka[i] == kb[j]:
                i += 1
                j += 1
            blocks.append((start_i, start_j, i - start_i))
            continue
        for d in range(1, _RESYNC_SKIP + 1):
            if agree(i + d, j):
                i += d
                break
            if agree(i, j + d):
                j += d
                break
        else:
            i += 1
            j += 1
    return blocks


def _matching_blocks(ka: list[int], kb: list[int]) -> list[tuple[int, int, int]]:
    na, nb = len(ka), len(kb)
    m = min(na, nb)
    p = 0
    while p < m and ka[p] == kb[p]:
        p += 1
    s = 0
    while s < m - p and ka[na - 1 - s] == kb[nb - 1 - s]:
        s += 1
    blocks: list[tuple[int, int, int]] = []
    if p:
        blocks.append((0, 0, p))
    mid_a = ka[p : na - s]
    mid_b = kb[p : nb - s]
    if mid_a and mid_b:
        if len(mid_a) * len(mid_b) > _EXACT_MATCH_LIMIT:
            found = _greedy_blocks(mid_a, mid_b)
        else:
            sm = SequenceMatcher(None, mid_a, mid_b, autojunk=False)
            found = [blk for blk in sm.get_matching_blocks() if blk[2]]
        blocks.extend((p + i, p + j, n) for i, j, n in found)
    if s:
        blocks.append((na - s, nb - s, s))
    return blocks


def align_runs(a: Run, b: Run) -> Alignment:
    """Match the calls of two runs: roots as a sequence, then children of each matched pair."""
    out = Alignment()
    key_ids: dict[tuple[str, str], int] = {}

    def keys(run: Run, lst: list[int]) -> list[int]:
        res = []
        for i in lst:
            r = run.recs[i]
            res.append(key_ids.setdefault((r.kind, r.name), len(key_ids)))
        return res

    stack: list[tuple[list[int], list[int], int]] = [(a.roots, b.roots, -1)]
    while stack:
        la, lb, pp = stack.pop()
        na, nb = len(la), len(lb)
        blocks = _matching_blocks(keys(a, la), keys(b, lb))
        anchor = a.recs[out.pairs[pp][0]].seq if pp >= 0 else -1
        ia = ib = 0
        for i, j, n in [*blocks, (na, nb, 0)]:
            for x in range(ia, i):
                out.only_a.append((la[x], pp))
            for y in range(ib, j):
                out.only_b.append((lb[y], pp, anchor))
            for t in range(n):
                ai, bi = la[i + t], lb[j + t]
                out.pairs.append((ai, bi, pp))
                anchor = a.recs[ai].seq
                ka, kb = a.kids.get(ai), b.kids.get(bi)
                if ka or kb:
                    stack.append((ka or [], kb or [], len(out.pairs) - 1))
            ia, ib = i + n, j + n
    return out


# ---------------------------------------------------------------------------------------------
# Comparison
# ---------------------------------------------------------------------------------------------

_NONFINITE = {"nan": math.nan, "inf": math.inf, "-inf": -math.inf}
_STATS = ("mean", "std", "absmean", "min", "max")
_SCALAR_TYPES = ("int", "float")
_DEFAULT_IGNORED_KEYS = frozenset(
    {
        "id",
        "ver",
        "device",
        "start_ns",
        "end_ns",
        "duration_ns",
        "duration",
        "elapsed",
        "trace_id",
        "span_id",
        "thread",
        "label",
    }
)
_SPLIT = re.compile(r"[.\[\]]+")


def _num(x: Any) -> float | None:
    """A summary scalar as a float, or None when it is not a number."""
    if isinstance(x, bool):
        return None
    if isinstance(x, (int, float)):
        try:
            return float(x)
        except OverflowError:
            return None
    if isinstance(x, str):
        return _NONFINITE.get(x)
    return None


def _plain_num(x: Any) -> float | None:
    if isinstance(x, str):
        return None
    return _num(x)


def _clip(v: Any, depth: int = 3) -> Any:
    """A shortened copy of ``v`` that is safe to print or put into JSON."""
    if isinstance(v, dict):
        if depth <= 0:
            return "..."
        return {str(k): _clip(x, depth - 1) for k, x in list(v.items())[:16]}
    if isinstance(v, list):
        if depth <= 0:
            return "..."
        return [_clip(x, depth - 1) for x in v[:16]]
    if isinstance(v, str) and len(v) > 200:
        return v[:200] + "..."
    return v


class Change:
    """One field that differs between two matched calls (or one tensor statistic group)."""

    __slots__ = ("a", "abs_dev", "b", "field", "rel_dev", "where")

    def __init__(
        self,
        field: str,
        a: Any,
        b: Any,
        rel_dev: float | None = None,
        abs_dev: float | None = None,
        where: Any = None,
    ) -> None:
        self.field = field
        self.a = a
        self.b = b
        self.rel_dev = rel_dev
        self.abs_dev = abs_dev
        self.where = where

    def to_dict(self) -> dict[str, Any]:
        return {
            "field": self.field,
            "a": _clip(self.a),
            "b": _clip(self.b),
            "rel_dev": _json_float(self.rel_dev),
            "abs_dev": _json_float(self.abs_dev),
            "where": self.where,
        }


def _json_float(x: float | None) -> float | str | None:
    if x is None or math.isfinite(x):
        return x
    return "nan" if x != x else ("inf" if x > 0 else "-inf")


class Difference:
    """A matched call whose content differs ('changed'), or a subtree present on one side."""

    __slots__ = (
        "a_idx",
        "a_seq",
        "b_idx",
        "b_seq",
        "changes",
        "inherited",
        "kind",
        "name",
        "parent_pair",
        "size",
        "sort_key",
    )

    def __init__(
        self,
        kind: str,
        name: str,
        a_idx: int,
        b_idx: int,
        a_seq: int | None,
        b_seq: int | None,
        sort_key: float,
        parent_pair: int,
        changes: list[Change] | None = None,
        size: int = 1,
    ) -> None:
        self.kind = kind  # "changed", "only_a" or "only_b"
        self.name = name
        self.a_idx = a_idx
        self.b_idx = b_idx
        self.a_seq = a_seq
        self.b_seq = b_seq
        self.sort_key = sort_key
        self.parent_pair = parent_pair
        self.changes = changes or []
        self.size = size
        self.inherited = False

    @property
    def top_dev(self) -> float | None:
        devs = [c.rel_dev for c in self.changes if c.rel_dev is not None]
        return max(devs) if devs else None

    def to_dict(self, a: Run, b: Run) -> dict[str, Any]:
        run, idx = (b, self.b_idx) if self.kind == "only_b" else (a, self.a_idx)
        return {
            "kind": self.kind,
            "name": self.name,
            "seq_a": self.a_seq,
            "seq_b": self.b_seq,
            "path": [{"name": n, "index": o, "seq": s} for n, o, s in call_path(run, idx)],
            "inherited": self.inherited,
            "size": self.size,
            "changes": [c.to_dict() for c in self.changes],
        }


class DiffResult:
    def __init__(self, a: Run, b: Run, rtol: float, atol: float) -> None:
        self.a = a
        self.b = b
        self.rtol = rtol
        self.atol = atol
        self.matched = 0
        self.compared = 0
        self.changed: list[Difference] = []
        self.only_a: list[Difference] = []
        self.only_b: list[Difference] = []
        # (seq in A, name, largest relative deviation, where, beyond tolerance, index in A)
        self.drift: list[tuple[int, str, float, str, bool, int]] = []

    @property
    def has_differences(self) -> bool:
        return bool(self.changed or self.only_a or self.only_b)

    def first(self) -> Difference | None:
        """The earliest changed call that is not merely inherited from a call inside it."""
        for d in self.changed:
            if not d.inherited:
                return d
        return self.changed[0] if self.changed else None


class _Filter:
    def __init__(self, ignore: list[str], only: list[str]) -> None:
        self.ignore = ignore
        self.only = only
        self._cache: dict[str, bool] = {}

    def call_selected(self, name: str) -> bool:
        if self.only and not any(fnmatchcase(name, p) for p in self.only):
            return False
        return not any(fnmatchcase(name, p) for p in self.ignore)

    def field_ignored(self, field: str) -> bool:
        if not self.ignore:
            return False
        hit = self._cache.get(field)
        if hit is None:
            parts = [p for p in _SPLIT.split(field) if p]
            hit = any(
                fnmatchcase(field, pat) or any(fnmatchcase(p, pat) for p in parts)
                for pat in self.ignore
            )
            self._cache[field] = hit
        return hit


class _Comparer:
    """Compares the content of two matched calls."""

    def __init__(self, rtol: float, atol: float) -> None:
        self.rtol = rtol
        self.atol = atol
        self.changes: list[Change] = []
        self.dev = 0.0
        self.dev_where = ""
        self.beyond = False

    # -- numbers ---------------------------------------------------------------------------

    def _close(self, x: float, y: float) -> tuple[bool, float, float]:
        """(within tolerance, relative deviation, absolute deviation)."""
        if x == y or (x != x and y != y):
            return True, 0.0, 0.0
        if x != x or y != y or math.isinf(x) or math.isinf(y):
            return False, math.inf, math.inf
        d = abs(x - y)
        m = max(abs(x), abs(y))
        return d <= max(self.rtol * m, self.atol), d / max(m, self.atol), d

    def _note(self, rel: float, where: str) -> None:
        if rel > self.dev:
            self.dev = rel
            self.dev_where = where

    def _add(self, *args: Any, **kw: Any) -> None:
        self.changes.append(Change(*args, **kw))

    # -- one call --------------------------------------------------------------------------

    def compare(self, ra: Rec, rb: Rec) -> tuple[list[Change], float, str, bool]:
        self.changes = []
        self.dev = 0.0
        self.dev_where = ""
        self.beyond = False
        if (
            ra.args == rb.args
            and ra.ret == rb.ret
            and ra.retval == rb.retval
            and ra.exc == rb.exc
            and ra.state == rb.state
        ):
            return self.changes, 0.0, "", False
        self._args(ra.args, rb.args)
        self._walk(ra.ret, rb.ret, "ret")
        self._walk(ra.retval, rb.retval, "ret.return")
        self._walk(ra.exc, rb.exc, "exc")
        self._state(ra.state, rb.state)
        return self.changes, self.dev, self.dev_where, self.beyond

    def _args(self, a: Any, b: Any) -> None:
        if not isinstance(a, dict) or not isinstance(b, dict):
            self._walk(a, b, "args")
            return
        for k in a:
            if k not in b:
                self._add(f"args.{k}", _clip(a[k]), None, where="only in A")
            else:
                self._walk(a[k], b[k], f"args.{k}")
        for k in b:
            if k not in a:
                self._add(f"args.{k}", None, _clip(b[k]), where="only in B")

    def _state(self, sa: Any, sb: Any) -> None:
        ga = _group_state(sa)
        gb = _group_state(sb)
        for label in [*ga, *(k for k in gb if k not in ga)]:
            la, lb = ga.get(label, []), gb.get(label, [])
            for k in range(max(len(la), len(lb))):
                path = f"state[{label}]"
                if k < len(la) and k < len(lb):
                    self._walk(la[k].get("before"), lb[k].get("before"), path + ".before")
                    self._walk(la[k].get("after"), lb[k].get("after"), path + ".after")
                elif k < len(la):
                    self._add(path, _clip(la[k].get("after")), None, where="only in A")
                else:
                    self._add(path, None, _clip(lb[k].get("after")), where="only in B")

    # -- summaries -------------------------------------------------------------------------

    def _walk(self, a: Any, b: Any, path: str) -> None:
        stack: list[tuple[Any, Any, str]] = [(a, b, path)]
        while stack:
            a, b, path = stack.pop()
            if a == b:
                continue
            kids: list[tuple[Any, Any, str]] = []
            if isinstance(a, dict) and isinstance(b, dict):
                ta, tb = a.get("t"), b.get("t")
                if isinstance(ta, str) and isinstance(tb, str):
                    self._summary(a, b, ta, tb, path, kids)
                elif isinstance(ta, str) or isinstance(tb, str):
                    self._add(path, _clip(a), _clip(b), where="type differs")
                else:
                    self._mapping(a, b, path, kids, ignore_defaults=True)
            elif isinstance(a, list) and isinstance(b, list):
                if len(a) != len(b):
                    self._add(path + ".len", len(a), len(b))
                kids.extend(
                    (x, y, f"{path}[{i}]") for i, (x, y) in enumerate(zip(a, b, strict=False))
                )
            else:
                x, y = _plain_num(a), _plain_num(b)
                if x is not None and y is not None:
                    close, rel, ab = self._close(x, y)
                    if not close:
                        self._add(path, a, b, rel, ab)
                else:
                    self._add(path, _clip(a), _clip(b))
            stack.extend(reversed(kids))

    def _mapping(
        self,
        a: dict[str, Any],
        b: dict[str, Any],
        path: str,
        kids: list[tuple[Any, Any, str]],
        *,
        ignore_defaults: bool = False,
        fmt: str = "{path}.{key}",
        a_complete: bool = True,
        b_complete: bool = True,
    ) -> None:
        for k, va in a.items():
            if ignore_defaults and k in _DEFAULT_IGNORED_KEYS:
                continue
            sub = fmt.format(path=path, key=k)
            if k in b:
                kids.append((va, b[k], sub))
            elif b_complete:
                self._add(sub, _clip(va), None, where="only in A")
        for k, vb in b.items():
            if k in a or (ignore_defaults and k in _DEFAULT_IGNORED_KEYS) or not a_complete:
                continue
            self._add(fmt.format(path=path, key=k), None, _clip(vb), where="only in B")

    def _summary(
        self,
        a: dict[str, Any],
        b: dict[str, Any],
        ta: str,
        tb: str,
        path: str,
        kids: list[tuple[Any, Any, str]],
    ) -> None:
        if ta != tb and not (ta in _SCALAR_TYPES and tb in _SCALAR_TYPES):
            self._add(path, _clip(a), _clip(b), where="type differs")
            return
        if ta in ("tensor", "ndarray"):
            self._tensor(a, b, path)
        elif ta in ("bool", *_SCALAR_TYPES):
            x, y = _num(a.get("v")), _num(b.get("v"))
            if ta == "bool" or x is None or y is None:
                if a.get("v") != b.get("v"):
                    self._add(path, a.get("v"), b.get("v"))
            else:
                close, rel, ab = self._close(x, y)
                if not close:
                    self._add(path, a.get("v"), b.get("v"), rel, ab)
        elif ta == "str":
            if "v" in a and "v" in b:
                if a["v"] != b["v"]:
                    self._add(path, a["v"], b["v"])
            elif a.get("len") != b.get("len") or a.get("sha") != b.get("sha"):
                self._add(path, _clip(a), _clip(b))
        elif ta == "bytes":
            if a.get("len") != b.get("len") or a.get("sha") != b.get("sha"):
                self._add(path, _clip(a), _clip(b))
        elif ta in ("list", "tuple", "set"):
            if a.get("len") != b.get("len"):
                self._add(path + ".len", a.get("len"), b.get("len"))
            ia, ib = a.get("items"), b.get("items")
            if isinstance(ia, list) and isinstance(ib, list):
                kids.extend(
                    (x, y, f"{path}[{i}]") for i, (x, y) in enumerate(zip(ia, ib, strict=False))
                )
        elif ta == "dict":
            if a.get("len") != b.get("len"):
                self._add(path + ".len", a.get("len"), b.get("len"))
            ia, ib = a.get("items"), b.get("items")
            if isinstance(ia, dict) and isinstance(ib, dict):
                # Only the first few keys are recorded: a key that is absent on the other side
                # proves nothing when that side's item list was cut short.
                self._mapping(
                    ia,
                    ib,
                    path,
                    kids,
                    fmt="{path}[{key}]",
                    a_complete=len(ia) >= (_int(a.get("len")) or 0),
                    b_complete=len(ib) >= (_int(b.get("len")) or 0),
                )
        elif ta == "obj":
            if a.get("cls") != b.get("cls"):
                self._add(path + ".cls", a.get("cls"), b.get("cls"))
            fa, fb = a.get("fields"), b.get("fields")
            if isinstance(fa, dict) and isinstance(fb, dict):
                self._mapping(fa, fb, path, kids)
        elif ta == "fn":
            if a.get("name") != b.get("name"):
                self._add(path, a.get("name"), b.get("name"))
        elif ta == "gen":
            if a.get("yields") != b.get("yields"):
                self._add(path + ".yields", a.get("yields"), b.get("yields"))
        elif ta == "cut":
            if a.get("cls") != b.get("cls"):
                self._add(path, a.get("cls"), b.get("cls"))
        else:
            self._mapping(a, b, path, kids, ignore_defaults=True)

    # -- tensors ---------------------------------------------------------------------------

    def _tensor(self, a: dict[str, Any], b: dict[str, Any], path: str) -> None:
        for key in ("shape", "dtype"):
            va, vb = a.get(key), b.get(key)
            if va is not None and vb is not None and va != vb:
                self._add(f"{path}.{key}", va, vb)
                self._note(math.inf, f"{path}.{key}")
                self.beyond = True
        fp = a.get("fp")
        if fp is not None and fp == b.get("fp"):
            return  # bit-identical contents
        for key in ("nan", "inf"):
            va, vb = a.get(key), b.get(key)
            x, y = _plain_num(va), _plain_num(vb)
            if x is not None and y is not None and x != y:
                self._add(f"{path}.{key}", va, vb, abs(x - y) / max(x, y, 1.0), abs(x - y))
                self._note(math.inf, f"{path}.{key}")
                self.beyond = True
        for key in _STATS:
            va, vb = a.get(key), b.get(key)
            x, y = _num(va), _num(vb)
            if x is None or y is None:
                continue
            close, rel, ab = self._close(x, y)
            self._note(rel, f"{path}.{key}")
            if not close:
                self._add(f"{path}.{key}", va, vb, rel, ab)
                self.beyond = True
        pa, pb = a.get("profile"), b.get("profile")
        if isinstance(pa, dict) and isinstance(pb, dict):
            self._profile(pa, pb, f"{path}.profile")
        sa, sb = a.get("segments"), b.get("segments")
        if isinstance(sa, dict) and isinstance(sb, dict):
            self._segments(sa, sb, f"{path}.segments")

    def _profile(self, pa: dict[str, Any], pb: dict[str, Any], path: str) -> None:
        if pa.get("axis") != pb.get("axis") and pa.get("axis") is not None:
            self._add(f"{path}.axis", pa.get("axis"), pb.get("axis"))
        va, vb = pa.get("absmean"), pb.get("absmean")
        if not isinstance(va, list) or not isinstance(vb, list):
            return
        if len(va) != len(vb):
            self._add(f"{path}.absmean.len", len(va), len(vb))
            self._note(math.inf, f"{path}.absmean.len")
            self.beyond = True
            return
        worst_k = -1
        worst = (0.0, 0.0, 0.0, 0.0)  # rel, abs, a, b of the worst bin that is not close
        nbad = 0
        for k, (u, v) in enumerate(zip(va, vb, strict=True)):
            x, y = _num(u), _num(v)
            if x is None or y is None:
                continue
            close, rel, ab = self._close(x, y)
            self._note(rel, f"{path}.absmean bin {k}")
            if not close:
                nbad += 1
                if worst_k < 0 or rel > worst[0]:
                    worst_k, worst = k, (rel, ab, x, y)
        if worst_k < 0:
            return
        edges = pa.get("edges") if isinstance(pa.get("edges"), list) else pb.get("edges")
        where: dict[str, Any] = {
            "axis": pa.get("axis"),
            "bin": worst_k,
            "bins": len(va),
            "bins_differing": nbad,
        }
        if isinstance(edges, list) and len(edges) > worst_k + 1:
            where["edges"] = [edges[worst_k], edges[worst_k + 1]]
        self._add(f"{path}.absmean", worst[2], worst[3], worst[0], worst[1], where)
        self.beyond = True

    def _segments(self, sa: dict[str, Any], sb: dict[str, Any], path: str) -> None:
        worst_name: str | None = None
        worst = (0.0, 0.0, 0.0, 0.0)
        nbad = 0
        common = 0
        for name, u in sa.items():
            if name not in sb:
                self._add(f"{path}[{name}]", u, None, where="only in A")
                self.beyond = True
                continue
            x, y = _num(u), _num(sb[name])
            if x is None or y is None:
                continue
            common += 1
            close, rel, ab = self._close(x, y)
            self._note(rel, f"{path}[{name}]")
            if not close:
                nbad += 1
                if worst_name is None or rel > worst[0]:
                    worst_name, worst = name, (rel, ab, x, y)
        for name, v in sb.items():
            if name not in sa:
                self._add(f"{path}[{name}]", None, v, where="only in B")
                self.beyond = True
        if worst_name is not None:
            where = {"segment": worst_name, "segments": common, "segments_differing": nbad}
            self._add(path, worst[2], worst[3], worst[0], worst[1], where)
            self.beyond = True


def _int(x: Any) -> int | None:
    return x if isinstance(x, int) and not isinstance(x, bool) else None


def _group_state(state: Any) -> dict[str, list[dict[str, Any]]]:
    groups: dict[str, list[dict[str, Any]]] = {}
    if not isinstance(state, list):
        return groups
    for e in state:
        if not isinstance(e, dict):
            continue
        target = str(e.get("target", ""))
        attr = e.get("attr")
        attr = "" if attr is None else str(attr)
        if attr.startswith("["):
            label = target + attr
        elif attr:
            label = f"{target}.{attr}"
        else:
            label = target
        groups.setdefault(label, []).append(e)
    return groups


def diff_runs(
    a: Run,
    b: Run,
    *,
    rtol: float = DEFAULT_RTOL,
    atol: float = DEFAULT_ATOL,
    ignore: list[str] | tuple[str, ...] = (),
    only: list[str] | tuple[str, ...] = (),
    alignment: Alignment | None = None,
) -> DiffResult:
    """Align two runs and list every difference, ordered by position in run A."""
    al = alignment or align_runs(a, b)
    filt = _Filter(list(ignore), list(only))
    res = DiffResult(a, b, rtol, atol)
    comparer = _Comparer(rtol, atol)
    res.matched = len(al.pairs)
    n = len(al.pairs)
    own: list[Difference | None] = [None] * n
    output_only = bytearray(n)
    for k, (ia, ib, pp) in enumerate(al.pairs):
        ra, rb = a.recs[ia], b.recs[ib]
        if not filt.call_selected(ra.name):
            continue
        res.compared += 1
        changes, dev, where, beyond = comparer.compare(ra, rb)
        if changes and filt.ignore:
            changes = [c for c in changes if not filt.field_ignored(c.field)]
        if ra.tens or rb.tens:
            res.drift.append((ra.seq, ra.name, dev, where, beyond, ia))
        if changes:
            own[k] = Difference(
                "changed", ra.name, ia, ib, ra.seq, rb.seq, float(ra.seq), pp, changes
            )
            if all(c.field.startswith(("ret", "exc", "state")) for c in changes):
                output_only[k] = 1
    below = bytearray(n)
    for ia0, pp in al.only_a:
        for ia in _selected_subtrees(a, ia0, filt):
            r = a.recs[ia]
            d = Difference(
                "only_a", r.name, ia, -1, r.seq, None, float(r.seq), pp, size=subtree_size(a, ia)
            )
            res.only_a.append(d)
            if pp >= 0:
                below[pp] = 1
    for ib0, pp, anchor in al.only_b:
        for ib in _selected_subtrees(b, ib0, filt):
            r = b.recs[ib]
            d = Difference(
                "only_b",
                r.name,
                -1,
                ib,
                None,
                r.seq,
                anchor + 0.5,
                pp,
                size=subtree_size(b, ib),
            )
            res.only_b.append(d)
            if pp >= 0:
                below[pp] = 1
    for k in range(n - 1, -1, -1):
        if own[k] is not None or below[k]:
            pp = al.pairs[k][2]
            if pp >= 0:
                below[pp] = 1
    for k in range(n):
        d = own[k]
        if d is not None:
            d.inherited = bool(output_only[k] and below[k])
            res.changed.append(d)
    res.changed.sort(key=lambda d: d.sort_key)
    res.drift.sort(key=lambda t: t[0])
    res.only_a.sort(key=lambda d: d.sort_key)
    res.only_b.sort(key=lambda d: d.sort_key)
    return res


# ---------------------------------------------------------------------------------------------
# Summary of one run
# ---------------------------------------------------------------------------------------------


def _mark_note(r: Rec) -> str:
    attrs = r.attrs
    if isinstance(attrs, dict):
        for key in ("note", "message", "msg", "reason", "text"):
            v = attrs.get(key)
            if v:
                return str(v)
        if attrs:
            return json.dumps(_clip(attrs), sort_keys=True)
    return r.name


def summarize_run(run: Run) -> dict[str, Any]:
    """Counts and inclusive time per function name, deepest path, and the mark records."""
    counts: Counter[str] = Counter()
    time_ns: Counter[str] = Counter()
    for r in run.recs:
        counts[r.name] += 1
        if r.start_ns is not None and r.end_ns is not None and r.end_ns >= r.start_ns:
            time_ns[r.name] += r.end_ns - r.start_ns
    best, best_depth = -1, -1
    stack = [(i, 1) for i in reversed(run.roots)]
    while stack:
        i, depth = stack.pop()
        if depth > best_depth:
            best, best_depth = i, depth
        for c in run.kids.get(i, ()):
            stack.append((c, depth + 1))
    marks = [(r.seq, r.name, _mark_note(r)) for r in run.recs if r.kind == "mark"]
    marks.sort()
    return {
        "counts": counts,
        "time_ns": time_ns,
        "depth": max(best_depth, 0),
        "deepest": call_path(run, best) if best >= 0 else [],
        "marks": marks,
    }


# ---------------------------------------------------------------------------------------------
# Meta: instrumented file hashes
# ---------------------------------------------------------------------------------------------

_HEX64 = re.compile(r"^[0-9a-fA-F]{64}$")
_HASH_KEYS = ("sha256", "sha", "hash", "digest")
_PATH_KEYS = ("path", "file", "filename", "name")


def file_hashes(meta: Any) -> dict[str, str]:
    """Collect {path: sha256} pairs wherever meta.json keeps them.

    The layout of meta.json is not fixed by the schema, so this accepts both a mapping of path
    to hash and a list of objects holding a path and a hash, at any depth.
    """
    out: dict[str, str] = {}
    stack = [meta]
    while stack:
        cur = stack.pop()
        if isinstance(cur, dict):
            hash_val = next(
                (
                    cur[k]
                    for k in _HASH_KEYS
                    if isinstance(cur.get(k), str) and _HEX64.match(cur[k])
                ),
                None,
            )
            path_val = next((cur[k] for k in _PATH_KEYS if isinstance(cur.get(k), str)), None)
            if hash_val and path_val:
                out[path_val] = hash_val.lower()
                continue
            for k, v in cur.items():
                if isinstance(v, str) and _HEX64.match(v) and ("/" in k or "." in k):
                    out[k] = v.lower()
                elif isinstance(v, (dict, list)):
                    stack.append(v)
        elif isinstance(cur, list):
            stack.extend(x for x in cur if isinstance(x, (dict, list)))
    return out


def code_differences(a: Run, b: Run) -> dict[str, Any]:
    """Instrumented files whose SHA-256 differs, or that only one run lists."""
    ha, hb = file_hashes(a.meta), file_hashes(b.meta)
    if not ha or not hb:
        return {"checked": False, "different": [], "only_a": [], "only_b": []}
    if not set(ha) & set(hb):
        ha = {os.path.basename(k): v for k, v in ha.items()}
        hb = {os.path.basename(k): v for k, v in hb.items()}
    return {
        "checked": True,
        "different": sorted(k for k in ha if k in hb and ha[k] != hb[k]),
        "only_a": sorted(k for k in ha if k not in hb),
        "only_b": sorted(k for k in hb if k not in ha),
    }


# ---------------------------------------------------------------------------------------------
# Report building
# ---------------------------------------------------------------------------------------------


class Doc:
    """A tiny document model that renders as plain text or Markdown."""

    def __init__(self, fmt: str) -> None:
        self.md = fmt == "markdown"
        self.blocks: list[tuple[str, Any]] = []

    def c(self, s: Any) -> str:
        """Inline code."""
        return f"`{s}`" if self.md else str(s)

    def h(self, text: str, level: int = 2) -> None:
        self.blocks.append(("h", (text, level)))

    def p(self, text: str) -> None:
        self.blocks.append(("p", text))

    def bullets(self, items: list[str]) -> None:
        self.blocks.append(("ul", items))

    def table(self, headers: list[str], rows: list[list[Any]], width: int = 60) -> None:
        self.blocks.append(("table", (headers, rows, width)))

    def code(self, lines: list[str]) -> None:
        self.blocks.append(("code", lines))

    def render(self) -> str:
        out: list[str] = []
        for kind, data in self.blocks:
            if kind == "h":
                text, level = data
                if self.md:
                    out.append("#" * level + " " + text)
                else:
                    out.append(text + "\n" + ("=" if level == 1 else "-") * len(text))
            elif kind == "p":
                out.append(data if self.md else textwrap.fill(data, 100))
            elif kind == "ul":
                if self.md:
                    out.append("\n".join(f"- {x}" for x in data))
                else:
                    out.append(
                        "\n".join(
                            textwrap.fill(x, 100, initial_indent="  - ", subsequent_indent="    ")
                            for x in data
                        )
                    )
            elif kind == "code":
                body = "\n".join(data)
                out.append(f"```\n{body}\n```" if self.md else textwrap.indent(body, "    "))
            elif kind == "table":
                out.append(self._table(*data))
            out.append("")
        return "\n".join(out).rstrip() + "\n"

    def _table(self, headers: list[str], rows: list[list[Any]], width: int) -> str:
        cells = [[_cell(c, width) for c in row] for row in rows]
        if self.md:
            esc = lambda s: s.replace("|", "\\|")  # noqa: E731
            lines = ["| " + " | ".join(esc(h) for h in headers) + " |"]
            lines.append("|" + "|".join("---" for _ in headers) + "|")
            lines += ["| " + " | ".join(esc(c) for c in row) + " |" for row in cells]
            return "\n".join(lines)
        widths = [max([len(h)] + [len(r[i]) for r in cells]) for i, h in enumerate(headers)]
        lines = ["  ".join(h.ljust(w) for h, w in zip(headers, widths, strict=True)).rstrip()]
        lines.append("  ".join("-" * w for w in widths))
        lines += [
            "  ".join(c.ljust(w) for c, w in zip(r, widths, strict=True)).rstrip() for r in cells
        ]
        return "\n".join(lines)


def _cell(v: Any, width: int) -> str:
    s = str(v).replace("\n", " ")
    return s if len(s) <= width else s[: width - 3] + "..."


def _g(x: Any) -> str:
    if isinstance(x, float):
        return f"{x:.6g}"
    return str(x)


def _brief(v: Any, limit: int = 80) -> str:
    """One-line description of a summary or a plain value."""
    s: str
    if v is None:
        s = "(absent or null)"
    elif isinstance(v, dict) and isinstance(v.get("t"), str):
        t = v["t"]
        if t in ("bool", "int", "float"):
            s = _g(v.get("v"))
        elif t == "str":
            s = repr(v["v"]) if "v" in v else f"string(len={v.get('len')}, sha={v.get('sha')})"
        elif t in ("tensor", "ndarray"):
            mean = f", mean {_g(v['mean'])}" if "mean" in v else ""
            s = f"{t} shape {v.get('shape')} {v.get('dtype')}{mean}"
        elif t in ("list", "tuple", "set", "dict", "bytes"):
            s = f"{t}(len={v.get('len')})"
        elif t == "obj":
            s = f"object {v.get('cls')}"
        elif t == "fn":
            s = f"function {v.get('name')}"
        elif t == "none":
            s = "None"
        else:
            s = json.dumps(_clip(v), sort_keys=True, default=str)
    elif isinstance(v, str):
        s = repr(v)
    elif isinstance(v, (dict, list)):
        s = json.dumps(_clip(v), sort_keys=True, default=str)
    else:
        s = _g(v)
    return s if len(s) <= limit else s[: limit - 3] + "..."


def _pct(rel: float | None) -> str:
    if rel is None:
        return ""
    if math.isinf(rel):
        return "unbounded"
    return f"{rel * 100:.3g}%"


def _where_text(w: Any) -> str:
    if not w:
        return ""
    if isinstance(w, str):
        return w
    if "bin" in w:
        s = f"bin {w['bin']} of {w['bins']}"
        if "edges" in w:
            s += f", covering {_g(w['edges'][0])} to {_g(w['edges'][1])}"
        if w.get("axis") is not None:
            s += f" along axis {w['axis']}"
        return s + f"; {w['bins_differing']} bins differ"
    if "segment" in w:
        return f"segment '{w['segment']}'; {w['segments_differing']} of {w['segments']} differ"
    return json.dumps(w, sort_keys=True)


def _path_lines(path: list[tuple[str, int, int]], max_lines: int = 14) -> list[str]:
    def line(depth: int, item: tuple[str, int, int]) -> str:
        return "  " * min(depth, 20) + f"{item[0]} [{item[1]}]  (record {item[2]} in the run)"

    if len(path) <= max_lines:
        return [line(d, x) for d, x in enumerate(path)]
    head, tail = 3, max_lines - 4
    out = [line(d, path[d]) for d in range(head)]
    out.append(f"... {len(path) - head - tail} levels omitted ...")
    out += [line(d, path[d]) for d in range(len(path) - tail, len(path))]
    return out


def _path_short(path: list[tuple[str, int, int]], keep: int = 3) -> str:
    parts = [f"{n} [{o}]" for n, o, _ in path[-keep:]]
    prefix = f"({len(path) - keep} levels) ... > " if len(path) > keep else ""
    return prefix + " > ".join(parts)


def _fmt_ns(ns: float) -> str:
    if ns >= 1e9:
        return f"{ns / 1e9:.3f} s"
    if ns >= 1e6:
        return f"{ns / 1e6:.3f} ms"
    return f"{ns / 1e3:.1f} us"


def _counts_text(c: Counter[str]) -> str:
    return ", ".join(f"{k} {v:,}" for k, v in sorted(c.items(), key=lambda kv: -kv[1])) or "none"


def _describe_run(doc: Doc, tag: str, run: Run) -> str:
    s = (
        f"Run {tag} ({doc.c(run.source)}) holds {len(run):,} records ({_counts_text(run.kinds)}); "
        f"its labels are: {_counts_text(run.labels)}."
    )
    notes = []
    if run.truncated:
        notes.append("the last line was cut off and was ignored")
    if run.bad_lines:
        notes.append(f"{run.bad_lines} unreadable lines were skipped")
    if run.orphans:
        notes.append(
            f"{run.orphans} records name a parent that is not in the file and are treated as roots"
        )
    if run.meta_error:
        notes.append(run.meta_error)
    if notes:
        s += " Note: " + "; ".join(notes) + "."
    return s


def _header(doc: Doc, res: DiffResult) -> None:
    a, b = res.a, res.b
    doc.p(_describe_run(doc, "A", a))
    doc.p(_describe_run(doc, "B", b))
    marks_a, marks_b = a.kinds.get("mark", 0), b.kinds.get("mark", 0)
    if marks_a or marks_b:
        doc.p(
            f"Run A has {marks_a} mark records and run B has {marks_b}. A mark is a note from the "
            "recorder itself, for example about calls that were counted but not recorded."
        )
    code = code_differences(a, b)
    if not code["checked"]:
        doc.p(
            "The instrumented source files could not be compared, because meta.json is missing "
            "or lists no SHA-256 hashes in at least one run. Check that both runs used the same code."
        )
    elif code["different"] or code["only_a"] or code["only_b"]:
        doc.p(
            "WARNING: the two runs did not use the same code. A difference in the source files "
            "is the first thing to rule out."
        )
        items = [f"{doc.c(f)} has a different SHA-256 in the two runs" for f in code["different"]]
        items += [f"{doc.c(f)} is listed only in run A" for f in code["only_a"]]
        items += [f"{doc.c(f)} is listed only in run B" for f in code["only_b"]]
        doc.bullets(items[:30] + ([f"... and {len(items) - 30} more"] if len(items) > 30 else []))
    else:
        doc.p("Every instrumented source file has the same SHA-256 in both runs.")
    scope = (
        f"{res.matched:,} calls were matched between the runs and {res.compared:,} of them were "
        f"compared. Numbers count as equal when they are within a relative tolerance of "
        f"{res.rtol:g} or an absolute tolerance of {res.atol:g}."
    )
    doc.p(scope)


def _first_section(doc: Doc, res: DiffResult) -> None:
    doc.h("First difference")
    d = res.first()
    if d is None:
        doc.p(
            "No matched call has different arguments, results, exceptions or state changes. The "
            "runs differ only in which calls they contain, as listed under structural differences."
        )
        return
    path = call_path(res.a, d.a_idx)
    earlier = sum(1 for x in [*res.only_a, *res.only_b] if x.sort_key < d.sort_key)
    s = (
        f"The runs first part at the call {doc.c(d.name)}: record {d.a_seq} in run A and "
        f"record {d.b_seq} in run B. Everything the two runs did before this point agrees "
        f"within tolerance."
    )
    if d.inherited:
        s += (
            " Every difference of this call comes from a call inside it, and no other call "
            "differs for a reason of its own, so this is the call closest to the cause."
        )
    doc.p(s)
    if earlier:
        doc.p(
            f"Before this call, {earlier} calls exist in only one of the two runs (see "
            "structural differences), so the runs did not execute the same code path even "
            "though every matched call before this point agrees."
        )
    doc.p(
        "Call path from the root. The number in brackets counts the earlier calls with the "
        "same name under the same parent, starting at 0."
    )
    doc.code(_path_lines(path))
    n = len(d.changes)
    doc.p(f"This call differs in {n} place{'s' if n != 1 else ''}:")
    rows = [
        [
            c.field,
            _brief(c.a),
            _brief(c.b),
            _pct(c.rel_dev),
            _g(c.abs_dev) if c.abs_dev is not None else "",
            _where_text(c.where),
        ]
        for c in d.changes[:25]
    ]
    doc.table(
        [
            "Field",
            "Value in run A",
            "Value in run B",
            "Relative deviation",
            "Absolute deviation",
            "Where",
        ],
        rows,
        width=90,
    )
    if n > 25:
        doc.p(
            f"{n - 25} more fields of this call differ and are not shown here (see the JSON output)."
        )
    doc.p(
        "Relative deviation is the difference divided by the larger of the two magnitudes (or "
        "of the absolute tolerance, when both values are tiny)."
    )


def _later_section(doc: Doc, res: DiffResult, max_items: int) -> None:
    first = res.first()
    shown_pool = [d for d in res.changed if not d.inherited and d is not first]
    hidden = sum(1 for d in res.changed if d.inherited and d is not first)
    doc.h("Later differences")
    if first is None or (not shown_pool and not hidden):
        doc.p("No other call differs.")
        return
    shown = shown_pool[:max_items]
    intro = (
        f"The next {len(shown)} differing calls in execution order of run A "
        f"(of {len(shown_pool)} in total)."
        if shown_pool
        else "No other call differs for a reason of its own."
    )
    if hidden:
        intro += (
            f" {hidden} further calls are left out because their only differences are in "
            "results or state that they inherit from a differing call inside them."
        )
    doc.p(intro)
    lines = []
    for i, d in enumerate(shown, 2):
        c = d.changes[0]
        more = f" (+{len(d.changes) - 1} more fields)" if len(d.changes) > 1 else ""
        dev = f", {_pct(c.rel_dev)}" if c.rel_dev is not None else ""
        lines.append(
            f"{i:>3}. record {d.a_seq}: {_path_short(call_path(res.a, d.a_idx))} -- "
            f"{c.field}: {_brief(c.a, 30)} vs {_brief(c.b, 30)}{dev}{more}"
        )
    if lines:
        doc.code(lines)
    if len(shown_pool) > len(shown):
        doc.p(f"{len(shown_pool) - len(shown)} more differing calls are not shown (raise --max).")


def _drift_section(doc: Doc, res: DiffResult) -> None:
    doc.h("Drift over the run")
    drift = res.drift
    if not drift:
        doc.p("No matched call carries tensor statistics, so there is no drift to show.")
        return
    first_bad = next((i for i, t in enumerate(drift) if t[4]), None)
    n = len(drift)
    if first_bad is None:
        worst = max(drift, key=lambda t: t[2])
        doc.p(
            f"All {n:,} matched calls with tensor statistics agree within tolerance. The "
            f"largest relative deviation is {_pct(worst[2])}, in {doc.c(worst[1])} (record {worst[0]})."
        )
    elif first_bad == 0:
        t = drift[0]
        doc.p(
            f"The runs differ from the start: the very first of {n:,} calls with tensor "
            f"statistics, {doc.c(t[1])} (record {t[0]}), is already beyond tolerance."
        )
    else:
        t = drift[first_bad]
        after = drift[first_bad:]
        nbad = sum(1 for x in after if x[4])
        doc.p(
            f"The first {first_bad:,} of {n:,} calls with tensor statistics agree within "
            f"tolerance. The first call beyond tolerance is {doc.c(t[1])} (record {t[0]}); "
            f"from there on, {nbad:,} of the remaining {len(after):,} calls are beyond tolerance."
        )
    nb = min(DRIFT_ROWS, n)
    rows = []
    for i in range(nb):
        chunk = drift[i * n // nb : (i + 1) * n // nb]
        worst = max(chunk, key=lambda t: t[2])
        med = statistics.median(t[2] for t in chunk)
        rows.append(
            [
                f"{chunk[0][0]} to {chunk[-1][0]}",
                len(chunk),
                sum(1 for t in chunk if t[4]),
                _pct(med),
                _pct(worst[2]),
                f"{worst[1]} ({worst[3]})" if worst[2] > 0 else "",
            ]
        )
    doc.table(
        [
            "Records in run A",
            "Calls compared",
            "Calls beyond tolerance",
            "Median deviation",
            "Largest deviation",
            "Where the largest is",
        ],
        rows,
        width=70,
    )
    doc.p(
        "Each row covers an equal share of the calls that carry tensor statistics, in execution "
        "order. A deviation is the largest relative deviation over all tensor statistics and "
        "profile bins of one call."
    )


def _structure_section(doc: Doc, res: DiffResult, max_items: int) -> None:
    doc.h("Structural differences")
    if not res.only_a and not res.only_b:
        doc.p("Both runs contain the same calls: nothing is present in only one of them.")
        return
    doc.p(
        f"{len(res.only_a)} call subtrees appear only in run A ({sum(d.size for d in res.only_a):,} "
        f"calls in total) and {len(res.only_b)} appear only in run B "
        f"({sum(d.size for d in res.only_b):,} calls). The alignment did not look inside them."
    )
    names: dict[str, list[int]] = {}
    for d in res.only_a:
        e = names.setdefault(d.name, [0, 0, 0, 0])
        e[0] += 1
        e[1] += d.size
    for d in res.only_b:
        e = names.setdefault(d.name, [0, 0, 0, 0])
        e[2] += 1
        e[3] += d.size
    rows = [[k, *v] for k, v in sorted(names.items(), key=lambda kv: -(kv[1][1] + kv[1][3]))]
    doc.table(
        [
            "Function name",
            "Subtrees only in A",
            "Calls inside them",
            "Subtrees only in B",
            "Calls inside them",
        ],
        rows[:60],
        width=80,
    )
    if len(rows) > 60:
        doc.p(f"{len(rows) - 60} more function names are not shown.")
    allx = sorted([*res.only_a, *res.only_b], key=lambda d: d.sort_key)[: min(max_items, 15)]
    lines = []
    for d in allx:
        run = res.b if d.kind == "only_b" else res.a
        idx = d.b_idx if d.kind == "only_b" else d.a_idx
        side = "B" if d.kind == "only_b" else "A"
        seq = d.b_seq if d.kind == "only_b" else d.a_seq
        lines.append(
            f"only in {side}: {_path_short(call_path(run, idx), 4)} (record {seq}, {d.size} calls)"
        )
    doc.p("The first of them, in execution order:")
    doc.code(lines)


def build_report(res: DiffResult, fmt: str = "text", max_items: int = DEFAULT_MAX) -> str:
    doc = Doc(fmt)
    doc.h("podtrace comparison", 1)
    _header(doc, res)
    if not res.has_differences:
        doc.h("Result")
        doc.p(
            "No differences were found: every matched call agrees within tolerance and both runs contain the same calls."
        )
        if res.drift:
            doc.p(f"{len(res.drift):,} matched calls carry tensor statistics.")
        return doc.render()
    ninh = sum(1 for d in res.changed if d.inherited)
    doc.p(
        f"{len(res.changed):,} matched calls differ ({ninh:,} of them only through a call "
        f"inside them); {len(res.only_a):,} call subtrees exist only in A and "
        f"{len(res.only_b):,} only in B."
    )
    _first_section(doc, res)
    _later_section(doc, res, max_items)
    _drift_section(doc, res)
    _structure_section(doc, res, max_items)
    return doc.render()


def build_summary(run: Run, fmt: str = "text", max_items: int = DEFAULT_MAX) -> str:
    s = summarize_run(run)
    doc = Doc(fmt)
    doc.h("podtrace run summary", 1)
    doc.p(_describe_run(doc, "", run).replace("Run  (", "The run ("))
    if run.roots:
        doc.p(
            f"The call tree has {len(run.roots):,} root calls and reaches a depth of {s['depth']}."
        )
    counts, time_ns = s["counts"], s["time_ns"]
    rows = [
        [name, cnt, _fmt_ns(time_ns[name])]
        for name, cnt in sorted(counts.items(), key=lambda kv: (-kv[1], kv[0]))[:max_items]
    ]
    doc.h("Calls per function name")
    doc.table(["Function name", "Records", "Total time"], rows, width=90)
    doc.p(
        "Total time adds up end minus start of every record of that name, so time spent in "
        "nested calls is counted again at each level."
    )
    if len(counts) > max_items:
        doc.p(f"{len(counts) - max_items} more function names are not shown (raise --max).")
    doc.h("Deepest call path")
    doc.code(_path_lines(s["deepest"]) if s["deepest"] else ["(no records)"])
    marks = s["marks"]
    doc.h("Mark records")
    if not marks:
        doc.p("The run contains no mark records.")
    else:
        doc.p(f"The run contains {len(marks)} mark records:")
        doc.code([f"record {seq}: {note}" for seq, _, note in marks[:max_items]])
        if len(marks) > max_items:
            doc.p(f"{len(marks) - max_items} more are not shown (raise --max).")
    return doc.render()


def summary_json(run: Run) -> dict[str, Any]:
    s = summarize_run(run)
    return {
        "run": run.info(),
        "counts": dict(s["counts"]),
        "time_ns": dict(s["time_ns"]),
        "depth": s["depth"],
        "deepest_path": [{"name": n, "index": o, "seq": q} for n, o, q in s["deepest"]],
        "marks": [{"seq": q, "name": n, "note": t} for q, n, t in s["marks"]],
    }


def write_json(path: str, res: DiffResult) -> None:
    """Write the full result as JSON, one difference at a time to keep memory flat."""
    head = {
        "format": "podtrace-diff",
        "version": 1,
        "run_a": res.a.info(),
        "run_b": res.b.info(),
        "rtol": res.rtol,
        "atol": res.atol,
        "matched_calls": res.matched,
        "compared_calls": res.compared,
        "code": code_differences(res.a, res.b),
        "drift": [
            {"seq": s, "name": n, "rel_dev": _json_float(dv), "where": w, "beyond_tolerance": bd}
            for s, n, dv, w, bd, _ in res.drift
        ],
    }
    ordered = sorted([*res.changed, *res.only_a, *res.only_b], key=lambda d: d.sort_key)
    try:
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(json.dumps(head, default=str)[:-1])
            fh.write(', "differences": [')
            for i, d in enumerate(ordered):
                if i:
                    fh.write(", ")
                fh.write(json.dumps(d.to_dict(res.a, res.b), default=str))
            fh.write("]}\n")
    except OSError as exc:
        raise InputError(f"cannot write {path}: {exc}") from exc


# ---------------------------------------------------------------------------------------------
# Command line
# ---------------------------------------------------------------------------------------------


def _build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="podtrace diff",
        description=(
            "Find where two podtrace recordings first part. RUN is a run directory "
            "(records.jsonl and meta.json) or a path to a records.jsonl[.gz] file."
        ),
        epilog="Exit code: 0 no differences, 1 differences found, 2 usage or input error.",
    )
    p.add_argument("runs", nargs="*", metavar="RUN", help="A and B; with --summary only one run")
    p.add_argument("--rtol", type=float, default=DEFAULT_RTOL, help="relative tolerance (1e-3)")
    p.add_argument("--atol", type=float, default=DEFAULT_ATOL, help="absolute tolerance (1e-6)")
    p.add_argument(
        "--ignore",
        action="append",
        default=[],
        metavar="PATTERN",
        help="glob; drops fields (such as ret.std or args.*) and calls with a matching name; repeatable",
    )
    p.add_argument(
        "--only",
        action="append",
        default=[],
        metavar="PATTERN",
        help="glob; compare only calls whose name matches; repeatable",
    )
    p.add_argument("--max", type=int, default=DEFAULT_MAX, help="differences to list (40)")
    p.add_argument("--json", metavar="PATH", help="also write all differences as JSON")
    p.add_argument("--format", choices=("text", "markdown"), default="text")
    p.add_argument("--summary", action="store_true", help="describe a single run instead")
    return p


def _run(ns: argparse.Namespace, parser: argparse.ArgumentParser) -> int:
    if ns.rtol < 0 or ns.atol < 0:
        raise InputError("--rtol and --atol must not be negative")
    if ns.max < 0:
        raise InputError("--max must not be negative")
    if ns.summary:
        if len(ns.runs) != 1:
            raise InputError("--summary takes exactly one run")
        run = load_run(ns.runs[0])
        sys.stdout.write(build_summary(run, ns.format, ns.max))
        if ns.json:
            try:
                Path(ns.json).write_text(json.dumps(summary_json(run), default=str) + "\n")
            except OSError as exc:
                raise InputError(f"cannot write {ns.json}: {exc}") from exc
        return 0
    if len(ns.runs) != 2:
        parser.print_usage(sys.stderr)
        raise InputError("two runs are needed, A and B (or one run with --summary)")
    a, b = load_run(ns.runs[0]), load_run(ns.runs[1])
    res = diff_runs(a, b, rtol=ns.rtol, atol=ns.atol, ignore=ns.ignore, only=ns.only)
    sys.stdout.write(build_report(res, ns.format, ns.max))
    if ns.json:
        write_json(ns.json, res)
    return 1 if res.has_differences else 0


def main(argv: list[str] | None = None) -> int:
    """Entry point for ``podtrace diff``. A leading ``diff`` word in ``argv`` is accepted."""
    args = list(sys.argv[1:] if argv is None else argv)
    if args and args[0] == "diff" and not os.path.exists("diff"):
        args = args[1:]
    parser = _build_parser()
    try:
        ns = parser.parse_args(args)
    except SystemExit as exc:
        return exc.code if isinstance(exc.code, int) else 2
    try:
        return _run(ns, parser)
    except InputError as exc:
        print(f"podtrace diff: error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
