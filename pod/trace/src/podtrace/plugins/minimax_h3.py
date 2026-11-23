"""Packed-token layout of the MiniMax H3 transformer.

Every ``PackedLayout`` construction is observed (its ``__init__`` is a traced call). The layout is
a sequence of segments: text, keyframe conditioning (``cond``, ``cond_audio``), references
(``ref_img``, ``ref_audio``), target ``audio`` and target ``video`` last. A tensor
``[batch, tokens, channels]`` or ``[tokens, channels]`` whose token axis has the length of a known
layout gets a profile
with an edge at every segment boundary and, inside the video segment, one per latent frame
(``latent_h/2 x latent_w/2`` rows each), plus the mean absolute value per named segment.

Only layouts built while recording is on are known; a layout built earlier is not seen.
"""

from __future__ import annotations

from collections import OrderedDict
from dataclasses import dataclass, replace
from typing import Any

_MAX_LAYOUTS = 64
_MAX_EDGES = 4096


@dataclass
class TokenLayout:
    seq_len: int
    axis: int
    edges: list[int]
    segments: list[tuple[str, int, int]]
    signature: tuple[int, ...]
    raw: list[tuple[int, int, str]]


_layouts: OrderedDict[int, TokenLayout] = OrderedDict()


def _build(obj: Any) -> TokenLayout | None:
    seq_len = int(obj.seq_len)
    raw = [(int(a), int(b), str(kind)) for a, b, kind in obj.segments]
    signature = tuple(int(x) for x in getattr(obj, "signature", ()))
    edges = {0, seq_len}
    names: list[tuple[str, int, int]] = []
    count: dict[str, int] = {}
    for start, stop, kind in raw:
        count[kind] = count.get(kind, 0) + 1
        names.append((kind if count[kind] == 1 else f"{kind}#{count[kind]}", start, stop))
        edges.update((start, stop))
        if kind == "video" and len(signature) >= 2 and signature[1] > 0:
            frames = signature[1]
            rows = (stop - start) // frames
            if rows > 0 and rows * frames == stop - start:
                edges.update(start + k * rows for k in range(frames + 1))
    ordered = sorted(e for e in edges if 0 <= e <= seq_len)
    if len(ordered) > _MAX_EDGES or len(ordered) < 2:
        ordered = sorted({0, seq_len, *(e for _, a, b in names for e in (a, b))})
    return TokenLayout(seq_len, 1, ordered, names, signature, raw)


def _on_init(obj: Any, name: str) -> dict[str, Any] | None:
    if type(obj).__name__ != "PackedLayout":
        return None
    layout = _build(obj)
    if layout is None:
        return None
    _layouts[layout.seq_len] = layout
    _layouts.move_to_end(layout.seq_len)
    while len(_layouts) > _MAX_LAYOUTS:
        _layouts.popitem(last=False)
    return {
        "layout": {
            "seq_len": layout.seq_len,
            "signature": list(layout.signature),
            "segments": [[a, b, kind] for a, b, kind in layout.raw],
        }
    }


def _layout_for(shape: tuple[int, ...]) -> TokenLayout | None:
    """The layout of a packed token tensor: ``[batch, tokens, channels]`` or ``[tokens, channels]``.

    The H3 transformer carries its stream without a batch axis, so the two-dimensional form is the
    one its blocks and the control network see.
    """
    if len(shape) == 3:
        return _layouts.get(shape[1])
    if len(shape) == 2:
        layout = _layouts.get(shape[0])
        if layout is not None:
            return replace(layout, axis=0)
    return None


def install(rt: Any) -> None:
    rt.add_init_hook(_on_init)
    rt.add_layout_provider(_layout_for)


def reset() -> None:
    _layouts.clear()
