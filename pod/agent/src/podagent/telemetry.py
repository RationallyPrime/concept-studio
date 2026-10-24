"""Optional tracing to Logfire, on only when the pod was given ``LOGFIRE_TOKEN``.

What is sent: the agent's HTTP requests (method, route, status, timing; never request values or
bodies), its own log lines (service starts, exits, stuck processes) and the caption server's
request traces (token counts and latency breakdowns; vLLM puts no prompt or output text in its
spans). Images, clips and caption text never leave the pod through this path.
"""

from __future__ import annotations

import logging
import os
import re
from dataclasses import dataclass, field
from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    from fastapi import FastAPI, Request, WebSocket

# A Logfire write token names its region (``pylf_v1_eu_…``); older tokens without one are US.
_REGION = re.compile(r"^pylf_v[0-9]+_(?P<region>[a-z]+)_")
_BASE_URLS = {"us": "https://logfire-us.pydantic.dev", "eu": "https://logfire-eu.pydantic.dev"}

# Not traced: what the app polls every few seconds (one span each would bury everything else),
# TensorBoard's proxied traffic, and uploads, whose URLs carry the person's own file names.
_EXCLUDED = [
    r"/health$",
    r"/gpus$",
    r"/storage$",
    r"/services$",
    r"/services/[^/]+$",
    r"/services/[^/]+/logs",
    r"/runs/[^/]+/(events|log|files|log-files)",
    r"/tensorboard",
    r"/uploads/",
]


@dataclass(frozen=True)
class Telemetry:
    token: str = field(repr=False)
    resource: dict[str, str]

    @property
    def base_url(self) -> str:
        match = _REGION.match(self.token)
        return _BASE_URLS.get(match.group("region") if match else "us", _BASE_URLS["us"])

    @property
    def traces_endpoint(self) -> str:
        return self.base_url + "/v1/traces"

    def child_env(self, service_name: str) -> dict[str, str]:
        """OTLP settings for a child that exports its own spans (vLLM reads the standard names)."""
        attributes = ",".join(f"{key}={value}" for key, value in self.resource.items())
        return {
            "OTEL_SERVICE_NAME": service_name,
            "OTEL_RESOURCE_ATTRIBUTES": attributes,
            "OTEL_EXPORTER_OTLP_TRACES_PROTOCOL": "http/protobuf",
            "OTEL_EXPORTER_OTLP_TRACES_HEADERS": f"Authorization={self.token}",
        }


def load_telemetry(env: os._Environ[str] | dict[str, str]) -> Telemetry | None:
    token = env.get("LOGFIRE_TOKEN", "").strip()
    if not token:
        return None
    resource = {"runpod.pod_id": env.get("RUNPOD_POD_ID", "").strip()}
    return Telemetry(token=token, resource={key: value for key, value in resource.items() if value})


def _arguments_without_values(_request: Request | WebSocket, attributes: dict[str, Any]):
    """Keep validation errors, drop the request's values: they can name repos, runs and files."""
    errors = attributes.get("errors")
    return {"errors": errors} if errors else None


def configure(app: FastAPI, telemetry: Telemetry, version: str) -> None:
    import logfire

    logfire.configure(
        token=telemetry.token,
        service_name="podagent",
        service_version=version,
        resource_attributes=telemetry.resource,
        console=False,
        inspect_arguments=False,
    )
    instrument(app)


def instrument(app: FastAPI) -> None:
    """Trace the agent's requests and send its log lines to whatever Logfire is configured."""
    import logfire

    logfire.instrument_fastapi(
        app, excluded_urls=_EXCLUDED, request_attributes_mapper=_arguments_without_values
    )
    logging.getLogger("podagent").addHandler(logfire.LogfireLoggingHandler())
