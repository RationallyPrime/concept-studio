import enum
import math
import pathlib
from itertools import pairwise

import pytest

from podtrace import config, summary, tensors
from podtrace.summary import Aliases, Summarizer, TensorCache


def make(**kw):
    cfg = config.from_dict({"summary": kw} if kw else {})
    return Summarizer(cfg, Aliases(), TensorCache())


def S(value, level="full", **kw):
    return make(**kw).summarize(value, level, set())


def test_primitives():
    assert S(None) == {"t": "none"}
    assert S(True) == {"t": "bool", "v": True}
    assert S(3) == {"t": "int", "v": 3}
    assert S(1.5) == {"t": "float", "v": 1.5}
    assert S(float("nan"))["v"] == "nan"
    assert S(float("inf"))["v"] == "inf" and S(float("-inf"))["v"] == "-inf"


def test_strings_record_text_only_when_short_or_enabled():
    short = S("hello")
    assert short["v"] == "hello" and short["len"] == 5 and len(short["sha"]) == 12
    long = S("x" * 100)
    assert "v" not in long and long["len"] == 100
    assert S("x" * 100, **{}) == long
    cfg = config.from_dict({"text": True})
    assert "v" in Summarizer(cfg, Aliases(), TensorCache()).summarize("x" * 100, "full", set())
    import hashlib

    assert short["sha"] == hashlib.sha256(b"hello").hexdigest()[:12]
    assert S(b"abc")["t"] == "bytes" and S(b"abc")["len"] == 3


def test_sensitive_names_never_leak_values():
    s = make()
    out = s.summarize(
        {"api_key": "sk-123", "user": "ann", "nested": {"password": "pw"}}, "full", set()
    )
    assert "v" not in out["items"]["api_key"] and out["items"]["user"]["v"] == "ann"
    assert "v" not in out["items"]["nested"]["items"]["password"]
    assert "v" not in s.summarize("sk-123", "full", set(), redact=True)


def test_containers_are_truncated_and_deterministic():
    out = S(list(range(100)))
    assert out["t"] == "list" and out["len"] == 100 and len(out["items"]) == 4
    assert S((1, "a"))["t"] == "tuple"
    d = S({f"k{i}": i for i in range(20)})
    assert d["len"] == 20 and list(d["items"]) == [f"k{i}" for i in range(8)]
    st = S({"b", "a", "c"})
    assert st["t"] == "set" and [i["v"] for i in st["items"]] == ["a", "b", "c"]


def test_depth_and_node_budget_cut():
    deep = [[[[[1]]]]]
    out = S(deep)
    node = out
    for _ in range(4):
        node = node["items"][0]
    assert node["t"] == "cut"
    wide = S([list(range(3)) for _ in range(4)], max_nodes=3)
    flat = repr(wide)
    assert "'cut'" in flat


class Thing:
    def __init__(self):
        self.a = 1
        self._b = [1, 2]
        self.big = "y" * 200


class Slotted:
    __slots__ = ("p", "q")

    def __init__(self):
        self.p, self.q = 1, 2


class Colour(enum.Enum):
    RED = 1


def test_objects_enums_functions_paths():
    s = make()
    t = Thing()
    out = s.summarize(t, "full", set())
    assert out["t"] == "obj" and out["cls"].endswith("Thing") and out["id"] == 1
    assert set(out["fields"]) == {"a", "_b", "big"}
    assert s.summarize(t, "full", set())["id"] == 1  # stable alias
    assert s.summarize(Thing(), "full", set())["id"] == 2
    assert s.summarize(Slotted(), "full", set())["fields"]["q"]["v"] == 2
    # fields of fields are not expanded
    assert "fields" not in s.summarize([t], "full", set())["items"][0]
    e = s.summarize(Colour.RED, "full", set())
    assert e["fields"]["name"]["v"] == "RED"
    fn = s.summarize(summary.sha12, "full", set())
    assert fn == {"t": "fn", "name": "podtrace.summary.sha12"}
    assert s.summarize(Thing, "full", set())["t"] == "fn"
    assert s.summarize(pathlib.PurePosixPath("/a/b"), "full", set())["fields"]["v"]["v"] == "/a/b"


def test_alias_is_not_reused_for_a_new_object_at_the_same_address():
    a = Aliases()
    seen = []
    for _ in range(5):
        o = Thing()
        seen.append(a.alias(o))
        del o
    assert seen == [1, 2, 3, 4, 5]


def test_keys_detect_shallow_changes():
    s = make()
    lst = [1, 2]
    k1 = s.key(lst, "full")
    lst.append(3)
    assert s.key(lst, "full") != k1
    d = {"a": 1}
    kd = s.key(d, "full")
    d["a"] = 2
    assert s.key(d, "full") != kd
    assert s.key(1, "full") == s.key(1, "full") != s.key(2, "full")
    assert s.key(float("nan"), "full") == s.key(float("nan"), "full")
    assert s.from_key(k1, "full") == {"t": "list", "len": 2}


np = pytest.importorskip("numpy")


def ref_stats(a):
    x = a.astype("float64")
    fin = x[np.isfinite(x)]
    return {
        "mean": float(fin.mean()),
        "std": float(fin.std()),
        "absmean": float(np.abs(fin).mean()),
        "min": float(fin.min()),
        "max": float(fin.max()),
        "nan": int(np.isnan(x).sum()),
        "inf": int(np.isinf(x).sum()),
    }


def assert_stats(out, a):
    ref = ref_stats(a)
    for k, v in ref.items():
        assert out[k] == pytest.approx(v, rel=1e-9, abs=1e-12), k


def test_numpy_stats_match_numpy():
    rng = np.random.default_rng(0)
    a = rng.normal(size=(2, 3, 4, 5, 6)).astype("float32")
    a[0, 0, 0, 0, 0] = np.nan
    a[1, 1, 1, 1, 1] = np.inf
    out = S(a)
    assert out["t"] == "ndarray" and out["shape"] == [2, 3, 4, 5, 6] and out["dtype"] == "float32"
    assert "ver" not in out
    assert_stats(out, a)
    assert (out["nan"], out["inf"]) == (1, 1)
    assert len(out["fp"]) == 16


def test_levels():
    a = np.ones((3, 4, 5, 6, 7), dtype="float32")
    full, basic, shape = S(a), S(a, "basic"), S(a, "shape")
    assert {"profile", "fp"} <= set(full)
    assert "profile" not in basic and "fp" not in basic and "mean" in basic
    assert set(shape) == {"t", "id", "shape", "dtype", "device"}


def test_fingerprint_is_bit_exact():
    a = np.arange(24, dtype="float32").reshape(2, 3, 4)
    b = a.copy()
    assert S(a)["fp"] == S(b)["fp"]
    b[1, 2, 3] += 1e-6
    assert S(a)["fp"] != S(b)["fp"]
    c = a.copy()
    c[0, 0, 0], c[0, 0, 1] = c[0, 0, 1], c[0, 0, 0]  # same values, different order
    assert S(a)["fp"] != S(c)["fp"] and S(a)["mean"] == S(c)["mean"]
    assert S(a)["fp"] != S(a.reshape(4, 3, 2))["fp"]
    neg0 = np.array([0.0], dtype="float32")
    assert S(neg0)["fp"] != S(-neg0)["fp"]


def test_profile_axes_and_bins():
    a = np.zeros((1, 2, 6, 3, 3), dtype="float32")
    for t in range(6):
        a[:, :, t] = t + 1
    prof = S(a)["profile"]
    assert prof["axis"] == 2 and prof["edges"] == list(range(7))
    assert prof["absmean"] == pytest.approx([1, 2, 3, 4, 5, 6])
    tok = np.ones((2, 1000, 3), dtype="float32")
    tok[:, 500:] = 2
    p3 = S(tok)["profile"]
    assert p3["axis"] == 1 and len(p3["absmean"]) == 256 and len(p3["edges"]) == 257
    assert p3["edges"][0] == 0 and p3["edges"][-1] == 1000
    assert p3["absmean"][0] == pytest.approx(1) and p3["absmean"][-1] == pytest.approx(2)
    assert "profile" not in S(np.ones((4, 4), dtype="float32"))
    assert "profile" not in S(np.ones((2, 3, 4, 5), dtype="float32"))


def test_profile_is_only_in_the_first_summary_of_a_version_per_trace():
    s = make()
    a = np.arange(60, dtype="float32").reshape(1, 5, 12)
    seen: set = set()
    first = s.summarize(a, "full", seen)
    second = s.summarize(a, "full", seen)
    assert "profile" in first and "profile" not in second
    assert first["fp"] == second["fp"]
    assert "profile" in s.summarize(a, "full", set())  # another trace shows it again


def test_chunking_gives_identical_results(monkeypatch):
    rng = np.random.default_rng(1)
    a = rng.normal(size=(3, 7, 11, 5, 4)).astype("float32")
    whole = S(a)
    monkeypatch.setattr(tensors, "CHUNK", 37)
    pieces = S(a)
    assert pieces["fp"] == whole["fp"]
    for k in ("mean", "std", "absmean", "min", "max"):
        assert pieces[k] == pytest.approx(whole[k], rel=1e-12)
    assert pieces["profile"]["absmean"] == pytest.approx(whole["profile"]["absmean"], rel=1e-9)


def test_chunk_plan_tiles_exactly():
    for shape, limit in [
        ((5, 4, 3), 7),
        ((2, 100), 30),
        ((1, 1, 50), 8),
        ((6,), 4),
        ((3, 3, 3, 3), 10),
    ]:
        covered = np.zeros(shape, dtype=int)
        total = 1
        for d in shape:
            total *= d
        for starts, lens in tensors.chunk_plan(shape, limit):
            sl = tuple(slice(s, s + n) for s, n in zip(starts, lens, strict=True))
            covered[sl] += 1
            n = 1
            for x in lens:
                n *= x
            assert n <= max(limit, shape[-1])
            assert tensors._flat_offset(starts, shape) == int(np.ravel_multi_index(starts, shape))
        assert (covered == 1).all()


def test_integers_bools_empty_and_object_arrays():
    assert S(np.arange(5))["mean"] == 2.0
    assert S(np.array([True, False]))["mean"] == 0.5
    assert "mean" not in S(np.zeros((0, 3)))
    assert "mean" not in S(np.array(["a", "b"]))
    out = S(np.array([np.nan, np.inf]))
    assert out["mean"] is None and out["nan"] == 1 and out["inf"] == 1


def test_numpy_scalar_is_a_plain_number():
    assert S(np.float32(2.5)) == {"t": "float", "v": 2.5}
    assert S(np.int64(7)) == {"t": "int", "v": 7}


def test_plugin_edges_and_segments_are_used():
    class Layout:
        axis = 1
        edges = [0, 2, 6, 10]
        segments = [("text", 0, 2), ("video", 2, 10)]

    s = make()
    s.layout_for = lambda shape: Layout() if shape == (1, 10, 2) else None
    a = np.ones((1, 10, 2), dtype="float32")
    a[:, 2:] = 3
    out = s.summarize(a, "full", set())
    assert out["profile"]["edges"] == [0, 2, 6, 10]
    assert out["profile"]["absmean"] == pytest.approx([1, 3, 3])
    assert out["segments"] == pytest.approx({"text": 1.0, "video": 3.0})
    assert "segments" not in s.summarize(np.ones((1, 9, 2), dtype="float32"), "full", set())


def test_default_edges():
    assert tensors.default_edges(5, 256) == [0, 1, 2, 3, 4, 5]
    e = tensors.default_edges(1000, 256)
    assert len(e) == 257 and e[0] == 0 and e[-1] == 1000 and all(b > a for a, b in pairwise(e))
    assert math.isfinite(sum(e))


def test_sample_steps_thin_the_longest_dimensions_first():
    from podtrace.tensors import CPU_SAMPLE_TARGET, sample_steps

    shape = [736, 3, 1024, 576]
    steps = sample_steps(shape)
    assert steps[1] == 1  # the short channel dimension is kept whole
    kept = 1
    for size, step in zip(shape, steps, strict=True):
        kept *= -(-size // step)
    assert kept <= CPU_SAMPLE_TARGET
    assert sample_steps([4, 5]) == [1, 1]


def test_large_host_array_is_summarized_from_a_sample():
    np = __import__("pytest").importorskip("numpy")
    from types import SimpleNamespace

    from podtrace import tensors

    a = np.ones((1 << 13, 1 << 12), dtype=np.float32)  # 32 million elements
    a[::2] = 3.0
    out = tensors.summarize_numpy(a, "full", 1, SimpleNamespace(profile_bins=256), set(), None)
    assert out["shape"] == [1 << 13, 1 << 12]
    assert out["sampled"] != [1, 1]
    assert "profile" not in out
    assert out["min"] in (1.0, 3.0) and out["max"] in (1.0, 3.0)


@pytest.mark.parametrize("dtype", ["float32", "float16"])
def test_numpy_std_of_values_with_a_large_mean_keeps_precision(dtype):
    # float16 cannot hold 10001
    vals = [10000.0, 10001.0] if dtype == "float32" else [1000.0, 1001.0]
    out = S(np.array(vals, dtype=dtype))
    assert out["std"] == pytest.approx(0.5, abs=1e-6)
