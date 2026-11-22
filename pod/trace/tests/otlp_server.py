"""A minimal OTLP/HTTP trace receiver for tests: decodes spans, optionally slow."""

from __future__ import annotations

import gzip
import threading
import time
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Receiver:
    def __init__(self, delay: float = 0.0) -> None:
        self.spans: list = []
        self.requests = 0
        self.paths: list[str] = []
        self.delay = delay
        self.lock = threading.Lock()
        outer = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def do_GET(self):
                outer.paths.append(self.path)
                self.send_response(404)
                self.end_headers()

            def do_POST(self):
                body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
                outer.paths.append(self.path)
                enc = (self.headers.get("Content-Encoding") or "").lower()
                if enc == "gzip":
                    body = gzip.decompress(body)
                elif enc == "deflate":
                    body = zlib.decompress(body)
                elif enc == "zstd":
                    import zstandard

                    body = zstandard.ZstdDecompressor().decompressobj().decompress(body)
                if self.path.endswith("/v1/traces"):
                    from opentelemetry.proto.collector.trace.v1.trace_service_pb2 import (
                        ExportTraceServiceRequest,
                    )

                    req = ExportTraceServiceRequest()
                    req.ParseFromString(body)
                    if outer.delay:
                        time.sleep(outer.delay)
                    with outer.lock:
                        outer.requests += 1
                        for rs in req.resource_spans:
                            res = {a.key: a.value.string_value for a in rs.resource.attributes}
                            for ss in rs.scope_spans:
                                for sp in ss.spans:
                                    outer.spans.append((res, sp))
                self.send_response(200)
                self.send_header("Content-Type", "application/x-protobuf")
                self.end_headers()

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    @property
    def url(self) -> str:
        return f"http://127.0.0.1:{self.server.server_address[1]}"

    def close(self) -> None:
        self.server.shutdown()
        self.server.server_close()
