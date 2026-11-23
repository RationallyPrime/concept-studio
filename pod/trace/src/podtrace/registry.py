"""Process-wide tables shared by the load-time hook, the transform and the runtime."""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from .config import Config, Rule

# Set by ``podtrace.hook.install``. None means tracing was never activated in this process.
CONFIG: Config | None = None


@dataclass(frozen=True)
class SiteInfo:
    """What the transform knows statically about one decorated ``def`` or ``class``."""

    idx: int
    # "f" function, "g" generator, "c" coroutine, "a" async generator, "C" class
    shape: str
    qualname: str
    lineno: int
    # A ``def`` directly in a class body that is neither a static nor a class method.
    is_method: bool = False
    is_init: bool = False


@dataclass
class FileTable:
    path: str
    sha256: str
    rule: Rule
    sites: list[SiteInfo] = field(default_factory=list)


# Keyed by the file path the loader reported.
TABLES: dict[str, FileTable] = {}
