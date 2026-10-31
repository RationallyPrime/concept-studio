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
import time
from dataclasses import dataclass, field
from typing import TYPE_CHECKING

from starlette.routing import BaseRoute, Route
from starlette.types import ASGIApp, Message, Receive, Scope, Send

if TYPE_CHECKING:
    from fastapi import FastAPI

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


class RequestTelemetry:
    """Trace only allowlisted metadata, never automatic ASGI URL/argument/exception fields."""

    def __init__(self, app: ASGIApp, routes: list[BaseRoute]) -> None:
        self.app = app
        # Middleware is constructed after route registration. Only these fixed templates may leave.
        self.routes = {id(route): route.path for route in routes if isinstance(route, Route)}

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http" or any(
            re.search(pattern, scope.get("path", "")) for pattern in _EXCLUDED
        ):
            await self.app(scope, receive, send)
            return

        import logfire

        method = scope.get("method", "")
        # Configuration is polled frequently. Decide after the response so failures still
        # appear; do not export the concrete path, query, body, or exception.
        config_poll = method == "GET" and re.fullmatch(r"/runs/[^/]+/config", scope.get("path", ""))
        if method not in {
            "GET",
            "POST",
            "PUT",
            "PATCH",
            "DELETE",
            "HEAD",
            "OPTIONS",
            "TRACE",
            "CONNECT",
        }:
            method = "OTHER"
        status = 500

        async def record_status(message: Message) -> None:
            nonlocal status
            if message["type"] == "http.response.start":
                value = message.get("status")
                if type(value) is int and 100 <= value <= 599:
                    status = value
            await send(message)

        if config_poll:
            started = time.monotonic()
            try:
                await self.app(scope, receive, record_status)
            finally:
                if status >= 400:
                    logfire.warning(
                        "Agent request failed",
                        **{
                            "http.method": method,
                            "http.route": "/runs/{run_id}/config",
                            "http.status_code": status,
                            "duration_s": time.monotonic() - started,
                        },
                    )
            return

        span = logfire.span("Agent request", **{"http.method": method})
        span.__enter__()
        try:
            await self.app(scope, receive, record_status)
        finally:
            span.set_attribute("http.route", self.routes.get(id(scope.get("route")), "<unmatched>"))
            span.set_attribute("http.status_code", status)
            # End normally even when the request raises: exception text/locals may contain inputs.
            # The original exception still propagates to the server unchanged.
            span.__exit__(None, None, None)


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

    app.add_middleware(RequestTelemetry, routes=app.routes)
    agent_log = logging.getLogger("podagent")
    # The agent's lifecycle lines (service started, exited) are INFO; the default threshold is WARNING.
    agent_log.setLevel(logging.INFO)
    agent_log.addHandler(logfire.LogfireLoggingHandler())


def report_collection_failure() -> None:
    import logfire

    logfire.warning("Training telemetry collection failed")
