# podtrace record schema (version 1)

`podtrace` writes one JSON object per line to `records.jsonl` in a run directory, and sends the
same information to Logfire as OpenTelemetry spans. This file is the contract between the
recorder (`podtrace.runtime` and its sinks) and the comparison tool (`podtrace.compare`).

A record is written when its span **ends**, so children appear before their parent in the file.
Readers rebuild the tree from `parent_id` and order siblings by `seq`.

## Record

| Field | Type | Meaning |
|---|---|---|
| `v` | int | Schema version, `1`. |
| `kind` | string | `call`, `init`, `gen`, `line` or `mark` (below). |
| `seq` | int | Position in **start** order within the process: assigned when the span starts, strictly increasing. A child's `seq` is greater than its parent's. |
| `trace_id` | string | 32 hex characters, the OpenTelemetry trace id. |
| `span_id` | string | 16 hex characters. |
| `parent_id` | string or null | `span_id` of the enclosing record, null for a root. |
| `name` | string | Qualified name, `module.Class.method` or `module.outer.<locals>.inner`. |
| `module` | string | Module name as Python knows it. |
| `file` | string | Source file path. |
| `line` | int | Line of the `def` (for `line` records: the executed line). |
| `start_ns`, `end_ns` | int | Wall clock, nanoseconds since the epoch. |
| `thread` | int | Small per-process alias of the thread (1, 2, ...), not the OS id. |
| `label` | string or null | Run label from the control file at the time the root span started. |
| `args` | object | Argument name to summary, after binding to the signature (`self` included). |
| `ret` | summary or null | Returned value. Null when the call raised. |
| `exc` | object or null | `{"type": "ValueError", "msg": "..."}` when the call raised. |
| `state` | array | Mutations detected across the call (below). Empty when none. |
| `attrs` | object | Extra attributes from plugins. May be empty. |

### Kinds

- `call`: one call of a function or method.
- `init`: one object construction, the `__init__` of a class defined in an instrumented file.
  `state` lists every attribute the new object has when `__init__` returns (`before` is null).
- `gen`: one invocation of a generator, coroutine or async generator function, from first resume
  to exhaustion or close. `ret` is `{"t": "gen", "yields": n}`.
- `line`: deep mode only. One executed source line of a function on the deep list. `args` is
  empty; `state` lists the local variables whose value changed on that line, with
  `target` = `"local"`.
- `mark`: a note from the recorder itself, for example calls that were counted but not recorded
  after a per-parent cap, or an error inside the recorder. `attrs` carries the details.

### `state` entries

```json
{"target": "self", "attr": "cache", "before": <summary or null>, "after": <summary or null>}
```

`target` is `"self"`, `"arg:<name>"` or `"local"`. `attr` is an attribute name, or `[key]` for an
item of a dict or list argument, or `""` when the argument itself was mutated in place (a tensor
written into). `before` null means the attribute or key is new; `after` null means it was removed.

## Summaries

A summary never contains tensor contents or long text. Every summary is an object with a type
tag `t`.

| `t` | Other fields |
|---|---|
| `none` | none |
| `bool`, `int`, `float` | `v`. A non-finite float is the string `"nan"`, `"inf"` or `"-inf"`. |
| `str` | `len`, `sha` (first 12 hex characters of SHA-256), and `v` only when the string is at most 64 characters or text recording is on. |
| `bytes` | `len`, `sha`. |
| `tensor` | See below. |
| `list`, `tuple`, `set` | `len`, `items`: summaries of the first few items. |
| `dict` | `len`, `items`: object from `str(key)` to summary, first few keys in insertion order. |
| `obj` | `cls` (`module.QualName`), `id` (alias, below), optionally `fields`: shallow attribute name to summary. |
| `fn` | `name`: qualified name of a function, method or other callable. |
| `gen` | `yields`. |
| `cut` | Depth or size limit reached; `cls` names the type. |

### Tensors

```json
{"t": "tensor", "id": 17, "ver": 3, "shape": [1, 24, 90, 60, 34], "dtype": "bfloat16",
 "device": "cuda:0", "mean": 0.01, "std": 1.02, "absmean": 0.81, "min": -6.1, "max": 5.9,
 "nan": 0, "inf": 0, "fp": "9c1b22e07a31f5d0",
 "profile": {"axis": 2, "edges": [0, 1, 2, "..."], "absmean": [0.8, 0.79, "..."]},
 "segments": {"text": 0.4, "video": 0.83}}
```

- `id`: alias of the tensor object, a small integer handed out in first-seen order per process.
  Memory addresses are never recorded, so two runs of the same code give the same aliases.
- `ver`: the tensor's in-place version counter. A change of `ver` on the same `id` is a write.
- `mean`, `std`, `absmean`, `min`, `max`: over all finite elements, computed in float32 or wider.
  Absent in `shape`-only mode.
- `nan`, `inf`: counts.
- `fp`: content fingerprint. Bit-identical tensors give the same value.
- `profile`: mean absolute value along one axis in bins; `edges` has one more entry than
  `absmean`. Present the first time an (`id`, `ver`) pair is summarized in a trace and omitted on
  later occurrences.
- `segments`: named groups along the same axis, from a plugin that knows the layout. Optional.
- `sampled`: present when the statistics and the fingerprint were computed on a strided view
  instead of the whole tensor. It lists the step taken along each dimension. Two cases:
  - tensors held in host memory above about 16 million elements (a decoded video, for example).
    Such a summary has no `profile`.
  - tensors on an accelerator above about 64 million elements (a transformer's token stream at
    video sizes). The profiled axis is thinned last, so its step is normally 1 and the summary
    keeps `profile` and `segments`; both are then means over the sampled elements of each bin.
    Fingerprints of sampled summaries compare only with fingerprints taken with the same steps.

A plugin can give a layout for a tensor shape. The `minimax_h3` plugin does so for the packed
token tensors of the H3 transformer, with or without a batch axis (`[batch, tokens, channels]` or
`[tokens, channels]`): the profile then has one bin per segment boundary and one per latent frame
inside the video segment.

NumPy arrays use the same form with `t` = `"ndarray"` and no `ver`.

### Aliases

`id` values for objects, tensors and threads are small integers assigned in first-seen order,
so that the same program run twice produces the same ids as long as it does the same things.

## Run directory

```
<out_dir>/<label or "unlabelled">-<UTC timestamp>-<pid>/
  meta.json       config snapshot, package version, Python and library versions, start time,
                  and for every instrumented file its path and SHA-256
  records.jsonl   the records
```

## Logfire mapping

Records of kind `call`, `init` and `gen` are spans named by `name`, nested the same way as
`parent_id`. `line` and `mark` records are logs under their span. Attributes: `podtrace.kind`,
`podtrace.seq`, `podtrace.label`, `code.filepath`, `code.lineno`, `code.function`, and the
structured values `args`, `ret`, `state`, `exc`, `attrs`.
