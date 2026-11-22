# podtrace

A load-time call, construction and state tracer for the ComfyUI MiniMax H3 video pipeline. It
answers "what ran, with what, and what changed" for one render, without editing any ComfyUI or
custom-node file.

It records, per call of the functions and classes you select:

- the call (qualified name, file, line, start and end time, thread, parent, exception);
- the arguments and return value, as bounded summaries (tensors by shape, dtype, device,
  version counter, statistics, optional profile; strings, numbers, containers and objects by
  shape);
- the attributes an object gained or changed while the call ran, and in-place writes to
  arguments (`state` entries);
- construction (`init` records) and generator lifetimes (`gen` records);
- free-form `line` records (deep mode) and `mark` records (caps, recorder errors).

The record format is `docs/RECORD-SCHEMA.md`; it is the contract and this package only writes it.

## What it writes and what leaves the machine

- A run directory `<out_dir>/<label>-<UTC>-<pid>/` with `records.jsonl` (one record per line) and
  `meta.json` (versions, config, platform). Nothing else is written outside it.
- Optionally Pydantic Logfire spans, one per `call`, `init` and `gen` record and logs for `line`
  and `mark` records. Export happens only when `LOGFIRE_TOKEN` is set in the environment or
  `[logfire] credentials_dir` names a directory holding `logfire_credentials.json`. A
  `.logfire` directory in the working directory and `LOGFIRE_API_KEY` are deliberately ignored.
  With neither, a single line on stderr says that export is off and nothing is sent.
- Values are summaries, not data: tensors never leave as contents. A string is stored as length
  and a short hash, plus its value only when it is at most 64 characters (or `text = true`).
  Arguments and attributes whose name contains `token`, `secret`, `passw`, `api_key`, `auth`,
  `credential`, `bearer`, `cookie` or `private_key` keep only length and hash. Logfire's own
  scrubbing is switched off because it mangles the structured values; the name based rule above
  replaces it.

## Install

The package has no required dependencies. Logfire export needs the `logfire` extra.

```bash
COMFY=/workspace/runpod-slim/ComfyUI
PY=$COMFY/.venv-cu128/bin/python
uv pip install --python $PY "<path-to-repo>/pod/trace[logfire]"
$PY -m podtrace install --python $PY \
    --config <path-to-repo>/pod/trace/configs/comfyui-minimax-h3.toml
```

`install` writes `podtrace.pth` into the venv's site-packages and copies the config to
`/workspace/podtrace/config.toml` (override with `--config-dest`). `podtrace status --python $PY`
shows what is installed, which config is read and the state of the control file.

Remove it:

```bash
$PY -m podtrace uninstall --python $PY
uv pip uninstall --python $PY podtrace
```

Uninstall `podtrace.pth` first. Removing the package alone leaves a `.pth` line that prints one
harmless "ModuleNotFoundError" line at interpreter start. `PODTRACE_DISABLE=1` in the environment
switches the hook off without removing anything. If no config file exists the hook does nothing.

## How it works

The `.pth` file imports `podtrace.bootstrap` in every Python process of the venv. If a config
file exists, it replaces `SourceFileLoader.get_code` so that files matching an `[[include]]`
rule are parsed, rewritten (a decorator on each selected function and class, plus a module
prologue) and compiled in memory. The source files and `.pyc` caches are never touched; files
that do not match are loaded by the original code path. Any error in the hook falls back to the
unmodified module. Matching is by file path, so it works for normal imports and for ComfyUI's
custom node loader (`spec_from_file_location` with arbitrary module names) alike.

`argv_glob` restricts tracing to the ComfyUI process (`main.py`); other Python processes in the
venv (pip, uv, workers) load the hook and do nothing. At `.pth` time `python -m pkg` shows up in
`sys.argv` as `-m`, so a pattern for a `-m` launch has to match `-m`.

Recording is off until the control file says otherwise, so an installed tracer costs a function
call wrapper and a flag check per traced call and writes nothing.

## Turning it on for one render

```bash
podtrace control on --label broken      # next root call starts a new run directory
# ... queue the render in ComfyUI ...
podtrace control off
```

The control file is JSON, polled twice a second by a daemon thread and also checked at the start
of every root call, so you can edit it by hand:

```json
{"record": true, "label": "broken", "deep": ["ClipLoops.*", "sample_*"]}
```

| key | meaning |
| --- | --- |
| `record` | `true` records; `false` or a missing file does not. |
| `label` | Name for the run directory. A new label, or turning record off and on, opens a new run directory and resets ids, aliases and `seq`. |
| `deep` | Qualified-name patterns whose functions also emit one `line` record per executed line (Python 3.12 or newer, `sys.monitoring`). Empty by default. |

Two runs recorded this way can be compared with `podtrace diff <run-a> <run-b>`; that command is
implemented in `podtrace.compare` and takes its arguments from there.

## Configuration

TOML, read once per process from `PODTRACE_CONFIG` or `/workspace/podtrace/config.toml`. The
ready-made file for the MiniMax H3 stack is `configs/comfyui-minimax-h3.toml`.

Top level:

| key | default | meaning |
| --- | --- | --- |
| `argv_glob` | `[]` (every process) | fnmatch patterns for `sys.argv[0]`; the process is traced if one matches. |
| `out_dir` | `/workspace/podtrace/runs` | where run directories go. |
| `control_file` | `/workspace/podtrace/control.json` | the control file. |
| `control_poll_s` | `0.5` | polling interval. |
| `per_parent_cap` | `10000` | most child records one parent may emit; the rest are dropped and one `mark` says how many. |
| `stack_dump_file` | `""` (off) | `kill -USR1 <pid>` appends the Python stack of every thread to this file: where a traced program is when it seems stuck. |
| `plugins` | `[]` | plugin modules from `podtrace.plugins` (`minimax_h3` learns the packed-layout segments). |
| `text` | `false` | keep every string value instead of only short ones. |
| `inference_check` | `"probe"` | how inference tensors (no version counter) are cached: `probe`, `full` (always recompute) or `trust` (identity only). |

`[summary]` (limits, all integers): `profile_bins` 256, `items` 4 (list and tuple items shown),
`dict_items` 8, `fields` 12 (object attributes shown), `max_depth` 4, `max_nodes` 256,
`max_tensors` 24 (tensors summarised per record).

`[jsonl]`: `enabled` (true).

`[logfire]`: `enabled` (true), `service_name` (`comfyui`), `credentials_dir` (empty), `base_url`
(empty, Logfire's default), `flush_every` 20000 spans, `flush_timeout_s` 300, `queue_size`
1,000,000. The large queue and periodic flush exist so that spans are not dropped; the batch
queue is sized through `OTEL_BSP_MAX_QUEUE_SIZE` unless you already set it. A flush waits for
the export, on the thread that recorded the span, at the end of each root span and every
`flush_every` spans. The one exception is the main thread while it runs an asyncio event loop
(ComfyUI's web server): nothing waits there, because that would freeze the web interface for as
long as the export takes, and the exporter's own thread sends what is queued.

`[[include]]` rules, first match wins (a file matches at most one rule):

| key | default | meaning |
| --- | --- | --- |
| `path` | required | path glob. `*` and `?` stay inside a directory, `**/` spans directories, a pattern not starting with `/` matches any trailing part of the path. Symlinks are also tried resolved. |
| `names` | `["*"]` | fnmatch patterns on file-local qualified names (`Class.method`, `outer.<locals>.inner`) of functions and classes to instrument. |
| `exclude` | `[]` | same, subtracted. |
| `stats` | `"full"` | `full`: tensor statistics, quantiles and profile; `basic`: shape, dtype, version, min, max, mean; `shape`: shape and dtype only. Use `basic` or `shape` on hot loops (the VAE). |

## Overhead

Measured on this machine (Python 3.12, one thread, `timeit`, a traced function that returns its
argument):

| | per call |
| --- | --- |
| untraced | about 30 ns |
| traced, recording off | about 78 ns |
| traced, recording on, small int argument and return, JSONL only | about 11 to 14 microseconds (nested in a root, and as a root) |

Recording on is dominated by building and serialising the record, not by the wrapper. Cost grows
with the number and size of tensors in a call: summaries run in 4M-element chunks on the tensor's
own device with a single synchronisation, but a `full` summary of a large tensor is still a few
reductions over it. Pick `stats` accordingly, and trace the functions you care about rather than
all of them.

The benchmark used a throwaway module and was not run against ComfyUI; treat the numbers as the
order of magnitude of the fixed cost per traced call.

## Tests

```bash
uv sync
uv run pytest
```

The suite contains unit tests, subprocess end-to-end tests, a real `.pth` round trip in a fresh
venv, and a fake OTLP receiver for the Logfire path. Tests that need torch skip when it is not
installed; the deep-mode tests skip on Python 3.11.

## Limitations

- In-place writes to tensors are detected for arguments (by version counter, or by a sampled
  fingerprint for inference tensors). Writes to inference tensors held as `self` attributes or
  deep locals are not detected. Probe sampling of large inference tensors can miss a tiny write.
- Argument errors for generator functions surface at the first `next()`, as in Python itself.
- The wrapper replaces the function object, so `__code__` and the frame of the original body
  differ from what a debugger shows without the hook; `inspect.signature` still works.
- A thread started inside traced code starts its own root; parent links do not cross threads.
- `podtrace.pth` runs once per interpreter start and again in child processes; `argv_glob`
  keeps the latter inert.
- Objects that cannot be weakly referenced are identified by `id()` only, so a recycled address
  can share an alias within one run.
- Before-summaries of attributes come from a cached key; an attribute never summarised before
  carries no statistics in its "before" half.
- Summarising a tensor may allocate temporaries from the CUDA caching allocator.
- Verified with torch 2.15 (CPU). CUDA and the torch 2.10 cu128 build in the ComfyUI venv have not
  been exercised, and the `minimax_h3` plugin has been run against a stand-in, not a real
  `PackedLayout`.
