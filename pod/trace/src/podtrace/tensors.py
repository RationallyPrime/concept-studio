"""Numeric summaries of tensors and arrays.

Everything here is duck-typed: ``torch`` and ``numpy`` are only used when the traced program has
already imported them (``sys.modules``), and nothing is ever written to the inspected object.

Large tensors are reduced in chunks of at most ``CHUNK`` elements, so the temporaries stay
bounded (a few hundred megabytes) whatever the tensor size. On a device, every chunk adds into
small accumulators that live on the device, and a single transfer at the end brings all scalars
(statistics, fingerprint parts and the profile) to the host: one synchronisation per summarized
tensor.

Host memory is the exception. A decoded video held on the CPU can be several gigabytes, and
reducing all of it costs minutes per summary. A CPU tensor or array above ``CPU_SAMPLE_ABOVE``
elements is therefore summarized from a strided view of about ``CPU_SAMPLE_TARGET`` elements, and
the summary says so in ``sampled`` (the step taken along each dimension).
"""

from __future__ import annotations

import sys
import zlib
from collections.abc import Iterator
from itertools import pairwise
from math import isfinite
from typing import Any

CHUNK = 1 << 24  # elements per chunk: 64 MB as float32, 128 MB as int64
CPU_SAMPLE_ABOVE = 1 << 24  # host tensors above this many elements are sampled, not fully read
CPU_SAMPLE_TARGET = 1 << 22
# Tensors on an accelerator above this many elements are summarized from a strided view that keeps
# the profiled axis whole (a transformer's token stream at video sizes is a billion elements, and
# full statistics of every such tensor in every call multiply the run time).
GPU_SAMPLE_ABOVE = 1 << 26
GPU_SAMPLE_TARGET = 1 << 25
PROBE_MIN = 1 << 20  # inference tensors above this are validated by a sampled fingerprint
PROBE_SAMPLES = 4096
MASK64 = (1 << 64) - 1
_K1 = 0x9E3779B97F4A7C15
_K2 = 0xC2B2AE3D27D4EB4F
_K3 = 0x165667B19E3779F9


def _signed(x: int) -> int:
    x &= MASK64
    return x - (1 << 64) if x >= (1 << 63) else x


SK1, SK2, SK3 = _signed(_K1), _signed(_K2), _signed(_K3)

PROFILE_AXIS = {5: 2, 3: 1}


# ----------------------------------------------------------------------------- chunk planning


def _prod(xs: tuple[int, ...] | list[int]) -> int:
    n = 1
    for x in xs:
        n *= x
    return n


def chunk_plan(
    shape: tuple[int, ...], limit: int = CHUNK
) -> Iterator[tuple[tuple[int, ...], tuple[int, ...]]]:
    """Yield ``(starts, lens)`` boxes that tile ``shape``.

    Every box holds at most ``limit`` elements (or a single row of the last dimension) and is a
    contiguous range of the row-major order, so its flat offset is a plain dot product.
    """
    nd = len(shape)
    if nd == 0 or _prod(shape) <= limit:
        yield (0,) * nd, tuple(shape)
        return

    def rec(d: int, starts: tuple[int, ...], lens: tuple[int, ...]):
        inner = _prod(shape[d + 1 :])
        if inner > limit and d < nd - 1:
            for i in range(shape[d]):
                yield from rec(d + 1, (*starts, i), (*lens, 1))
            return
        step = max(1, limit // max(inner, 1))
        for s in range(0, shape[d], step):
            yield (
                (*starts, s, *([0] * (nd - d - 1))),
                (*lens, min(step, shape[d] - s), *shape[d + 1 :]),
            )

    yield from rec(0, (), ())


def _flat_offset(starts: tuple[int, ...], shape: tuple[int, ...]) -> int:
    off, stride = 0, 1
    for k in range(len(shape) - 1, -1, -1):
        off += starts[k] * stride
        stride *= shape[k]
    return off


def sample_steps(
    shape: tuple[int, ...] | list[int], target: int = CPU_SAMPLE_TARGET, keep: int | None = None
) -> list[int]:
    """Step per dimension so that the strided view holds about ``target`` elements or fewer.

    The longest dimensions are thinned first, so a batch of frames loses frames before it loses
    pixels. ``keep`` names a dimension that is thinned last, and only if the others alone cannot
    reach the target: the axis a profile runs along. The view starts at index 0 of every dimension
    and is the same for the same shape.
    """
    steps = [1] * len(shape)
    sizes = [int(d) for d in shape]
    for d in sorted(range(len(sizes)), key=lambda i: (i == keep, -sizes[i])):
        total = _prod(sizes)
        if total <= target:
            break
        step = min(sizes[d], -(-total // target))
        steps[d] = step
        sizes[d] = -(-sizes[d] // step)
    return steps


def default_edges(length: int, bins: int) -> list[int]:
    if length <= bins:
        return list(range(length + 1))
    return [round(i * length / bins) for i in range(bins + 1)]


def bin_profile(sums: list[float], per_index: int, edges: list[int]) -> list[float]:
    """Mean absolute value per bin from per-index sums of the absolute values."""
    prefix = [0.0]
    for s in sums:
        prefix.append(prefix[-1] + s)
    out = []
    for a, b in pairwise(edges):
        width = max(b - a, 1) * max(per_index, 1)
        out.append((prefix[b] - prefix[a]) / width)
    return out


def _clean(x: float) -> float | None:
    return float(x) if isfinite(x) else None


def _fp_hex(parts: tuple[int, int], shape: list[int], dtype: str) -> str:
    h1, h2 = parts
    tag = zlib.crc32(f"{shape}|{dtype}".encode()) * 0x100000001B3
    return f"{(h1 ^ ((h2 * _K1) & MASK64) ^ tag) & MASK64:016x}"


def _finish_stats(
    out: dict[str, Any],
    acc: list[float],
    numel: int,
    fp: tuple[int, int] | None,
    shape: list[int],
    dtype: str,
) -> None:
    n_fin, total, sumsq, abssum, mn, mx, n_nan = acc[:7]
    if n_fin > 0:
        mean = total / n_fin
        var = max(sumsq / n_fin - mean * mean, 0.0)
        out["mean"] = _clean(mean)
        out["std"] = _clean(var**0.5)
        out["absmean"] = _clean(abssum / n_fin)
        out["min"] = _clean(mn)
        out["max"] = _clean(mx)
    else:
        for key in ("mean", "std", "absmean", "min", "max"):
            out[key] = None
    out["nan"] = int(n_nan)
    out["inf"] = int(numel - n_fin - n_nan)
    if fp is not None:
        out["fp"] = _fp_hex(fp, shape, dtype)


# ----------------------------------------------------------------------------- torch


def torch_module() -> Any:
    return sys.modules.get("torch")


def is_torch_tensor(v: object) -> bool:
    torch = sys.modules.get("torch")
    if torch is None:
        return False
    tensor_cls = getattr(torch, "Tensor", None)
    return tensor_cls is not None and isinstance(v, tensor_cls)


def _torch_bits(torch: Any, c: Any) -> Any:
    dt = c.dtype
    if dt.is_floating_point:
        size = c.element_size()
        target = {1: torch.int8, 2: torch.int16, 4: torch.int32, 8: torch.int64}[size]
        return c.view(target)
    return c


_probe_idx: dict[int, Any] = {}


def torch_probe(t: Any) -> int:
    """Cheap fingerprint of ``PROBE_SAMPLES`` scattered elements of a contiguous tensor.

    The cached index tensors stay in host memory and are copied to the tensor's device for each
    probe. The tracer keeps no tensor on an accelerator beyond the call that made it: a host that
    plans its allocations (ComfyUI's model compiler) aborts the process when such a tensor is
    freed later, outside the allocation scope it was made in.
    """
    torch = sys.modules["torch"]
    n = t.numel()
    idx = _probe_idx.get(n)
    if idx is None:
        if len(_probe_idx) > 64:
            _probe_idx.clear()
        base = torch.arange(PROBE_SAMPLES, dtype=torch.int64)
        idx = (base * 2654435761 + 12345) % n
        _probe_idx[n] = idx
    with torch.no_grad():
        at = idx.to(t.device)
        sample = t.reshape(-1)[at]
        bits = _torch_bits(torch, sample).to(torch.int64)
        h = (bits ^ (at * SK1)) * SK2
        h = h ^ (h >> 29)
        return int(h.sum().item()) & MASK64


def _on_accelerator(device_type: str) -> bool:
    return device_type != "cpu"


def summarize_torch(
    t: Any,
    level: str,
    alias: int,
    cfg: Any,
    cache: Any,
    profile_seen: set[Any],
    layout_for: Any,
) -> dict[str, Any]:
    """Summary of one torch tensor. ``cache`` maps ``(alias, key)`` to a computed body."""
    torch = sys.modules["torch"]
    shape = [int(d) for d in t.shape]
    dtype = str(t.dtype).removeprefix("torch.")
    inference = False
    try:
        inference = bool(t.is_inference())
        ver = 0 if inference else int(t._version)
    except Exception:
        ver = 0
    out: dict[str, Any] = {
        "t": "tensor",
        "id": alias,
        "ver": ver,
        "shape": shape,
        "dtype": dtype,
        "device": str(t.device),
    }
    if inference:
        out["inference"] = True
    if level == "shape":
        return out
    plain = type(t) in (torch.Tensor, getattr(torch.nn, "Parameter", torch.Tensor))
    numel = _prod(shape)
    if (
        not plain
        or numel == 0
        or t.device.type == "meta"
        or t.layout != torch.strided
        or t.is_complex()
        or getattr(t, "is_quantized", False)
    ):
        return out

    want_full = level == "full"
    key: Any
    if not inference:
        key = ("v", ver)
    elif cfg.inference_check == "trust":
        key = ("i", 0)
    elif cfg.inference_check == "probe" and numel > PROBE_MIN and t.is_contiguous():
        key = ("p", torch_probe(t))
    else:
        key = None
    hit = cache.get((alias, key)) if key is not None else None
    if hit is not None and (hit[0] or not want_full):
        body = hit[1]
    else:
        if t.device.type == "cpu" and numel > CPU_SAMPLE_ABOVE:
            steps = sample_steps(shape)
            view = t[tuple(slice(None, None, k) for k in steps)]
            vshape = [int(d) for d in view.shape]
            body = _torch_body(
                view, torch, vshape, dtype, _prod(vshape), want_full, cfg, None, profile=False
            )
            body["sampled"] = steps
        elif _on_accelerator(t.device.type) and numel > GPU_SAMPLE_ABOVE:
            layout = layout_for(tuple(shape)) if (want_full and layout_for is not None) else None
            nd = len(shape)
            keep = layout.axis if layout is not None else PROFILE_AXIS.get(nd)
            steps = sample_steps(shape, GPU_SAMPLE_TARGET, keep=keep)
            view = t[tuple(slice(None, None, k) for k in steps)]
            vshape = [int(d) for d in view.shape]
            whole = keep is not None and steps[keep] == 1
            body = _torch_body(
                view,
                torch,
                vshape,
                dtype,
                _prod(vshape),
                want_full,
                cfg,
                layout_for if whole else None,
                profile=whole,
            )
            body["sampled"] = steps
        else:
            body = _torch_body(t, torch, shape, dtype, numel, want_full, cfg, layout_for)
        if key is not None:
            cache.put((alias, key), (want_full, body))
    sk = (alias, key) if key is not None else (alias, "fp", body.get("fp"))
    return _compose(out, body, want_full, sk, profile_seen)


def _compose(
    head: dict[str, Any], body: dict[str, Any], want_full: bool, seen_key: Any, seen: set[Any]
) -> dict[str, Any]:
    out = dict(head)
    for k, v in body.items():
        if k in ("fp", "profile", "segments") and not want_full:
            continue
        if k == "profile":
            if seen_key in seen:
                continue
            seen.add(seen_key)
        out[k] = v
    return out


def _torch_body(
    t: Any,
    torch: Any,
    shape: list[int],
    dtype: str,
    numel: int,
    want_full: bool,
    cfg: Any,
    layout_for: Any,
    profile: bool = True,
) -> dict[str, Any]:
    f64, i64 = torch.float64, torch.int64
    dev = t.device
    nd = len(shape)
    shp = tuple(shape)
    layout = layout_for(shp) if (want_full and layout_for is not None) else None
    axis = None
    if want_full and profile and nd in PROFILE_AXIS and shape[PROFILE_AXIS[nd]] > 1:
        axis = PROFILE_AXIS[nd]
    if layout is not None:
        axis = layout.axis
    alen = shape[axis] if axis is not None else 0
    with torch.no_grad():
        acc = torch.zeros(7, dtype=f64, device=dev)
        acc[4] = float("inf")
        acc[5] = float("-inf")
        fpacc = torch.zeros(2, dtype=i64, device=dev)
        prof = torch.zeros(max(alen, 1), dtype=f64, device=dev)
        dims = [d for d in range(nd) if d != axis] if axis is not None else []
        for starts, lens in chunk_plan(shp, CHUNK):
            sl = tuple(slice(s, s + n) for s, n in zip(starts, lens, strict=True))
            c = t[sl] if nd else t
            xf = c if c.dtype == f64 else c.to(torch.float32)
            fin = torch.isfinite(xf)
            z = torch.nan_to_num(xf, nan=0.0, posinf=0.0, neginf=0.0)
            acc[0].add_(fin.sum())
            acc[1].add_(z.sum(dtype=f64))
            zd = z if z.dtype == f64 else z.to(f64)  # squares in float64, or large means cancel
            acc[2].add_((zd * zd).sum())
            za = z.abs()
            acc[3].add_(za.sum(dtype=f64))
            acc[4] = torch.minimum(acc[4], xf.masked_fill(~fin, float("inf")).min().to(f64))
            acc[5] = torch.maximum(acc[5], xf.masked_fill(~fin, float("-inf")).max().to(f64))
            acc[6].add_(torch.isnan(xf).sum())
            if axis is not None:
                part = za.sum(dim=dims, dtype=f64) if dims else za.to(f64)
                a0 = starts[axis]
                prof[a0 : a0 + lens[axis]].add_(part)
            if want_full:
                v = _torch_bits(torch, c).reshape(-1).to(i64)
                off = _flat_offset(starts, shp)
                idx = torch.arange(off, off + v.numel(), dtype=i64, device=dev)
                h1 = (v ^ (idx * SK1)) * SK2
                h1 = h1 ^ (h1 >> 29)
                h2 = v * SK3 + idx
                h2 = h2 ^ (h2 >> 31)
                fpacc[0].add_(h1.sum())
                fpacc[1].add_(h2.sum())
        parts = [acc]
        if want_full:
            hi = (fpacc >> 32) & 0xFFFFFFFF
            lo = fpacc & 0xFFFFFFFF
            parts.append(torch.stack([hi[0], lo[0], hi[1], lo[1]]).to(f64))
        if axis is not None:
            parts.append(prof)
        flat = torch.cat(parts).tolist()
    return _assemble(flat, shape, dtype, numel, want_full, axis, alen, layout, cfg)


def _assemble(
    flat: list[float],
    shape: list[int],
    dtype: str,
    numel: int,
    want_full: bool,
    axis: int | None,
    alen: int,
    layout: Any,
    cfg: Any,
) -> dict[str, Any]:
    acc = flat[:7]
    pos = 7
    fp = None
    if want_full:
        hi1, lo1, hi2, lo2 = (int(x) for x in flat[7:11])
        fp = ((hi1 << 32) | lo1, (hi2 << 32) | lo2)
        pos = 11
    body: dict[str, Any] = {}
    _finish_stats(body, acc, numel, fp, shape, dtype)
    if axis is not None:
        sums = flat[pos : pos + alen]
        per_index = numel // alen if alen else 1
        edges = layout.edges if layout is not None else default_edges(alen, cfg.profile_bins)
        body["profile"] = {
            "axis": axis,
            "edges": edges,
            "absmean": bin_profile(sums, per_index, edges),
        }
        if layout is not None:
            segs = {}
            for name, a, b in layout.segments:
                if b > a:
                    segs[name] = sum(sums[a:b]) / ((b - a) * max(per_index, 1))
            body["segments"] = segs
    return body


# ----------------------------------------------------------------------------- numpy


def numpy_module() -> Any:
    return sys.modules.get("numpy")


def is_numpy_array(v: object) -> bool:
    np = sys.modules.get("numpy")
    return np is not None and isinstance(v, np.ndarray)


def summarize_numpy(
    a: Any, level: str, alias: int, cfg: Any, profile_seen: set[Any], layout_for: Any
) -> dict[str, Any]:
    np = sys.modules["numpy"]
    shape = [int(d) for d in a.shape]
    dtype = str(a.dtype)
    out: dict[str, Any] = {
        "t": "ndarray",
        "id": alias,
        "shape": shape,
        "dtype": dtype,
        "device": "cpu",
    }
    if level == "shape" or a.dtype.kind not in "biuf" or a.size == 0:
        return out
    want_full = level == "full"
    steps = None
    if a.size > CPU_SAMPLE_ABOVE:
        steps = sample_steps(shape)
        a = a[tuple(slice(None, None, k) for k in steps)]
        shape = [int(d) for d in a.shape]
    nd = len(shape)
    shp = tuple(shape)
    layout = layout_for(shp) if (want_full and steps is None and layout_for is not None) else None
    axis = None
    if want_full and steps is None and nd in PROFILE_AXIS and shape[PROFILE_AXIS[nd]] > 1:
        axis = PROFILE_AXIS[nd]
    if layout is not None:
        axis = layout.axis
    alen = shape[axis] if axis is not None else 0
    acc = [0.0, 0.0, 0.0, 0.0, float("inf"), float("-inf"), 0.0]
    prof = np.zeros(max(alen, 1), dtype=np.float64)
    h1 = h2 = np.uint64(0)
    dims = tuple(d for d in range(nd) if d != axis) if axis is not None else ()
    with np.errstate(all="ignore"):
        for starts, lens in chunk_plan(shp, CHUNK):
            sl = tuple(slice(s, s + n) for s, n in zip(starts, lens, strict=True))
            c = a[sl] if nd else a
            xf = c.astype(np.float64)
            fin = np.isfinite(xf)
            z = np.where(fin, xf, 0.0)
            za = np.abs(z)
            acc[0] += float(fin.sum())
            acc[1] += float(z.sum())
            acc[2] += float((z * z).sum())
            acc[3] += float(za.sum())
            if fin.any():
                acc[4] = min(acc[4], float(xf[fin].min()))
                acc[5] = max(acc[5], float(xf[fin].max()))
            acc[6] += float(np.isnan(xf).sum())
            if axis is not None:
                part = za.sum(axis=dims) if dims else za
                a0 = starts[axis]
                prof[a0 : a0 + lens[axis]] += part
            if want_full:
                flat = np.ascontiguousarray(c).reshape(-1)
                if flat.dtype.kind == "f":
                    flat = flat.view(np.dtype(f"u{flat.dtype.itemsize}"))
                v = flat.astype(np.uint64)
                off = _flat_offset(starts, shp)
                idx = np.arange(off, off + v.size, dtype=np.uint64)
                x1 = (v ^ (idx * np.uint64(_K1))) * np.uint64(_K2)
                x1 = x1 ^ (x1 >> np.uint64(29))
                x2 = v * np.uint64(_K3) + idx
                x2 = x2 ^ (x2 >> np.uint64(31))
                h1 = np.uint64(h1 + x1.sum(dtype=np.uint64))
                h2 = np.uint64(h2 + x2.sum(dtype=np.uint64))
    flat_out = list(acc)
    if want_full:
        for h in (h1, h2):
            hv = int(h)
            flat_out += [float(hv >> 32), float(hv & 0xFFFFFFFF)]
    if axis is not None:
        flat_out += prof.tolist()
    body = _assemble(flat_out, shape, dtype, a.size, want_full, axis, alen, layout, cfg)
    out.update(body)
    if steps is not None:
        out["sampled"] = steps
    if "profile" in out:
        k = (alias, "nd", out.get("fp"))
        if k in profile_seen:
            del out["profile"]
        else:
            profile_seen.add(k)
    return out
