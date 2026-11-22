"""Tests for podtrace.compare (the ``podtrace diff`` command)."""

from __future__ import annotations

import gzip
import importlib
import importlib.util
import json
import resource
import sys
import time
from pathlib import Path
from typing import Any

import pytest

try:
    compare = importlib.import_module("podtrace.compare")
except ModuleNotFoundError:  # run from the repository root without an installed package
    _path = Path(__file__).resolve().parents[1] / "src" / "podtrace" / "compare.py"
    _spec = importlib.util.spec_from_file_location("podtrace_compare_under_test", _path)
    assert _spec is not None
    assert _spec.loader is not None
    compare = importlib.util.module_from_spec(_spec)
    sys.modules[_spec.name] = compare
    _spec.loader.exec_module(compare)


# ---------------------------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------------------------


def scalar(v: float) -> dict[str, Any]:
    return {"t": "float", "v": v}


def tensor(mean: float = 0.0, **kw: Any) -> dict[str, Any]:
    t: dict[str, Any] = {
        "t": "tensor",
        "id": 1,
        "ver": 0,
        "shape": [2, 3],
        "dtype": "float32",
        "device": "cuda:0",
        "mean": mean,
        "std": 1.0,
        "absmean": abs(mean) + 0.5,
        "min": -2.0,
        "max": 2.0,
        "nan": 0,
        "inf": 0,
    }
    t.update(kw)
    return t


def node(name: str, children: list | None = None, **fields: Any) -> tuple:
    """A call spec: (name, fields, children)."""
    return (name, fields, children or [])


def make_records(roots: list[tuple], label: str = "run") -> list[dict[str, Any]]:
    """Turn nested call specs into records in the order the recorder writes them (post-order)."""
    out: list[dict[str, Any]] = []
    counter = [0]

    def visit(spec: tuple, parent: str | None) -> None:
        # iterative-safe enough for tests: trees here are shallow
        name, fields, children = spec
        counter[0] += 1
        seq = counter[0]
        span = f"{seq:016x}"
        for child in children:
            visit(child, span)
        rec = {
            "v": 1,
            "kind": fields.get("kind", "call"),
            "seq": seq,
            "trace_id": "0" * 32,
            "span_id": span,
            "parent_id": parent,
            "name": name,
            "module": "m",
            "file": "m.py",
            "line": 1,
            "start_ns": seq * 1000,
            "end_ns": seq * 1000 + 500,
            "thread": 1,
            "label": label,
            "args": fields.get("args", {}),
            "ret": fields.get("ret"),
            "exc": fields.get("exc"),
            "state": fields.get("state", []),
            "attrs": fields.get("attrs", {}),
        }
        out.append(rec)

    for r in roots:
        visit(r, None)
    return out


def write_run(
    root: Path,
    records: list[dict[str, Any]],
    *,
    meta: dict[str, Any] | None = None,
    gz: bool = False,
    truncate_last: bool = False,
) -> Path:
    root.mkdir(parents=True, exist_ok=True)
    text = "".join(json.dumps(r) + "\n" for r in records)
    if truncate_last:
        text = text[: -(len(json.dumps(records[-1])) // 2) - 1]
    if gz:
        (root / "records.jsonl.gz").write_bytes(gzip.compress(text.encode()))
    else:
        (root / "records.jsonl").write_text(text)
    (root / "meta.json").write_text(json.dumps(meta or {"files": {}}))
    return root


def run_pair(tmp_path: Path, spec_a: list[tuple], spec_b: list[tuple], **kw: Any) -> tuple:
    a = write_run(tmp_path / "a", make_records(spec_a, "good"), **kw)
    b = write_run(tmp_path / "b", make_records(spec_b, "bad"), **kw)
    return a, b


def base_tree(deviant: float = 1.0) -> list[tuple]:
    leaf = node("pkg.leaf", ret=tensor(deviant))
    mid = node("pkg.mid", [leaf, node("pkg.other", ret=scalar(1.0))], ret=tensor(deviant))
    top = node("pkg.top", [node("pkg.pre", ret=scalar(0.0)), mid], ret=tensor(deviant))
    return [node("pkg.main", [top], ret=scalar(7.0))]


# ---------------------------------------------------------------------------------------------
# Behaviour
# ---------------------------------------------------------------------------------------------


def test_identical_runs_exit_zero(tmp_path, capsys):
    a, b = run_pair(tmp_path, base_tree(), base_tree())
    assert compare.main([str(a), str(b)]) == 0
    out = capsys.readouterr().out
    assert "No differences were found" in out


def test_leading_diff_word_is_accepted(tmp_path):
    a, b = run_pair(tmp_path, base_tree(), base_tree())
    assert compare.main(["diff", str(a), str(b)]) == 0


def test_deep_deviation_is_reported_first_with_path(tmp_path, capsys):
    a, b = run_pair(tmp_path, base_tree(1.0), base_tree(2.0))
    code = compare.main([str(a), str(b)])
    assert code == 1
    out = capsys.readouterr().out
    first = out.split("First difference")[1].split("Later differences")[0]
    assert "pkg.leaf" in first
    for name in ("pkg.main", "pkg.top", "pkg.mid"):
        assert name in first  # path from the root
    assert "ret.mean" in first
    assert "50%" in first  # |1-2| / max(1, 2)
    # parents differ only through the leaf: collapsed, not listed
    res = compare.diff_runs(compare.load_run(a), compare.load_run(b))
    assert res.changed[0].name == "pkg.top"  # first in seq order ...
    assert res.first() is not None
    assert res.first().name == "pkg.leaf"  # ... but not the first non-inherited one
    inherited = {d.name for d in res.changed if d.inherited}
    assert inherited == {"pkg.top", "pkg.mid"}


def test_deviation_value_is_relative_to_larger(tmp_path):
    a, b = run_pair(tmp_path, base_tree(1.0), base_tree(2.0))
    res = compare.diff_runs(compare.load_run(a), compare.load_run(b))
    ch = {c.field: c for c in res.first().changes}
    assert ch["ret.mean"].rel_dev == pytest.approx(0.5)
    assert ch["ret.mean"].abs_dev == pytest.approx(1.0)


def test_tolerance(tmp_path):
    a, b = run_pair(tmp_path, base_tree(1.0), base_tree(1.0 + 1e-4))
    assert compare.main([str(a), str(b)]) == 0  # inside the default rtol of 1e-3
    assert compare.main([str(a), str(b), "--rtol", "1e-6", "--atol", "0"]) == 1
    # absolute tolerance rescues small values
    a2, b2 = run_pair(tmp_path / "x", [node("f", ret=scalar(1e-9))], [node("f", ret=scalar(5e-9))])
    assert compare.main([str(a2), str(b2)]) == 0
    assert compare.main([str(a2), str(b2), "--atol", "0", "--rtol", "1e-3"]) == 1


def test_extra_call_does_not_shift_later_siblings(tmp_path):
    def kids(extra: bool, last: float) -> list[tuple]:
        items = [node("s.a", ret=scalar(1.0)), node("s.b", ret=scalar(2.0))]
        if extra:
            items.insert(1, node("s.extra", [node("s.inner")], ret=scalar(9.0)))
        items.append(node("s.c", ret=scalar(last)))
        return [node("root", items)]

    a, b = run_pair(tmp_path, kids(False, 3.0), kids(True, 3.0))
    res = compare.diff_runs(compare.load_run(a), compare.load_run(b))
    assert res.changed == []
    assert [(d.name, d.size) for d in res.only_b] == [("s.extra", 2)]
    assert res.only_a == []
    assert compare.main([str(a), str(b)]) == 1
    # a real difference in a later sibling is still found and attributed to the right call
    a, b = run_pair(tmp_path / "y", kids(False, 3.0), kids(True, 4.0))
    res = compare.diff_runs(compare.load_run(a), compare.load_run(b))
    assert [d.name for d in res.changed] == ["s.c"]


def test_missing_subtree(tmp_path, capsys):
    full = [node("root", [node("x", [node("y"), node("y")]), node("z")])]
    cut = [node("root", [node("z")])]
    a, b = run_pair(tmp_path, full, cut)
    assert compare.main([str(a), str(b)]) == 1
    res = compare.diff_runs(compare.load_run(a), compare.load_run(b))
    assert [(d.name, d.size) for d in res.only_a] == [("x", 3)]
    assert res.changed == []
    out = capsys.readouterr().out
    assert "Structural differences" in out


def test_state_entries(tmp_path):
    def st(after: Any, extra: bool = False) -> list[tuple]:
        state = [{"target": "self", "attr": "cache", "before": None, "after": after}]
        if extra:
            state.append({"target": "arg:x", "attr": "[k]", "before": None, "after": scalar(1)})
        return [node("f", state=state)]

    a, b = run_pair(tmp_path, st(scalar(1.0)), st(scalar(2.0)))
    res = compare.diff_runs(compare.load_run(a), compare.load_run(b))
    assert [c.field for c in res.changed[0].changes] == ["state[self.cache].after"]
    a, b = run_pair(tmp_path / "e", st(scalar(1.0)), st(scalar(1.0), extra=True))
    res = compare.diff_runs(compare.load_run(a), compare.load_run(b))
    fields = [(c.field, c.where) for c in res.changed[0].changes]
    assert fields == [("state[arg:x[k]]", "only in B")]


def test_profile_locates_bin(tmp_path):
    edges = [0, 10, 20, 30, 40]

    def prof(vals: list[float]) -> dict[str, Any]:
        return tensor(0.5, profile={"axis": 2, "edges": edges, "absmean": vals})

    a, b = run_pair(
        tmp_path,
        [node("f", ret=prof([1.0, 1.0, 1.0, 1.0]))],
        [node("f", ret=prof([1.0, 1.0, 1.5, 1.01]))],
    )
    res = compare.diff_runs(compare.load_run(a), compare.load_run(b))
    (change,) = res.changed[0].changes
    assert change.field == "ret.profile.absmean"
    assert change.where["bin"] == 2
    assert change.where["edges"] == [20, 30]
    assert change.where["axis"] == 2
    assert change.where["bins_differing"] == 2  # bins 2 and 3 (1% off) are beyond 1e-3
    assert change.rel_dev == pytest.approx(0.5 / 1.5)


def test_segments(tmp_path):
    a, b = run_pair(
        tmp_path,
        [node("f", ret=tensor(0.5, segments={"text": 0.4, "video": 0.8}))],
        [node("f", ret=tensor(0.5, segments={"text": 0.4, "video": 0.4}))],
    )
    res = compare.diff_runs(compare.load_run(a), compare.load_run(b))
    (change,) = res.changed[0].changes
    assert change.field == "ret.segments"
    assert change.where["segment"] == "video"


def test_fp_shortcut(tmp_path):
    # equal fingerprints: contents are identical, so a (nonsensical) stats difference is ignored
    a, b = run_pair(
        tmp_path,
        [node("f", ret=tensor(1.0, fp="abc"))],
        [node("f", ret=tensor(9.0, fp="abc"))],
    )
    assert compare.main([str(a), str(b)]) == 0
    a, b = run_pair(
        tmp_path / "d",
        [node("f", ret=tensor(1.0, fp="abc"))],
        [node("f", ret=tensor(9.0, fp="abd"))],
    )
    assert compare.main([str(a), str(b)]) == 1


def test_ignored_fields_by_default(tmp_path):
    a, b = run_pair(
        tmp_path,
        [node("f", ret=tensor(1.0, id=1, ver=3, device="cuda:0"))],
        [node("f", ret=tensor(1.0, id=7, ver=9, device="cpu"))],
    )
    assert compare.main([str(a), str(b)]) == 0


def test_dtype_and_nan_count_differences(tmp_path):
    a, b = run_pair(
        tmp_path,
        [node("f", ret=tensor(1.0)), node("g", ret=tensor(1.0))],
        [node("f", ret=tensor(1.0, dtype="bfloat16")), node("g", ret=tensor(1.0, nan=3))],
    )
    res = compare.diff_runs(compare.load_run(a), compare.load_run(b))
    assert [c.field for c in res.changed[0].changes] == ["ret.dtype"]
    assert [c.field for c in res.changed[1].changes] == ["ret.nan"]


def test_truncated_last_line(tmp_path, capsys):
    recs = make_records(base_tree())
    a = write_run(tmp_path / "a", recs)
    b = write_run(tmp_path / "b", recs, truncate_last=True)
    run = compare.load_run(b)
    assert run.truncated
    assert len(run) == len(recs) - 1
    # the lost record was the root; its children become roots and are counted as orphans
    assert run.orphans == 1
    assert compare.main([str(a), str(b)]) == 1
    assert "cut off" in capsys.readouterr().out


def test_orphans_are_roots(tmp_path):
    recs = make_records([node("r", [node("c")])])
    recs = [r for r in recs if r["name"] != "r"]  # drop the parent
    run = compare.load_run(write_run(tmp_path / "o", recs))
    assert run.orphans == 1
    assert [run.recs[i].name for i in run.roots] == ["c"]


def test_gzip_input_file_and_directory(tmp_path):
    a, b = run_pair(tmp_path, base_tree(), base_tree(), gz=True)
    assert compare.main([str(a), str(b)]) == 0
    # a path to the .gz file itself
    assert compare.main([str(a / "records.jsonl.gz"), str(b / "records.jsonl.gz")]) == 0


def test_truncated_gzip(tmp_path):
    recs = make_records(base_tree())
    d = tmp_path / "t"
    d.mkdir()
    data = gzip.compress(("".join(json.dumps(r) + "\n" for r in recs)).encode())
    (d / "records.jsonl.gz").write_bytes(data[: len(data) - 10])
    run = compare.load_run(d)
    assert run.truncated


def test_only_and_ignore(tmp_path):
    spec_a = [node("root", [node("pkg.f", ret=scalar(1.0)), node("pkg.g", ret=scalar(1.0))])]
    spec_b = [node("root", [node("pkg.f", ret=scalar(2.0)), node("pkg.g", ret=scalar(2.0))])]
    a, b = run_pair(tmp_path, spec_a, spec_b)
    la, lb = compare.load_run(a), compare.load_run(b)
    assert [d.name for d in compare.diff_runs(la, lb).changed] == ["pkg.f", "pkg.g"]
    only = compare.diff_runs(la, lb, only=["pkg.g"])
    assert [d.name for d in only.changed] == ["pkg.g"]
    assert [d.name for d in compare.diff_runs(la, lb, ignore=["pkg.f"]).changed] == ["pkg.g"]
    assert compare.diff_runs(la, lb, ignore=["pkg.*"]).changed == []
    assert compare.main([str(a), str(b), "--only", "nothing.*"]) == 0
    assert compare.main([str(a), str(b), "--ignore", "pkg.*"]) == 0
    # field-level ignore
    ta, tb = run_pair(
        tmp_path / "t",
        [node("f", ret=tensor(1.0, std=1.0))],
        [node("f", ret=tensor(1.0, std=2.0))],
    )
    assert compare.main([str(ta), str(tb)]) == 1
    assert compare.main([str(ta), str(tb), "--ignore", "ret.std"]) == 0
    assert compare.main([str(ta), str(tb), "--ignore", "std"]) == 0
    assert compare.main([str(ta), str(tb), "--ignore", "ret.*"]) == 0


def test_json_output(tmp_path):
    a, b = run_pair(tmp_path, base_tree(1.0), base_tree(2.0))
    out = tmp_path / "out.json"
    assert compare.main([str(a), str(b), "--json", str(out)]) == 1
    data = json.loads(out.read_text())
    assert data["format"] == "podtrace-diff"
    assert data["matched_calls"] == 6
    diffs = data["differences"]
    assert [d["name"] for d in diffs][:3] == ["pkg.top", "pkg.mid", "pkg.leaf"]
    leaf = diffs[2]
    assert not leaf["inherited"]
    assert [p["name"] for p in leaf["path"]] == ["pkg.main", "pkg.top", "pkg.mid", "pkg.leaf"]
    assert leaf["changes"][0]["field"] == "ret.mean"
    assert leaf["changes"][0]["rel_dev"] == pytest.approx(0.5)
    assert data["drift"]


def test_json_is_strict_with_infinite_deviation(tmp_path):
    a, b = run_pair(
        tmp_path,
        [node("f", ret=tensor(1.0))],
        [node("f", ret={**tensor(1.0), "mean": "nan"})],
    )
    out = tmp_path / "o.json"
    assert compare.main([str(a), str(b), "--json", str(out)]) == 1
    json.loads(out.read_text(), parse_constant=lambda c: pytest.fail(f"non-strict {c}"))


def test_code_difference_in_header(tmp_path, capsys):
    ma = {"instrumented": {"src/model.py": "a" * 64, "src/same.py": "c" * 64}}
    mb = {"instrumented": {"src/model.py": "b" * 64, "src/same.py": "c" * 64}}
    a = write_run(tmp_path / "a", make_records(base_tree()), meta=ma)
    b = write_run(tmp_path / "b", make_records(base_tree()), meta=mb)
    assert compare.main([str(a), str(b)]) == 0
    out = capsys.readouterr().out
    assert "did not use the same code" in out
    assert "src/model.py" in out
    assert "src/same.py" not in out


def test_markdown_format(tmp_path, capsys):
    a, b = run_pair(tmp_path, base_tree(1.0), base_tree(2.0))
    assert compare.main([str(a), str(b), "--format", "markdown"]) == 1
    out = capsys.readouterr().out
    assert out.startswith("# podtrace comparison")
    assert "## First difference" in out
    assert "|---|" in out


def test_drift_table_shows_onset(tmp_path):
    def spec(dev_from: int) -> list[tuple]:
        kids = [
            node(f"step{i}", ret=tensor(1.0 + (0.5 if i >= dev_from else 0.0))) for i in range(40)
        ]
        return [node("root", kids)]

    a, b = run_pair(tmp_path, spec(10**6), spec(25))
    res = compare.diff_runs(compare.load_run(a), compare.load_run(b))
    beyond = [t[4] for t in res.drift]
    assert beyond == [False] * 25 + [True] * 15
    text = compare.build_report(res)
    assert "The first 25 of 40" in text


def test_usage_errors(tmp_path, capsys):
    assert compare.main([]) == 2
    assert compare.main([str(tmp_path / "missing"), str(tmp_path / "missing2")]) == 2
    a, b = run_pair(tmp_path, base_tree(), base_tree())
    assert compare.main([str(a), str(b), "--rtol", "-1"]) == 2
    assert compare.main([str(a), str(b), "--bogus"]) == 2
    assert compare.main([str(a)]) == 2
    err = capsys.readouterr().err
    assert "error" in err


def test_summary_mode(tmp_path, capsys):
    spec = [
        node(
            "root",
            [
                node("f", [node("g")]),
                node("f"),
                node("m", kind="mark", attrs={"note": "dropped 12 calls after the cap"}),
            ],
        )
    ]
    d = write_run(tmp_path / "s", make_records(spec))
    assert compare.main(["--summary", str(d)]) == 0
    out = capsys.readouterr().out
    assert "Calls per function name" in out
    assert "dropped 12 calls after the cap" in out
    assert "1 mark" in out or "contains 1 mark" in out
    s = compare.summarize_run(compare.load_run(d))
    assert s["counts"]["f"] == 2
    assert s["time_ns"]["f"] == 1000
    assert s["depth"] == 3
    assert [n for n, _, _ in s["deepest"]] == ["root", "f", "g"]
    assert len(s["marks"]) == 1
    assert compare.main(["--summary", str(d), str(d)]) == 2


def test_only_in_b_is_ordered_after_its_anchor(tmp_path):
    a, b = run_pair(
        tmp_path,
        [node("r", [node("a"), node("b")])],
        [node("r", [node("a"), node("new"), node("b")])],
    )
    res = compare.diff_runs(compare.load_run(a), compare.load_run(b))
    (d,) = res.only_b
    seq_a = compare.load_run(a).recs
    anchor = next(r.seq for r in seq_a if r.name == "a")
    assert d.sort_key == anchor + 0.5


# ---------------------------------------------------------------------------------------------
# Scale
# ---------------------------------------------------------------------------------------------


def synthetic(n: int, deviate_at: int | None, extra_at: int | None) -> list[dict[str, Any]]:
    """n records: a 3000-level deep chain, then a wide layer of siblings with tensors."""
    recs: list[dict[str, Any]] = []
    depth = 3000
    seq = 0
    parent = None
    chain: list[str] = []
    for i in range(depth):
        seq += 1
        span = f"{seq:016x}"
        chain.append(span)
        recs.append(_rec(seq, span, parent, f"deep.f{i % 7}", scalar(float(i))))
        parent = span
    top = chain[-1]
    width = n - depth
    for i in range(width):
        if extra_at is not None and i == extra_at:
            seq += 1
            recs.append(_rec(seq, f"{seq:016x}", top, "extra.call", None))
        seq += 1
        mean = 1.0 + i * 1e-3
        if deviate_at is not None and i >= deviate_at:
            mean *= 1.05
        recs.append(_rec(seq, f"{seq:016x}", top, f"wide.layer{i % 50}", tensor(mean)))
    # the recorder writes children before parents: reverse the chain part
    return recs[:depth][::-1] + recs[depth:]


def _rec(seq: int, span: str, parent: str | None, name: str, ret: Any) -> dict[str, Any]:
    return {
        "v": 1,
        "kind": "call",
        "seq": seq,
        "span_id": span,
        "parent_id": parent,
        "name": name,
        "start_ns": seq,
        "end_ns": seq + 1,
        "args": {},
        "ret": ret,
        "exc": None,
        "state": [],
    }


def test_large_pair_is_fast_and_bounded(tmp_path):
    n = 50_000
    a = write_run(tmp_path / "a", synthetic(n, None, None))
    b = write_run(tmp_path / "b", synthetic(n + 1, 30_000, 20_000))
    rss_before = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    t0 = time.perf_counter()
    la, lb = compare.load_run(a), compare.load_run(b)
    t_load = time.perf_counter() - t0
    t1 = time.perf_counter()
    res = compare.diff_runs(la, lb)
    t_diff = time.perf_counter() - t1
    rss_growth_mb = (resource.getrusage(resource.RUSAGE_SELF).ru_maxrss - rss_before) / 1024
    print(f"load {t_load:.2f}s diff {t_diff:.2f}s rss growth {rss_growth_mb:.0f}MB")
    assert len(la) == n
    assert t_load < 10
    assert t_diff < 10
    assert rss_growth_mb < 600
    # the inserted call, and the one layer record that run B has beyond run A's end
    assert [d.name for d in res.only_b] == ["extra.call", "wide.layer0"]
    first = res.first()
    assert first is not None
    assert first.name == "wide.layer0"  # the layer at index 30000 (30000 % 50 == 0)
    assert first.a_seq == 3000 + 30_000 + 1
    # the whole report and a deep path must not hit the recursion limit
    text = compare.build_report(res)
    assert "First difference" in text
    deepest = max(la.recs, key=lambda r: r.seq if r.name.startswith("deep.") else -1)
    assert len(compare.call_path(la, la.recs.index(deepest))) == 3000


def test_deep_chain_summary_and_diff_do_not_recurse(tmp_path):
    # make_records recurses, so build this chain of records iteratively
    recs = []
    for i in range(1500):
        recs.append(_rec(i + 1, f"{i + 1:016x}", f"{i:016x}" if i else None, f"n{i}", None))
    recs.reverse()
    a = write_run(tmp_path / "a", recs)
    b = write_run(tmp_path / "b", recs)
    assert compare.main([str(a), str(b)]) == 0
    assert compare.main(["--summary", str(a)]) == 0


def test_return_value_of_a_coroutine_or_generator_is_compared(tmp_path):
    def spec(value):
        return [
            node(
                "pkg.co",
                kind="gen",
                ret={"t": "gen", "yields": 0},
                attrs={"return": {"t": "int", "v": value}},
            )
        ]

    a, b = run_pair(tmp_path, spec(1), spec(2))
    res = compare.diff_runs(compare.load_run(a), compare.load_run(b))
    assert [d.name for d in res.changed] == ["pkg.co"]
    assert [c.field for c in res.changed[0].changes] == ["ret.return"]
    assert compare.main([str(a), str(b)]) == 1
    same_a, same_b = run_pair(tmp_path / "same", spec(1), spec(1))
    assert compare.main([str(same_a), str(same_b)]) == 0


def test_only_and_ignore_look_through_unmatched_subtrees(tmp_path):
    with_helper = [node("root", [node("helper", [node("pkg.target", ret=scalar(1.0))])])]
    bare = [node("root")]
    for side, (spec_a, spec_b) in {
        "only_a": (with_helper, bare),
        "only_b": (bare, with_helper),
    }.items():
        a, b = run_pair(tmp_path / side, spec_a, spec_b)
        la, lb = compare.load_run(a), compare.load_run(b)
        for kwargs in ({"only": ["pkg.target"]}, {"ignore": ["helper"]}):
            res = compare.diff_runs(la, lb, **kwargs)
            found = getattr(res, side)
            assert [d.name for d in found] == ["pkg.target"], (side, kwargs)
            assert not getattr(res, "only_b" if side == "only_a" else "only_a")
        assert compare.main([str(a), str(b), "--only", "pkg.target"]) == 1
        assert compare.main([str(a), str(b), "--ignore", "helper"]) == 1
        # a filter that selects nothing below the subtree still reports nothing
        assert compare.main([str(a), str(b), "--only", "nothing.*"]) == 0
        assert compare.main([str(a), str(b), "--ignore", "helper", "--ignore", "pkg.target"]) == 0
