import asyncio
import inspect
import sys
import textwrap

import pytest

from podtrace import runtime


def tree(records):
    by_id = {r["span_id"]: r for r in records}
    kids: dict = {}
    for r in records:
        kids.setdefault(r["parent_id"], []).append(r)
    for v in kids.values():
        v.sort(key=lambda r: r["seq"])

    def render(r):
        return [r["name"].rsplit(".", 1)[-1] + ":" + r["kind"]] + [
            render(c) for c in kids.get(r["span_id"], [])
        ]

    roots = [r for r in records if r["parent_id"] not in by_id]
    return [render(r) for r in sorted(roots, key=lambda r: r["seq"])]


def test_nested_calls_form_a_tree_with_ordered_seq(h):
    h.start()
    m = h.module(
        """
        def leaf(x): return x + 1
        def mid(x): return leaf(x) + leaf(x)
        def top(x): return mid(x)
        """
    )
    assert m.top(1) == 4
    recs = h.records()
    assert tree(recs) == [["top:call", ["mid:call", ["leaf:call"], ["leaf:call"]]]]
    by_name = {r["name"].rsplit(".", 1)[-1]: r for r in recs}
    assert by_name["top"]["seq"] < by_name["mid"]["seq"] < by_name["leaf"]["seq"]
    # Children are written before their parent.
    assert [r["name"].rsplit(".", 1)[-1] for r in recs] == ["leaf", "leaf", "mid", "top"]
    top = by_name["top"]
    assert top["v"] == 1 and top["parent_id"] is None and top["label"] == "t"
    assert len(top["trace_id"]) == 32 and len(top["span_id"]) == 16
    assert top["args"] == {"x": {"t": "int", "v": 1}} and top["ret"] == {"t": "int", "v": 4}
    assert top["line"] == 4 and top["module"].startswith("odd.")
    assert top["end_ns"] >= top["start_ns"] > 1_600_000_000 * 10**9


def test_record_off_passes_straight_through(h):
    h.start()
    m = h.module("def f(x): return x * 2\n")
    h.record(False)
    assert m.f(2) == 4
    h.record(True)
    assert m.f(3) == 6
    names = [r["name"] for r in h.records()]
    assert names.count(f"{m.__name__}.f") == 1


def test_arguments_are_bound_with_defaults_varargs_and_kwargs(h):
    h.start()
    m = h.module(
        """
        def f(a, b=2, *rest, k, d=5, **extra): return a
        """
    )
    m.f(1, 9, 8, 7, k=3, z=1)
    (r,) = h.by_name(".f")
    assert list(r["args"]) == ["a", "b", "k", "d", "rest", "extra"]
    assert r["args"]["rest"]["len"] == 2
    assert r["args"]["extra"]["items"]["z"] == {"t": "int", "v": 1}
    assert r["args"]["d"]["v"] == 5


def test_exception_is_recorded_and_reraised_unchanged(h):
    h.start()
    m = h.module(
        """
        def boom(): raise KeyError('k')
        def caller():
            try: boom()
            except KeyError: return 'handled'
        """
    )
    assert m.caller() == "handled"
    (b,) = h.by_name(".boom")
    assert b["exc"] == {"type": "KeyError", "msg": "'k'"} and b["ret"] is None
    (c,) = h.by_name(".caller")
    assert c["exc"] is None


def test_self_mutation_and_init_state(h):
    h.start()
    m = h.module(
        """
        class Box:
            def __init__(self):
                self.n = 0
                self.tags = []
            def bump(self):
                self.n += 1
                self.fresh = 'x'
                del self.tags
        """
    )
    b = m.Box()
    b.bump()
    (init,) = h.by_name("Box.__init__")
    assert init["kind"] == "init"
    assert [(s["attr"], s["before"]) for s in init["state"]] == [("n", None), ("tags", None)]
    assert init["state"][0]["after"] == {"t": "int", "v": 0}
    (bump,) = h.by_name("Box.bump")
    entries = {s["attr"]: s for s in bump["state"]}
    assert entries["n"]["before"] == {"t": "int", "v": 0} and entries["n"]["after"] == {
        "t": "int",
        "v": 1,
    }
    assert entries["fresh"]["before"] is None and entries["fresh"]["after"]["v"] == "x"
    assert entries["tags"]["after"] is None and entries["tags"]["before"]["t"] == "list"


def test_dict_and_list_argument_mutation(h):
    h.start()
    m = h.module(
        """
        def f(d, l):
            d['a'] = 2
            d['new'] = 1
            del d['gone']
            l[0] = 'z'
            l.append(4)
        """
    )
    m.f({"a": 1, "gone": 0}, [1, 2, 3])
    (r,) = h.by_name(".f")
    got = {(s["target"], s["attr"]): s for s in r["state"]}
    assert got[("arg:d", "[a]")]["before"]["v"] == 1 and got[("arg:d", "[a]")]["after"]["v"] == 2
    assert got[("arg:d", "[new]")]["before"] is None
    assert got[("arg:d", "[gone]")]["after"] is None
    assert got[("arg:l", "[0]")]["after"]["v"] == "z"
    assert got[("arg:l", "[3]")]["before"] is None and got[("arg:l", "[3]")]["after"]["v"] == 4


def test_unchanged_state_gives_empty_state(h):
    h.start()
    m = h.module(
        """
        class C:
            def __init__(self): self.v = [1]
            def read(self, d): return len(self.v) + len(d)
        """
    )
    m.C().read({"a": 1})
    (r,) = h.by_name("C.read")
    assert r["state"] == []


def test_generators_get_gen_records_and_are_not_attached_across_yield(h):
    h.start()
    m = h.module(
        """
        def child(): return 1
        def numbers(n):
            for i in range(n):
                child()
                yield i
            return 'done'
        def consume():
            out = []
            for v in numbers(3):
                out.append(child())     # sibling of the generator, not its child
            return out
        """
    )
    assert m.consume() == [1, 1, 1]
    recs = h.records()
    (gen,) = [r for r in recs if r["kind"] == "gen"]
    assert gen["ret"] == {"t": "gen", "yields": 3} and gen["attrs"]["return"]["v"] == "done"
    kids = [r for r in recs if r["parent_id"] == gen["span_id"]]
    assert len(kids) == 3
    cons = next(r for r in recs if r["name"].endswith(".consume"))
    sibling_children = [
        r for r in recs if r["parent_id"] == cons["span_id"] and r["name"].endswith(".child")
    ]
    assert len(sibling_children) == 3
    assert runtime._CTX.get() is None


def test_generator_functions_stay_generator_functions_and_support_send_throw_close(h):
    h.start()
    m = h.module(
        """
        def echo():
            got = []
            try:
                while True:
                    got.append((yield len(got)))
            except ZeroDivisionError:
                yield 'caught'
            finally:
                got.append('closed')
        """
    )
    assert inspect.isgeneratorfunction(m.echo)
    g = m.echo()
    assert next(g) == 0
    assert g.send("a") == 1
    assert g.throw(ZeroDivisionError) == "caught"
    g.close()
    (r,) = h.by_name(".echo")
    assert r["kind"] == "gen" and r["exc"] is None and r["ret"]["yields"] == 3


def test_unfinished_generator_is_recorded_when_closed(h):
    h.start()
    m = h.module("def g():\n    yield 1\n    yield 2\n")
    gen = m.g()
    next(gen)
    gen.close()
    (r,) = h.by_name(".g")
    assert r["ret"]["yields"] == 1


def test_contextmanager_and_decorator_stacking(h):
    h.start()
    m = h.module(
        """
        import contextlib, functools
        @contextlib.contextmanager
        def cm(v):
            yield v + 1
        def deco(fn):
            @functools.wraps(fn)
            def w(*a, **k): return fn(*a, **k)
            return w
        class K:
            @staticmethod
            def s(a): return a * 2
            @classmethod
            def c(cls, a): return cls
            @property
            def p(self): return 7
            @deco
            @staticmethod
            def both(a): return a
            def m(self, a): return a
        """
    )
    with m.cm(1) as v:
        assert v == 2
    k = m.K()
    assert (m.K.s(2), m.K.c(0), k.p, k.m(5)) == (4, m.K, 7, 5)
    names = {r["name"].rsplit(".", 1)[-1] for r in h.records()}
    assert {"cm", "s", "c", "p", "m"} <= names
    assert inspect.signature(m.K.s).parameters.keys() == {"a"}
    assert inspect.signature(k.m).parameters.keys() == {"a"}
    assert isinstance(inspect.getattr_static(m.K, "s"), staticmethod)
    assert isinstance(inspect.getattr_static(m.K, "c"), classmethod)


def test_dataclass_enum_namedtuple_protocol_typeddict_keep_working(h):
    h.start()
    m = h.module(
        """
        import dataclasses, enum, typing
        @dataclasses.dataclass
        class D:
            a: int
            b: str = 'x'
            def total(self): return self.a
        @dataclasses.dataclass(frozen=True)
        class F:
            a: int
        @dataclasses.dataclass(slots=True)
        class S:
            a: int
        class E(enum.Enum):
            RED = 1
            BLUE = 2
            def twice(self): return self.value * 2
        class P(typing.NamedTuple):
            x: int
            y: int = 2
            def norm(self): return self.x + self.y
        class Proto(typing.Protocol):
            def run(self) -> int: ...
        class Impl:
            def run(self): return 3
        class TD(typing.TypedDict):
            k: int
        def use():
            return D(1).total(), F(2).a, S(3).a, E.BLUE.twice(), P(1).norm(), Impl().run(), TD(k=1)['k']
        """
    )
    assert m.use() == (1, 2, 3, 4, 3, 3, 1)
    inits = [r["name"].rsplit(".", 2)[-2] for r in h.records() if r["kind"] == "init"]
    assert {"D", "F", "S"} <= set(inits)
    d_init = next(r for r in h.records() if r["name"].endswith("D.__init__"))
    assert {s["attr"] for s in d_init["state"]} == {"a", "b"}
    assert m.E.RED.value == 1 and list(m.E) == [m.E.RED, m.E.BLUE]
    assert m.P(1, 2) == (1, 2)


def test_class_decorator_does_not_break_slots_or_inheritance(h):
    h.start()
    m = h.module(
        """
        class Base:
            __slots__ = ('a',)
            def __init__(self): self.a = 1
        class Child(Base):
            def __init__(self):
                super().__init__()
                self.b = 2
        """
    )
    c = m.Child()
    assert (c.a, c.b) == (1, 2)
    kinds = [(r["name"].rsplit(".", 2)[-2], r["kind"]) for r in h.records()]
    assert ("Base", "init") in kinds and ("Child", "init") in kinds


def test_async_coroutine_and_async_generator(h):
    h.start()
    m = h.module(
        """
        async def child(): return 5
        async def co(): return await child() + 1
        async def agen(n):
            for i in range(n):
                await child()
                yield i
        async def drive():
            return [i async for i in agen(2)]
        """
    )
    assert inspect.iscoroutinefunction(m.co) and inspect.isasyncgenfunction(m.agen)
    assert asyncio.run(m.co()) == 6
    assert asyncio.run(m.drive()) == [0, 1]
    recs = h.records()
    assert tree(recs)[0] == ["co:gen", ["child:gen"]]
    ag = next(r for r in recs if r["name"].endswith(".agen"))
    assert ag["ret"] == {"t": "gen", "yields": 2}
    assert len([r for r in recs if r["parent_id"] == ag["span_id"]]) == 2


def test_per_parent_cap_counts_and_reports_a_mark(h):
    h.start(per_parent_cap=5)
    m = h.module(
        """
        def leaf(i): return deeper(i)
        def deeper(i): return i
        def top():
            return sum(leaf(i) for i in range(8))
        """
    )
    assert m.top() == 28
    recs = h.records()
    assert len([r for r in recs if r["name"].endswith(".leaf")]) == 5
    # the skipped calls' own children are not attributed to anything
    assert len([r for r in recs if r["name"].endswith(".deeper")]) == 5
    (mark,) = [r for r in recs if r["kind"] == "mark"]
    top = next(r for r in recs if r["name"].endswith(".top"))
    assert mark["parent_id"] == top["span_id"] and mark["seq"] > top["seq"]
    assert mark["attrs"]["calls"] == 8 and mark["attrs"]["skipped"] == 3
    assert mark["attrs"]["function"].endswith(".leaf")


def test_traced_functions_called_by_the_recorder_pass_through(h):
    h.start()
    m = h.module(
        """
        class Spy(dict):
            def items(self):
                return super().items()
        def f(x):
            return len(x.items())
        """
    )
    assert m.f(m.Spy(a=1, b=2)) == 2
    names = [r["name"].rsplit(".", 1)[-1] for r in h.records()]
    # the recorder called items() itself while summarizing the argument: not recorded
    assert names.count("items") == 1 and names.count("f") == 1


def test_recorder_errors_never_reach_the_program_and_are_reported_once(h, monkeypatch, capsys):
    h.start()
    m = h.module("def f(x): return x + 1\n")

    def broken(*a, **k):
        raise RuntimeError("summary exploded")

    monkeypatch.setattr(runtime.Summarizer, "summarize", broken)
    assert [m.f(i) for i in range(3)] == [1, 2, 3]
    monkeypatch.undo()
    assert m.f(10) == 11
    recs = h.records()
    marks = [r for r in recs if r["kind"] == "mark"]
    assert len(marks) == 1 and marks[0]["attrs"]["error"] == "begin"
    assert runtime.state.errors["begin"] == 3
    assert "recorder error (begin)" in capsys.readouterr().err
    assert len([r for r in recs if r["name"].endswith(".f")]) == 1


def test_error_in_finish_still_returns_the_value(h, monkeypatch):
    h.start()
    m = h.module("def f(d): return [d]\n")
    monkeypatch.setattr(runtime, "_diff_args", lambda *a, **k: 1 / 0)
    assert m.f({}) == [{}]
    assert runtime.state.errors.get("finish") == 1


def test_compile_check_passes_through(h, monkeypatch):
    h.start()
    m = h.module("def f(): return 1\n")
    monkeypatch.setattr(runtime, "_skip_now", lambda: True)
    assert m.f() == 1
    assert not h.run_dirs()


def test_two_threads_have_their_own_trees_and_aliases(h):
    import threading

    h.start()
    m = h.module("def f(i): return g(i)\ndef g(i): return i\n")
    ts = [threading.Thread(target=m.f, args=(i,)) for i in range(2)]
    for t in ts:
        t.start()
    for t in ts:
        t.join()
    recs = h.records()
    assert {r["thread"] for r in recs} == {1, 2}
    assert len([r for r in recs if r["parent_id"] is None]) == 2
    assert len({r["trace_id"] for r in recs}) == 2


def test_loaded_via_normal_import_and_via_spec_both_instrumented(h):
    h.start()
    a = h.module("def f(): return 1\n", name="viaimport", via="import")
    b = h.module("def f(): return 2\n", name="viaspec", via="spec")
    assert (a.f(), b.f()) == (1, 2)
    names = {r["name"] for r in h.records()}
    assert names == {"viaimport.f", "odd.viaspec.f"}


def test_files_not_matching_any_rule_are_untouched_and_no_pyc_is_written(h, tmp_path):
    h.start(include=[{"path": "**/never/*.py"}])
    m = h.module("def f(): return 1\n")
    assert not hasattr(m, "__podtrace_s__") and m.f() == 1
    h.start(include=[{"path": f"{h.pkg_dir.as_posix()}/**/*.py"}])
    m2 = h.module("def f(): return 1\n", name="viaimport2", via="import")
    assert hasattr(m2, "__podtrace_s__")
    assert not list(h.pkg_dir.rglob("viaimport2*.pyc"))


def test_label_change_and_new_recording_start_new_run_directories(h):
    h.start()
    m = h.module("def f(): return 1\n")
    m.f()
    h.record(True, label="second")
    m.f()
    h.record(False)
    h.record(True, label="second")
    m.f()
    dirs = [p.name for p in h.run_dirs()]
    assert len(dirs) == 3
    assert dirs[0].startswith("second-") or dirs[0].startswith("t-")
    labels = sorted(d.split("-")[0] for d in dirs)
    assert labels == ["second", "second", "t"]
    for run in (0, 1, 2):
        recs = h.records(run)
        assert len(recs) == 1 and recs[0]["seq"] == 1


def test_syntax_that_cannot_be_transformed_falls_back_to_plain_import(h, capsys):
    h.start()
    h.pkg_dir.joinpath("badone.py").write_text("def f(:\n")
    import importlib

    sys.path.insert(0, str(h.pkg_dir))
    try:
        with pytest.raises(SyntaxError):
            importlib.import_module("badone")
    finally:
        sys.path.remove(str(h.pkg_dir))
    assert "not instrumenting" in capsys.readouterr().err


def test_meta_json_lists_files_with_hashes(h):
    import hashlib
    import json

    h.start()
    m = h.module("def f(): return 1\n", name="hashed")
    m.f()
    meta = json.loads((h.run_dirs()[-1] / "meta.json").read_text())
    entry = next(f for f in meta["files"] if f["path"].endswith("hashed.py"))
    assert entry["sha256"] == hashlib.sha256((h.pkg_dir / "hashed.py").read_bytes()).hexdigest()
    assert (
        meta["schema"] == 1 and meta["label"] == "t" and meta["python"].startswith(sys.version[:4])
    )
    assert textwrap.dedent("x")


def _all_strings(obj):
    if isinstance(obj, str):
        yield obj
    elif isinstance(obj, dict):
        for k, v in obj.items():
            yield from _all_strings(k)
            yield from _all_strings(v)
    elif isinstance(obj, list):
        for v in obj:
            yield from _all_strings(v)


def test_state_entries_redact_sensitive_values_before_and_after(h):
    h.start()
    m = h.module(
        """
        class Client:
            def __init__(self):
                self.api_key = 'old-attr-secret'
                self.plain = 'old-plain'
            def rotate(self):
                self.api_key = 'new-attr-secret'
                self.plain = 'new-plain'
        def swap(d):
            d['token'] = 'new-dict-secret'
            d['config'] = {'password': 'new-nested-secret'}
        def swap_tokens(tokens):
            tokens[0] = 'new-token-list'
        """
    )
    c = m.Client()
    c.rotate()
    m.swap({"token": "old-dict-secret", "config": {"password": "old-nested-secret"}})
    m.swap_tokens(["old-token-list"])
    text = str(h.records())
    for leaked in (
        "old-attr-secret",
        "new-attr-secret",
        "old-dict-secret",
        "new-dict-secret",
        "new-nested-secret",
        "old-token-list",
        "new-token-list",
    ):
        assert leaked not in text, leaked
    (rotate,) = h.by_name("Client.rotate")
    entries = {s["attr"]: s for s in rotate["state"]}
    assert entries["api_key"]["before"]["sha"] and "v" not in entries["api_key"]["before"]
    assert entries["plain"]["before"]["v"] == "old-plain"
    assert entries["plain"]["after"]["v"] == "new-plain"
    (swap,) = h.by_name(".swap")
    by_attr = {s["attr"]: s for s in swap["state"]}
    assert "v" not in by_attr["[token]"]["before"] and "v" not in by_attr["[token]"]["after"]
    assert by_attr["[token]"]["before"]["len"] == len("old-dict-secret")
    (tl,) = h.by_name(".swap_tokens")
    (entry,) = tl["state"]
    assert "v" not in entry["before"] and "v" not in entry["after"]


def test_deep_line_records_redact_sensitive_locals(h):
    if not hasattr(sys, "monitoring"):
        pytest.skip("deep mode needs Python 3.12+")
    h.start()
    m = h.module(
        """
        def local(x):
            secret = 'old-local-secret'
            secret = 'new-local-secret'
            plain = 'visible'
            return x
        """
    )
    h.record(True, deep=["*.local"])
    m.local(1)
    text = str(h.records())
    assert "old-local-secret" not in text and "new-local-secret" not in text
    assert "visible" in text


def test_label_change_waits_for_an_open_root_before_starting_a_new_run(h):
    h.start()
    m = h.module(
        """
        def gen():
            yield 1
            yield 2
        def other(): return 0
        """
    )
    g = m.gen()
    assert next(g) == 1  # a root span is now open
    h.record(True, label="second")
    m.other()  # a new root while the generator is still open
    assert list(g) == [2]
    m.other()  # nothing is open any more: this one starts the new run
    assert len(h.run_dirs()) == 2
    by_label = {d.name.split("-")[0]: i for i, d in enumerate(h.run_dirs())}
    first, second = h.records(by_label["t"]), h.records(by_label["second"])
    assert [r["label"] for r in first] == ["t", "t"]
    assert len({r["seq"] for r in first}) == 2
    assert [r["label"] for r in second] == ["second"]
    assert second[0]["seq"] == 1


def test_defaults_are_bound_per_function_object_not_per_source_site(h):
    h.start()
    m = h.module(
        """
        def make(v, w):
            def f(x=v, *, k=w):
                x_seen = x
                return x_seen
            return f
        def mutate(d={}):
            d['n'] = len(d)
        def mutator(v):
            def g(d=v):
                d['hit'] = 1
            return g
        """
    )
    f1, f2 = m.make(1, 10), m.make(2, 20)
    f1()
    f2()
    calls = [r for r in h.by_name(".f")]
    assert [(r["args"]["x"]["v"], r["args"]["k"]["v"]) for r in calls] == [(1, 10), (2, 20)]
    first, second = {}, {}
    g1, g2 = m.mutator(first), m.mutator(second)
    g1()
    g2()
    states = [r["state"] for r in h.by_name(".g")]
    assert all(len(s) == 1 and s[0]["attr"] == "[hit]" for s in states)
    assert first == {"hit": 1} and second == {"hit": 1}
