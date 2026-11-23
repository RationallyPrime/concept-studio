import sys

import pytest

pytestmark = pytest.mark.skipif(
    not hasattr(sys, "monitoring"), reason="deep mode needs Python 3.12+"
)


def lines(h, suffix):
    return [r for r in h.records() if r["kind"] == "line" and r["name"].endswith(suffix)]


def test_deep_reports_changed_locals_per_line(h):
    h.start()
    m = h.module(
        """
        def f(n):
            total = 0
            for i in range(n):
                total += i
            label = "done"
            return total
        def g(): return 1
        """
    )
    h.record(True, deep=["*.f"])
    assert m.f(3) == 3
    m.g()
    recs = lines(h, ".f")
    assert recs and all(r["args"] == {} and r["parent_id"] for r in recs)
    by_line = {}
    for r in recs:
        by_line.setdefault(r["line"], []).append({s["attr"]: s for s in r["state"]})
    assert all(e["target"] == "local" for r in recs for e in r["state"])
    # `total = 0` on source line 3 sets total; the loop body (line 5) changes total and i
    assert by_line[3][0]["total"]["before"] is None and by_line[3][0]["total"]["after"]["v"] == 0
    assert [e["total"]["after"]["v"] for e in by_line[5] if "total" in e] == [1, 3]
    assert "label" in by_line[6][0] and by_line[6][0]["label"]["after"]["v"] == "done"
    assert not lines(h, ".g")
    call = next(r for r in h.by_name(".f") if r["kind"] == "call")
    assert all(r["parent_id"] == call["span_id"] for r in recs)
    assert all(r["seq"] > call["seq"] for r in recs)
    assert [r["seq"] for r in recs] == sorted(r["seq"] for r in recs)


def test_deep_follows_the_control_file_and_stops(h):
    h.start()
    m = h.module("def f():\n    x = 1\n    y = 2\n    return x + y\n")
    h.record(True, deep=["*.f"])
    m.f()
    n = len(lines(h, ".f"))
    assert n >= 2
    h.record(True, deep=[])
    m.f()
    assert len(lines(h, ".f")) == n


def test_deep_in_generators_and_with_exceptions(h):
    h.start()
    m = h.module(
        """
        def gen():
            a = 1
            yield a
            b = 2
            yield b
        def boom():
            z = 1
            raise ValueError(z)
        """
    )
    h.record(True, deep=["*.gen", "*.boom"])
    assert list(m.gen()) == [1, 2]
    with pytest.raises(ValueError):
        m.boom()
    g = lines(h, ".gen")
    assert {e["attr"] for r in g for e in r["state"]} >= {"a", "b"}
    b = lines(h, ".boom")
    assert any(e["attr"] == "z" for r in b for e in r["state"])


def test_deep_tensors_use_summaries(h):
    np = pytest.importorskip("numpy")
    h.start()
    m = h.module(
        """
        import numpy as np
        def f():
            a = np.zeros(4, dtype='float32')
            a = a + 1
            return a
        """
    )
    h.record(True, deep=["*.f"])
    m.f()
    changed = [e for r in lines(h, ".f") for e in r["state"] if e["attr"] == "a"]
    assert changed[0]["after"]["t"] == "ndarray" and changed[-1]["after"]["mean"] == 1.0
    assert np is not None


def test_deep_is_reported_unavailable_once_on_old_pythons(h, monkeypatch):
    from podtrace import deep, runtime

    monkeypatch.setattr(deep, "available", lambda: False)
    h.start()
    m = h.module("def f():\n    x = 1\n    return x\n")
    h.record(True, deep=["*.f"])
    m.f()
    m.f()
    marks = [r for r in h.records() if r["kind"] == "mark"]
    assert len(marks) == 1 and marks[0]["attrs"]["error"] == "deep_unavailable"
    assert not lines(h, ".f") and runtime.state.errors["deep_unavailable"] == 1
