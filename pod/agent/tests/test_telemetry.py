"""Telemetry is off without a token, sends no request values, and gives only vLLM its OTLP setup."""

from __future__ import annotations

import json
from dataclasses import replace

from conftest import AUTH, TOKEN
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
