"""Where records go: a JSONL run directory and, optionally, Pydantic Logfire."""

from __future__ import annotations

import json
import os
import re
import sys
import threading
import time
from typing import Any

from .config import Config


def _dumps(obj: Any) -> str:
    return json.dumps(obj, separators=(",", ":"), default=str, ensure_ascii=False)


def safe_label(label: str | None) -> str:
    text = re.sub(r"[^A-Za-z0-9._-]+", "_", label or "").strip("._") or "unlabelled"
    return text[:80]


class JsonlSink:
    """One ``records.jsonl`` per run directory, written synchronously and flushed per root."""

    def __init__(self, cfg: Config) -> None:
        self.cfg = cfg
        self.run_dir: str | None = None
        self._fh: Any = None
        self._lock = threading.Lock()

    def open_run(self, label: str | None) -> str:
        self.close()
        stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
        base = os.path.join(self.cfg.out_dir, f"{safe_label(label)}-{stamp}-{os.getpid()}")
        path, n = base, 1
        while True:
            try:
                os.makedirs(path)
                break
            except FileExistsError:
                n += 1
                path = f"{base}-{n}"
        self.run_dir = path
        self._fh = open(  # noqa: SIM115
            os.path.join(path, "records.jsonl"), "w", encoding="utf-8", buffering=1 << 20
        )
        return path

    def write(self, rec: dict[str, Any]) -> None:
        line = _dumps(rec)
        with self._lock:
            if self._fh is not None:
                self._fh.write(line + "\n")

    def flush(self) -> None:
        with self._lock:
            if self._fh is not None:
                self._fh.flush()

    def write_meta(self, meta: dict[str, Any]) -> None:
        if self.run_dir is None:
            return
        with self._lock:
            tmp = os.path.join(self.run_dir, "meta.json.tmp")
            with open(tmp, "w", encoding="utf-8") as fh:
                json.dump(meta, fh, indent=2, default=str)
            os.replace(tmp, os.path.join(self.run_dir, "meta.json"))

    def close(self) -> None:
        with self._lock:
            fh, self._fh = self._fh, None
        if fh is not None:
            try:  # noqa: SIM105
                fh.close()
            except OSError:
                pass


def logfire_wanted(cfg: Config, env: Any = None) -> tuple[bool, str]:
    """Export only when ``LOGFIRE_TOKEN`` is set or a credentials directory is configured.

    Logfire's own ``send_to_logfire="if-token-present"`` is wider than that: it also reads a
    credentials file from ``LOGFIRE_CREDENTIALS_DIR`` or from ``.logfire`` in the working
    directory, and falls back to ``LOGFIRE_API_KEY``. The check here keeps those out: the working
    directory of a ComfyUI process is not a place to take credentials from.
    """
    env = os.environ if env is None else env
    if (env.get("LOGFIRE_TOKEN") or "").strip():
        return True, "LOGFIRE_TOKEN"
    if cfg.credentials_dir:
        if os.path.isfile(os.path.join(cfg.credentials_dir, "logfire_credentials.json")):
            return True, "credentials_dir"
        return False, f"no logfire_credentials.json in {cfg.credentials_dir}"
    return False, "no LOGFIRE_TOKEN and no credentials_dir in the config"


class LogfireSink:
    """Spans for ``call``/``init``/``gen`` records and logs for ``line``/``mark`` records.

    Spans are created when the record is complete, with explicit start and end times and with the
    ids the record already carries, and are never made the current span. Nothing here stays
    attached to an OpenTelemetry context while the traced code runs or yields.
    """

    def __init__(self, cfg: Config) -> None:
        self.cfg = cfg
        self.active = False
        self.reason = ""
        self._lf: Any = None
        self._tracer: Any = None
        self._log_tracer: Any = None
        self._ids: Any = None
        self._pending = 0
        self._api: Any = None
        self.flush_failures = 0

    def start(self) -> None:
        wanted, why = logfire_wanted(self.cfg)
        self.reason = why
        if not wanted:
            sys.stderr.write(f"podtrace: Logfire export is off ({why})\n")
            return
        import logfire
        from opentelemetry import context as otel_context
        from opentelemetry import trace
        from opentelemetry.sdk.trace.id_generator import IdGenerator, RandomIdGenerator

        class PresetIds(IdGenerator):
            """Hands out the ids a record already has; random ones for anything else."""

            def __init__(self) -> None:
                self.local = threading.local()
                self.fallback = RandomIdGenerator()

            def generate_span_id(self) -> int:
                value = getattr(self.local, "span", None)
                self.local.span = None
                return value or self.fallback.generate_span_id()

            def generate_trace_id(self) -> int:
                value = getattr(self.local, "trace", None)
                self.local.trace = None
                return value or self.fallback.generate_trace_id()

        ids = PresetIds()
        creds = self.cfg.credentials_dir or os.path.join(
            self.cfg.out_dir, ".no-logfire-credentials"
        )
        advanced_kwargs: dict[str, Any] = {}
        if self.cfg.logfire_base_url:
            advanced_kwargs["base_url"] = self.cfg.logfire_base_url
        advanced = logfire.AdvancedOptions(
            id_generator=ids,
            pending_spans=False,
            emit_configuration_span=False,
            **advanced_kwargs,
        )
        # The batch processor reads its queue size from the environment when it is built. A large
        # queue plus a flush every ``flush_every`` spans means nothing is ever dropped.
        queue_var = "OTEL_BSP_MAX_QUEUE_SIZE"
        set_here = queue_var not in os.environ
        if set_here:
            os.environ[queue_var] = str(self.cfg.logfire_queue_size)
        try:
            self._lf = logfire.configure(
                send_to_logfire="if-token-present",
                service_name=self.cfg.service_name,
                console=False,
                inspect_arguments=False,
                scrubbing=False,
                metrics=False,
                distributed_tracing=False,
                data_dir=creds,
                advanced=advanced,
                local=True,
            )
        finally:
            if set_here:
                os.environ.pop(queue_var, None)
        provider = self._lf.config.get_tracer_provider()
        self._tracer = provider.get_tracer("podtrace")
        # Logfire marks everything from the default tracer as a span; logs come from the other kind.
        self._log_tracer = provider.get_tracer("podtrace", is_span_tracer=False)
        self._ids = ids
        self._api = (otel_context, trace)
        self.active = True

    # ------------------------------------------------------------------ emission

    def emit(self, rec: dict[str, Any]) -> None:
        if not self.active:
            return
        otel_context, trace = self._api
        trace_id = int(rec["trace_id"], 16)
        span_id = int(rec["span_id"], 16)
        self._ids.local.trace = trace_id
        self._ids.local.span = span_id
        ctx = otel_context.Context()
        if rec["parent_id"]:
            parent = trace.NonRecordingSpan(
                trace.SpanContext(
                    trace_id=trace_id,
                    span_id=int(rec["parent_id"], 16),
                    is_remote=True,
                    trace_flags=trace.TraceFlags(trace.TraceFlags.SAMPLED),
                )
            )
            ctx = trace.set_span_in_context(parent, ctx)
        kind = rec["kind"]
        attrs: dict[str, Any] = {
            "logfire.msg_template": rec["name"],
            "logfire.msg": rec["name"],
            "logfire.span_type": "span" if kind in ("call", "init", "gen") else "log",
            "podtrace.kind": kind,
            "podtrace.seq": rec["seq"],
            "podtrace.label": rec["label"] or "",
            "podtrace.thread": rec["thread"],
            "code.filepath": rec["file"],
            "code.lineno": rec["line"],
            "code.function": rec["name"],
            "code.namespace": rec["module"],
        }
        schema: dict[str, Any] = {}
        for key, shape in (
            ("args", "object"),
            ("ret", "object"),
            ("state", "array"),
            ("exc", "object"),
            ("attrs", "object"),
        ):
            value = rec.get(key)
            if value:
                attrs[key] = _dumps(value)
                schema[key] = {"type": shape}
        if schema:
            attrs["logfire.json_schema"] = _dumps({"type": "object", "properties": schema})
        if rec.get("exc"):
            attrs["logfire.level_num"] = 17
        elif kind == "mark":
            attrs["logfire.level_num"] = 13
        tracer = self._tracer if kind in ("call", "init", "gen") else self._log_tracer
        span = tracer.start_span(
            rec["name"], context=ctx, attributes=attrs, start_time=rec["start_ns"]
        )
        if rec.get("exc"):
            from opentelemetry.trace import Status, StatusCode

            exc = rec["exc"]
            span.set_status(Status(StatusCode.ERROR, f"{exc['type']}: {exc['msg']}"[:200]))
        span.end(end_time=rec["end_ns"])
        self._pending += 1
        if self._pending >= self.cfg.logfire_flush_every:
            self.flush()

    def flush(self) -> None:
        if not self.active:
            return
        self._pending = 0
        ok = self._lf.force_flush(int(self.cfg.logfire_flush_timeout_s * 1000))
        if ok is False:
            self.flush_failures += 1

    def shutdown(self) -> None:
        if not self.active:
            return
        try:
            self.flush()
            self._lf.shutdown(int(self.cfg.logfire_flush_timeout_s * 1000))
        finally:
            self.active = False
