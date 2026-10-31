"""Telemetry is off without a token, sends no request values, and gives only vLLM its OTLP setup."""

from __future__ import annotations

import json
from dataclasses import replace

import pytest
from conftest import AUTH, TOKEN
from fastapi import FastAPI
from fastapi.testclient import TestClient
from logfire.testing import CaptureLogfire

from podagent import telemetry
from podagent.app import create_app
from podagent.catalog import CATALOG, parse_params
from podagent.gpus import FakeBackend
from podagent.settings import Settings, load_settings
from podagent.supervisor import child_env
from podagent.telemetry import Telemetry, load_telemetry

EU_TOKEN = "pylf_v1_eu_0123456789abcdef"


def test_telemetry_is_off_without_a_token_and_names_the_pod_with_one() -> None:
    assert load_settings({"PODAGENT_TOKEN": TOKEN}).telemetry is None
    loaded = load_telemetry({"LOGFIRE_TOKEN": EU_TOKEN, "RUNPOD_POD_ID": "as456w5b6sgl8v"})
    assert loaded == Telemetry(token=EU_TOKEN, resource={"runpod.pod_id": "as456w5b6sgl8v"})
    assert EU_TOKEN not in repr(loaded)


def test_traces_go_to_the_tokens_region() -> None:
    assert Telemetry(EU_TOKEN, {}).traces_endpoint == "https://logfire-eu.pydantic.dev/v1/traces"
    assert Telemetry("pylf_v1_us_abc", {}).base_url == "https://logfire-us.pydantic.dev"
    assert Telemetry("an-older-token", {}).base_url == "https://logfire-us.pydantic.dev"


def test_only_vllm_gets_the_otlp_header_and_no_child_inherits_the_token(
    settings: Settings, monkeypatch
) -> None:
    monkeypatch.setenv("LOGFIRE_TOKEN", EU_TOKEN)
    traced = replace(settings, telemetry=Telemetry(EU_TOKEN, {"runpod.pod_id": "p"}))
    vllm = CATALOG["vllm"]
    vllm_env = child_env(
        vllm, [0], parse_params("vllm", {"model": "org/m"}, settings.paths), traced
    )
    assert vllm_env["OTEL_EXPORTER_OTLP_TRACES_HEADERS"] == f"Authorization={EU_TOKEN}"
    assert vllm_env["OTEL_RESOURCE_ATTRIBUTES"] == "runpod.pod_id=p"
    assert vllm.telemetry_args(traced.telemetry) == [
        "--otlp-traces-endpoint",
        "https://logfire-eu.pydantic.dev/v1/traces",
    ]
    board = CATALOG["tensorboard"]
    board_env = child_env(board, [], parse_params("tensorboard", {}, settings.paths), traced)
    assert "LOGFIRE_TOKEN" not in vllm_env and "LOGFIRE_TOKEN" not in board_env
    assert not any(key.startswith("OTEL_EXPORTER") for key in board_env)
    assert board.telemetry_args(traced.telemetry) == []


def test_requests_are_traced_without_their_values_and_polling_is_not(
    settings: Settings, capfire: CaptureLogfire
) -> None:
    app = create_app(settings, FakeBackend(2))
    telemetry.instrument(app)
    with TestClient(app, headers=AUTH) as client:
        assert client.get("/services").status_code == 200
        started = client.post(
            "/services/vllm/start", json={"gpus": [0], "params": {"model": "org/private-model"}}
        )
        assert started.status_code == 201
        client.post("/services/vllm/stop", json={})
    spans = capfire.exporter.exported_spans_as_dict()
    routes = {span["attributes"].get("http.route") for span in spans}
    assert "/services/{name}/start" in routes
    assert "/services" not in routes
    assert "org/private-model" not in json.dumps(spans, default=str)


@pytest.mark.parametrize("private_field", ["caption", "NORA7-private-caption-as-key"])
def test_a_rejected_request_exports_no_validation_content(
    settings: Settings, capfire: CaptureLogfire, private_field: str
) -> None:
    app = create_app(settings, FakeBackend(2))
    telemetry.instrument(app)
    with TestClient(app, headers=AUTH) as client:
        rejected = client.post(
            "/services/vllm/start",
            json={"gpus": [0], "params": {"model": "org/m"}, private_field: "a private caption"},
        )
        assert rejected.status_code == 422
    exported = json.dumps(capfire.exporter.exported_spans_as_dict(), default=str)
    assert "a private caption" not in exported
    assert "NORA7-private-caption-as-key" not in exported
    assert "extra_forbidden" not in exported
    assert any(
        span["attributes"].get("http.status_code") == 422
        for span in capfire.exporter.exported_spans_as_dict()
    )


@pytest.mark.parametrize(
    ("method", "path", "status", "route"),
    [
        ("POST", "/services/vllm/start", 422, "/services/{name}/start"),
        ("POST", "/services/NORA7-private-path/start", 422, "/services/{name}/start"),
        ("GET", "/NORA7-private-unmatched", 404, "<unmatched>"),
        ("NORA7-private-method", "/services/vllm/start", 405, "/services/{name}/start"),
    ],
)
def test_request_spans_export_only_safe_metadata(
    settings: Settings, capfire: CaptureLogfire, method: str, path: str, status: int, route: str
) -> None:
    app = create_app(settings, FakeBackend(2))
    telemetry.instrument(app)
    with TestClient(app, headers=AUTH) as client:
        response = client.request(
            method,
            path + "?note=NORA7-private-query",
            headers={"User-Agent": "NORA7-private-header", "Cookie": "note=NORA7-private-cookie"},
            json={"NORA7-private-field": "NORA7-private-body"},
        )
        assert response.status_code == status
    spans = capfire.exporter.exported_spans_as_dict()
    assert "NORA7-private" not in json.dumps(spans, default=str)
    request_spans = [span for span in spans if span["name"] == "Agent request"]
    assert len(request_spans) == 1
    attributes = request_spans[0]["attributes"]
    assert attributes["http.method"] == ("OTHER" if method.startswith("NORA7") else method)
    assert attributes["http.route"] == route
    assert attributes["http.status_code"] == status
    assert not {"http.url", "http.target", "url.full", "url.path", "url.query"} & attributes.keys()


def test_request_exceptions_propagate_without_exporting_their_content(
    capfire: CaptureLogfire,
) -> None:
    app = FastAPI(telemetry={"tracing": False, "metrics": False, "logs": False})

    @app.get("/failure")
    async def failure() -> None:
        raise RuntimeError("NORA7-private-exception")

    telemetry.instrument(app)
    with TestClient(app) as client, pytest.raises(RuntimeError, match="NORA7-private-exception"):
        client.get("/failure?note=NORA7-private-query")
    spans = capfire.exporter.exported_spans_as_dict()
    assert "NORA7-private" not in json.dumps(spans, default=str)
    assert any(span["attributes"].get("http.status_code") == 500 for span in spans)


def test_service_lifecycle_lines_reach_logfire(settings: Settings, capfire: CaptureLogfire) -> None:
    app = create_app(settings, FakeBackend(2))
    telemetry.instrument(app)
    with TestClient(app, headers=AUTH) as client:
        client.post("/services/vllm/start", json={"gpus": [0], "params": {"model": "org/m"}})
        client.post("/services/vllm/stop", json={})
    messages = [
        span["attributes"].get("logfire.msg", "")
        for span in capfire.exporter.exported_spans_as_dict()
    ]
    assert any(message.startswith("started vllm") for message in messages)


def test_requests_emit_nothing_without_opt_in(settings: Settings, capfire: CaptureLogfire) -> None:
    with TestClient(create_app(settings, FakeBackend(2)), headers=AUTH) as client:
        client.post("/services/vllm/start?note=NORA7-private-query", json={"unexpected": "private"})
    assert capfire.exporter.exported_spans_as_dict() == []


@pytest.mark.parametrize(
    "path",
    [
        "/health",
        "/gpus",
        "/storage",
        "/services",
        "/services/vllm",
        "/services/vllm/logs",
        "/runs/NORA7-private-run/events",
        "/runs/NORA7-private-run/files",
        "/runs/NORA7-private-run/log-files",
        "/tensorboard/NORA7-private-path",
        "/uploads/NORA7-private-file",
    ],
)
def test_excluded_requests_emit_no_spans(
    settings: Settings, capfire: CaptureLogfire, path: str
) -> None:
    app = create_app(settings, FakeBackend(2))
    telemetry.instrument(app)
    with TestClient(app) as client:
        # Unauthorized requests exercise the exclusion without opening log streams or services.
        client.get(path + "?note=NORA7-private-query")
    assert capfire.exporter.exported_spans_as_dict() == []


def test_config_poll_success_is_suppressed_but_failure_is_safe(settings, capfire):
    app = create_app(settings, FakeBackend(0))
    telemetry.instrument(app)
    run = settings.paths.run_dir("private-run")
    run.mkdir()
    (run / "run.json").write_text("{}")
    with TestClient(app, headers=AUTH) as client:
        assert client.get("/runs/private-run/config").status_code == 200
        assert client.get("/runs/missing-private/config").status_code == 404
    exported = capfire.exporter.exported_spans_as_dict()
    assert len(exported) == 1
    assert exported[0]["attributes"]["http.status_code"] == 404
    assert "private" not in json.dumps(exported, default=str)
