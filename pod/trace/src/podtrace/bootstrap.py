"""Entry point of ``podtrace.pth``. Must never stop the host program from starting.

Does nothing unless a config file is found (``PODTRACE_CONFIG``, else
``/workspace/podtrace/config.toml``); ``PODTRACE_DISABLE=1`` switches it off outright. Everything
heavier than ``os`` and ``sys`` is imported only after a config file exists.
"""

import os
import sys


def _activate() -> None:
    if os.environ.get("PODTRACE_DISABLE"):
        return
    path = os.environ.get("PODTRACE_CONFIG") or "/workspace/podtrace/config.toml"
    if not os.path.isfile(path):
        return
    from podtrace import config, hook

    hook.install(config.load(path))


try:
    _activate()
except Exception as _exc:
    try:  # noqa: SIM105
        sys.stderr.write(f"podtrace: not active: {type(_exc).__name__}: {_exc}\n")
    except Exception:
        pass
