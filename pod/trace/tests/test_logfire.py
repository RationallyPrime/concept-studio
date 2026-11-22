import json
import os
import time
import warnings

import pytest

pytest.importorskip("logfire")
pytest.importorskip("opentelemetry.proto.collector.trace.v1.trace_service_pb2")

from otlp_server import Receiver

from podtrace import config, runtime
from podtrace.sinks import LogfireSink, logfire_wanted

TOKEN = "pylf_v1_us_testtoken0123456789"


@pytest.fixture(autouse=True)
def _quiet():
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        yield


@pytest.fixture
def server():
    srv = Receiver()
    yield srv
    srv.close()


def sink_config(tmp_path, srv=None, **lf):
    lf.setdefault("base_url", srv.url if srv else "")
    return config.from_dict({"out_dir": str(tmp_path / "runs"), "logfire": lf})


def record(i, parent=None, trace=1, **extra):
    now = time.time_ns()
    base = {
        "v": 1,
        "kind": "call",
        "seq": i,
        "trace_id": f"{trace:032x}",
        "span_id": f"{i + 1000:016x}",
        "parent_id": parent,
        "name": "m.f",
        "module": "m",
        "file": "f.py",
        "line": 1,
        "start_ns": now,
        "end_ns": now + 1000,
        "thread": 1,
        "label": "x",
        "args": {"a": {"t": "int", "v": i}},
        "ret": None,
        "exc": None,
        "state": [],
        "attrs": {},
    }
    base.update(extra)
    return base


def attrs(span):
    out = {}
    for a in span.attributes:
        kind = a.value.WhichOneof("value")
        out[a.key] = getattr(a.value, kind)
    return out


def test_export_needs_a_token_or_a_credentials_directory(tmp_path, monkeypatch):
    cfg = sink_config(tmp_path)
    assert logfire_wanted(cfg, {})[0] is False
    assert logfire_wanted(cfg, {"LOGFIRE_TOKEN": "  "})[0] is False
    assert logfire_wanted(cfg, {"LOGFIRE_TOKEN": TOKEN}) == (True, "LOGFIRE_TOKEN")
    # What logfire's own if-token-present would pick up is not enough here:
    assert logfire_wanted(cfg, {"LOGFIRE_API_KEY": "key"})[0] is False
    assert logfire_wanted(cfg, {"LOGFIRE_CREDENTIALS_DIR": str(tmp_path)})[0] is False
    cwd = tmp_path / "cwd"
    (cwd / ".logfire").mkdir(parents=True)
    (cwd / ".logfire" / "logfire_credentials.json").write_text("{}")
    monkeypatch.chdir(cwd)
    assert logfire_wanted(cfg, {})[0] is False
    creds = tmp_path / "creds"
    creds.mkdir()
    cfg2 = sink_config(tmp_path, credentials_dir=str(creds))
    assert logfire_wanted(cfg2, {})[0] is False  # directory given, file missing
    (creds / "logfire_credentials.json").write_text("{}")
    assert logfire_wanted(cfg2, {}) == (True, "credentials_dir")


def test_an_unconfigured_sink_never_starts_logfire(tmp_path, monkeypatch, capsys):
    monkeypatch.delenv("LOGFIRE_TOKEN", raising=False)
    monkeypatch.setenv("LOGFIRE_API_KEY", "key")
    cwd = tmp_path / "cwd"
    (cwd / ".logfire").mkdir(parents=True)
    (cwd / ".logfire" / "logfire_credentials.json").write_text("{}")
    monkeypatch.chdir(cwd)
    sink = LogfireSink(sink_config(tmp_path))
    sink.start()
    assert sink.active is False
    sink.emit(record(1))  # harmless
    assert "Logfire export is off" in capsys.readouterr().err


def test_spans_carry_the_record_ids_attributes_and_nesting(tmp_path, monkeypatch, server):
    monkeypatch.setenv("LOGFIRE_TOKEN", TOKEN)
    sink = LogfireSink(sink_config(tmp_path, server, service_name="comfyui"))
    sink.start()
    assert sink.active
    root = record(1, None, trace=0xABCDEF)
    child = record(
        2,
        root["span_id"],
        trace=0xABCDEF,
        args={},
        ret={"t": "int", "v": 3},
        exc={"type": "ValueError", "msg": "bad"},
        state=[{"target": "self", "attr": "x", "before": None, "after": {"t": "int", "v": 1}}],
    )
    line = record(3, child["span_id"], trace=0xABCDEF, kind="line")
    line["end_ns"] = line["start_ns"]
    sink.emit(child)
    sink.emit(line)
    sink.emit(root)
    sink.flush()
    sink.shutdown()
    by_id = {sp.span_id.hex(): (res, sp) for res, sp in server.spans}
    assert set(by_id) == {root["span_id"], child["span_id"], line["span_id"]}
    res, sp_root = by_id[root["span_id"]]
    assert res["service.name"] == "comfyui" and sp_root.trace_id.hex() == root["trace_id"]
    assert sp_root.parent_span_id == b""
    _, sp_child = by_id[child["span_id"]]
    assert sp_child.parent_span_id.hex() == root["span_id"] and sp_child.status.code == 2
    a = attrs(sp_child)
    assert a["podtrace.kind"] == "call" and a["podtrace.seq"] == 2 and a["code.lineno"] == 1
    assert (
        json.loads(a["ret"]) == {"t": "int", "v": 3}
        and json.loads(a["exc"])["type"] == "ValueError"
    )
    assert json.loads(a["state"])[0]["attr"] == "x" and "args" not in a
    assert json.loads(a["logfire.json_schema"])["properties"]["state"] == {"type": "array"}
    assert attrs(by_id[line["span_id"]][1])["logfire.span_type"] == "log"
    assert attrs(sp_root)["logfire.span_type"] == "span"
    assert (
        sp_root.start_time_unix_nano == root["start_ns"]
        and sp_root.end_time_unix_nano == root["end_ns"]
    )
    assert "/v1/traces" in server.paths


def test_credentials_directory_is_used_when_there_is_no_token(tmp_path, monkeypatch, server):
    monkeypatch.delenv("LOGFIRE_TOKEN", raising=False)
    creds = tmp_path / "creds"
    creds.mkdir()
    (creds / "logfire_credentials.json").write_text(
        json.dumps(
            {
                "token": TOKEN,
                "project_name": "p",
                "project_url": "https://logfire.example/p",
                "logfire_api_url": server.url,
            }
        )
    )
    sink = LogfireSink(sink_config(tmp_path, credentials_dir=str(creds)))
    sink.start()
    assert sink.active
    sink.emit(record(1))
    sink.shutdown()
    assert len(server.spans) == 1


def test_a_burst_of_spans_into_a_slow_receiver_loses_nothing(tmp_path, monkeypatch):
    monkeypatch.setenv("LOGFIRE_TOKEN", TOKEN)
    slow = Receiver(delay=0.02)
    try:
        sink = LogfireSink(sink_config(tmp_path, slow, flush_every=1500))
        sink.start()
        n = 6000  # three times the default queue of 2048
        for i in range(n):
            sink.emit(record(i + 1, None if i == 0 else f"{1001:016x}"))
        sink.shutdown()
        assert len(slow.spans) == n
        assert len({sp.span_id for _, sp in slow.spans}) == n
        assert sink.flush_failures == 0
    finally:
        slow.close()


def test_the_queue_size_setting_does_not_leak_into_the_environment(tmp_path, monkeypatch, server):
    monkeypatch.setenv("LOGFIRE_TOKEN", TOKEN)
    monkeypatch.delenv("OTEL_BSP_MAX_QUEUE_SIZE", raising=False)
    sink = LogfireSink(sink_config(tmp_path, server))
    sink.start()
    assert "OTEL_BSP_MAX_QUEUE_SIZE" not in os.environ
    sink.shutdown()


def test_full_pipeline_flushes_at_the_end_of_each_root(h, monkeypatch, server):
    monkeypatch.setenv("LOGFIRE_TOKEN", TOKEN)
    h.start(logfire={"enabled": True, "base_url": server.url, "service_name": "comfyui"})
    m = h.module(
        """
        def leaf(x): return x
        def root(x): return leaf(x) + leaf(1)
        """
    )
    m.root(1)
    # the root has ended: its spans must already be at the receiver, without waiting for exit
    deadline = time.time() + 5
    while len(server.spans) < 3 and time.time() < deadline:
        time.sleep(0.02)
    recs = h.records()
    assert {sp.span_id.hex() for _, sp in server.spans} == {r["span_id"] for r in recs}
    assert {sp.trace_id.hex() for _, sp in server.spans} == {recs[0]["trace_id"]}
    parents = {sp.span_id.hex(): sp.parent_span_id.hex() for _, sp in server.spans}
    assert parents == {r["span_id"]: r["parent_id"] or "" for r in recs}
    runtime.shutdown()
