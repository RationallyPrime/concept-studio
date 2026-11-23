import pytest

torch = pytest.importorskip("torch")
np = pytest.importorskip("numpy")

from podtrace import config, summary, tensors  # noqa: E402
from podtrace.summary import Aliases, Summarizer, TensorCache  # noqa: E402


def make(**top):
    return Summarizer(config.from_dict(top), Aliases(), TensorCache())


def S(value, level="full", s=None, seen=None):
    return (s or make()).summarize(value, level, seen if seen is not None else set())


def ref(t):
    x = t.detach().double()
    fin = x[torch.isfinite(x)]
    return {
        "mean": fin.mean().item(),
        "std": fin.std(unbiased=False).item(),
        "absmean": fin.abs().mean().item(),
        "min": fin.min().item(),
        "max": fin.max().item(),
        "nan": int(torch.isnan(x).sum()),
        "inf": int(torch.isinf(x).sum()),
    }


@pytest.mark.parametrize("dtype", [torch.float32, torch.bfloat16, torch.float16, torch.float64])
def test_stats_match_torch_for_float_dtypes(dtype):
    g = torch.Generator().manual_seed(0)
    t = torch.randn(2, 3, 5, 4, 3, generator=g).to(dtype)
    out = S(t)
    assert out["t"] == "tensor" and out["dtype"] == str(dtype).removeprefix("torch.")
    assert out["shape"] == [2, 3, 5, 4, 3] and out["device"] == "cpu" and out["ver"] == 0
    for k, v in ref(t).items():
        assert out[k] == pytest.approx(v, rel=1e-5, abs=1e-6), k
    assert len(out["fp"]) == 16 and out["profile"]["axis"] == 2


def test_nonfinite_values_are_counted_not_averaged():
    t = torch.tensor([1.0, float("nan"), float("inf"), -float("inf"), 3.0])
    out = S(t)
    assert (out["nan"], out["inf"]) == (1, 2)
    assert out["mean"] == 2.0 and out["min"] == 1.0 and out["max"] == 3.0
    allbad = S(torch.tensor([float("nan")]))
    assert allbad["mean"] is None and allbad["nan"] == 1


def test_integer_bool_and_non_contiguous():
    assert S(torch.arange(10))["mean"] == 4.5
    assert S(torch.tensor([True, False, True, True]))["mean"] == 0.75
    base = torch.arange(60, dtype=torch.float32).reshape(3, 4, 5)
    view = base.permute(2, 0, 1)
    assert not view.is_contiguous()
    out = S(view)
    assert out["mean"] == pytest.approx(view.mean().item())
    assert out["fp"] == S(view.contiguous())["fp"]


def test_fingerprint_is_bit_exact_and_device_independent_of_chunking(monkeypatch):
    g = torch.Generator().manual_seed(2)
    t = torch.randn(3, 7, 9, 5, 4, generator=g)
    whole = S(t)
    monkeypatch.setattr(tensors, "CHUNK", 101)
    chunked = S(t)
    monkeypatch.undo()
    assert chunked["fp"] == whole["fp"]
    assert chunked["profile"]["absmean"] == pytest.approx(whole["profile"]["absmean"], rel=1e-9)
    t2 = t.clone()
    t2[1, 2, 3, 4, 3] = t2[1, 2, 3, 4, 3] + 1e-7
    assert S(t2)["fp"] != whole["fp"]
    bf = t.to(torch.bfloat16)
    assert S(bf)["fp"] == S(bf.clone())["fp"] != S(bf.float())["fp"]


def test_version_counter_and_cache_one_reduction_per_version(monkeypatch):
    calls = []
    real = tensors._torch_body
    monkeypatch.setattr(tensors, "_torch_body", lambda *a, **k: calls.append(1) or real(*a, **k))
    s = make()
    t = torch.ones(2, 3, 4)
    seen: set = set()
    first = s.summarize(t, "full", seen)
    for _ in range(5):
        again = s.summarize(t, "full", seen)
        assert again["fp"] == first["fp"] and again["ver"] == first["ver"]
    assert len(calls) == 1
    t.add_(1)
    after = s.summarize(t, "full", seen)
    assert after["ver"] == first["ver"] + 1 and after["id"] == first["id"] and len(calls) == 2
    assert after["fp"] != first["fp"] and after["mean"] == 2.0
    # a basic request is served from the full entry; a full request after basic recomputes
    s2 = make()
    s2.summarize(t, "basic", set())
    n = len(calls)
    s2.summarize(t, "full", set())
    assert len(calls) == n + 1  # the cached basic entry does not satisfy a full request


def test_inference_tensors_are_not_trusted_blindly():
    s = make(inference_check="full")
    with torch.inference_mode():
        t = torch.ones(4, 4)
    a = s.summarize(t, "full", set())
    assert a["inference"] is True and a["ver"] == 0
    with torch.inference_mode():
        t.mul_(3)
    b = s.summarize(t, "full", set())
    assert b["mean"] == 3.0 and b["fp"] != a["fp"] and b["id"] == a["id"]


def test_inference_probe_notices_a_large_in_place_write(monkeypatch):
    monkeypatch.setattr(tensors, "PROBE_MIN", 100)
    s = make(inference_check="probe")
    with torch.inference_mode():
        t = torch.zeros(64, 64)
    a = s.summarize(t, "full", set())
    again = s.summarize(t, "full", set())
    assert again["fp"] == a["fp"]
    with torch.inference_mode():
        t.fill_(2.0)
    b = s.summarize(t, "full", set())
    assert b["mean"] == 2.0 and b["fp"] != a["fp"]


def test_the_probe_caches_its_indices_in_host_memory_by_element_count(monkeypatch):
    monkeypatch.setattr(tensors, "_probe_idx", {})
    t = torch.arange(5000, dtype=torch.float32)
    first = tensors.torch_probe(t)
    assert tensors.torch_probe(t.clone()) == first
    assert list(tensors._probe_idx) == [5000]
    idx = tensors._probe_idx[5000]
    assert idx.device.type == "cpu" and idx.numel() == tensors.PROBE_SAMPLES
    u = t.clone()
    u[int(idx[0])] += 1.0
    assert tensors.torch_probe(u) != first


def test_shape_only_cases():
    s = make()
    assert "mean" not in s.summarize(torch.zeros(3, device="meta"), "full", set())
    assert "mean" not in s.summarize(torch.zeros(0), "full", set())
    assert "mean" not in s.summarize(torch.zeros(2, dtype=torch.complex64), "full", set())
    sparse = torch.eye(3).to_sparse()
    assert s.summarize(sparse, "full", set())["shape"] == [3, 3]
    assert "mean" not in s.summarize(torch.ones(3), "shape", set())


def test_parameters_and_modules():
    lin = torch.nn.Linear(3, 2)
    lin.note = "hi"
    lin.scale = 2.0
    s = make()
    out = s.summarize(lin, "full", set())
    assert out["t"] == "obj" and out["cls"] == "torch.nn.modules.linear.Linear"
    assert set(out["fields"]) >= {"in_features", "out_features", "note", "scale"}
    assert not any(k.startswith("_") for k in out["fields"])  # no walk into parameters
    p = s.summarize(lin.weight, "full", set())
    assert p["t"] == "tensor" and p["shape"] == [2, 3]


def test_summaries_do_not_change_the_tensor_or_autograd_state():
    t = torch.randn(4, 5, requires_grad=True)
    v = t._version
    S(t)
    assert t._version == v and t.grad is None and t.requires_grad
    assert torch.is_grad_enabled()


def test_3d_profile_with_plugin_layout_and_segments():
    class Layout:
        axis = 1
        edges = [0, 3, 5, 9]
        segments = [("text", 0, 3), ("video", 5, 9)]

    s = make()
    s.layout_for = lambda shape: Layout() if shape[1] == 9 else None
    t = torch.ones(1, 9, 4)
    t[:, 5:] = 4
    out = s.summarize(t, "full", set())
    assert out["profile"]["edges"] == [0, 3, 5, 9]
    assert out["profile"]["absmean"] == pytest.approx([1, 1, 4])
    assert out["segments"] == pytest.approx({"text": 1.0, "video": 4.0})


class PackedLayout:  # the plugin goes by the class name
    def __init__(self, text, frames, rows_per_frame, audio):
        video = frames * rows_per_frame
        self.seq_len = text + audio + video
        self.segments = [
            (0, text, "text"),
            (text, text + audio, "audio"),
            (text + audio, self.seq_len, "video"),
        ]
        self.signature = (text, frames, 2, 2 * rows_per_frame, audio)


def test_the_h3_stream_without_a_batch_axis_gets_a_profile_per_latent_frame():
    from podtrace.plugins import minimax_h3

    minimax_h3.reset()
    try:
        layout = PackedLayout(text=3, frames=4, rows_per_frame=5, audio=2)
        assert minimax_h3._on_init(layout, "PackedLayout")["layout"]["seq_len"] == 25
        s = make()
        s.layout_for = minimax_h3._layout_for
        t = torch.ones(25, 6)
        t[5 + 2 * 5 : 5 + 3 * 5] = 7  # the third latent frame
        out = s.summarize(t, "full", set())
        assert out["profile"]["axis"] == 0
        assert out["profile"]["edges"] == [0, 3, 5, 10, 15, 20, 25]
        assert out["profile"]["absmean"] == pytest.approx([1, 1, 1, 1, 7, 1])
        assert out["segments"] == pytest.approx({"text": 1.0, "audio": 1.0, "video": 2.5})
        # the batched form still works, along its own axis
        assert s.summarize(t[None].clone(), "full", set())["profile"]["axis"] == 1
        # a tensor that only happens to be two-dimensional gets nothing
        assert "profile" not in s.summarize(torch.ones(24, 6), "full", set())
    finally:
        minimax_h3.reset()


def test_a_huge_accelerator_tensor_is_sampled_with_its_profile_axis_whole(monkeypatch):
    from podtrace.plugins import minimax_h3

    monkeypatch.setattr(tensors, "_on_accelerator", lambda device_type: True)
    monkeypatch.setattr(tensors, "GPU_SAMPLE_ABOVE", 1 << 10)
    monkeypatch.setattr(tensors, "GPU_SAMPLE_TARGET", 1 << 9)
    minimax_h3.reset()
    try:
        layout = PackedLayout(text=3, frames=4, rows_per_frame=5, audio=2)
        minimax_h3._on_init(layout, "PackedLayout")
        s = make()
        s.layout_for = minimax_h3._layout_for
        t = torch.ones(25, 256)
        t[5 + 2 * 5 : 5 + 3 * 5] = 7
        out = s.summarize(t, "full", set())
        assert out["sampled"][0] == 1 and out["sampled"][1] > 1  # channels thinned, every row kept
        assert out["profile"]["absmean"] == pytest.approx([1, 1, 1, 1, 7, 1])
        assert out["segments"]["video"] == pytest.approx(2.5)
        # a latent keeps its frame axis and loses pixels
        lat = s.summarize(torch.ones(1, 4, 6, 16, 16), "full", set())
        assert lat["sampled"][2] == 1 and len(lat["profile"]["absmean"]) == 6
        # the same tensor twice gives the same summary
        assert s.summarize(t.clone(), "full", set())["fp"] == out["fp"]
    finally:
        minimax_h3.reset()


def test_large_tensor_is_reduced_in_bounded_temporaries(monkeypatch):
    # A small CHUNK stands in for a huge tensor: peak temporaries are a function of CHUNK only.
    monkeypatch.setattr(tensors, "CHUNK", 1 << 10)
    t = torch.randn(1, 4, 64, 32, 32)
    out = S(t)
    assert out["mean"] == pytest.approx(t.double().mean().item(), abs=1e-6)
    assert max(len(list(tensors.chunk_plan(tuple(t.shape), 1 << 10))), 1) > 100


def test_torch_no_grad_decorator_stacking_and_wrapper_signature(tmp_path):
    from conftest import Harness

    from podtrace import hook, registry, runtime

    h = Harness(tmp_path)
    try:
        h.start()
        m = h.module(
            """
            import torch
            class N:
                @torch.no_grad()
                def f(self, x):
                    return x * 2
                @torch.no_grad()
                def gen(self, n):
                    for i in range(n):
                        yield torch.is_grad_enabled(), i
            @torch.no_grad()
            def g(x): return x + 1
            """
        )
        x = torch.ones(2, requires_grad=True)
        assert not m.N().f(x).requires_grad and not m.g(x).requires_grad
        assert list(m.N().gen(2)) == [(False, 0), (False, 1)]
        names = {r["name"].rsplit(".", 1)[-1] for r in h.records()}
        assert {"f", "g", "gen"} <= names
        rec = h.by_name(".g")[0]
        assert rec["args"]["x"]["t"] == "tensor" and rec["ret"]["t"] == "tensor"
        assert torch.is_grad_enabled()
    finally:
        runtime.shutdown()
        runtime._reset()
        hook.uninstall()
        registry.TABLES.clear()


def test_in_place_write_to_an_argument_is_a_state_entry(tmp_path):
    from conftest import Harness

    from podtrace import hook, registry, runtime

    h = Harness(tmp_path)
    try:
        h.start()
        m = h.module(
            """
            def write(x, y):
                x[0] = 5
                return y + 1
            def inner(x): x.add_(1)
            def outer(x):
                inner(x)
            """
        )
        x, y = torch.zeros(4), torch.zeros(4)
        m.write(x, y)
        (r,) = h.by_name(".write")
        (entry,) = r["state"]
        assert entry["target"] == "arg:x" and entry["attr"] == ""
        assert (
            entry["before"]["ver"] + 1 == entry["after"]["ver"]
            and entry["before"]["id"] == entry["after"]["id"]
        )
        assert entry["after"]["mean"] == pytest.approx(1.25)
        m.outer(torch.zeros(3))
        inner, outer = h.by_name(".inner")[0], h.by_name(".outer")[0]
        assert inner["state"] and outer["state"]
        with torch.inference_mode():
            z = torch.zeros(5)
        with torch.inference_mode():
            m.inner(z)
        last = h.by_name(".inner")[-1]
        assert last["state"] and last["state"][0]["after"]["mean"] == 1.0
    finally:
        runtime.shutdown()
        runtime._reset()
        hook.uninstall()
        registry.TABLES.clear()


def test_summary_helper_names_exist():
    assert summary.Summarizer and tensors.summarize_torch


@pytest.mark.parametrize("dtype", [torch.float32, torch.float16, torch.bfloat16])
def test_std_of_values_with_a_large_mean_keeps_precision(dtype):
    # float16 and bfloat16 cannot hold 10001, so use values each can represent exactly
    vals = {
        torch.float32: [10000.0, 10001.0],
        torch.float16: [1000.0, 1001.0],
        torch.bfloat16: [10240.0, 10368.0],
    }[dtype]
    t = torch.tensor(vals, dtype=dtype)
    expected = (vals[1] - vals[0]) / 2
    assert S(t)["std"] == pytest.approx(expected, rel=1e-6)
