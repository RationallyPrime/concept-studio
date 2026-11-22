"""Configuration: the TOML file, include rules and path globs.

Kept free of imports beyond the standard library so that ``podtrace.bootstrap`` can load it in
every Python process of the traced environment without cost.
"""

from __future__ import annotations

import fnmatch
import os
import re
from dataclasses import dataclass, field
from typing import Any

DEFAULT_CONFIG_PATH = "/workspace/podtrace/config.toml"
DEFAULT_CONTROL_PATH = "/workspace/podtrace/control.json"
DEFAULT_OUT_DIR = "/workspace/podtrace/runs"

STAT_LEVELS = ("full", "basic", "shape")


class ConfigError(ValueError):
    """The configuration file is unusable."""


def glob_to_regex(pattern: str) -> re.Pattern[str]:
    """Translate a path glob to a regex.

    ``*`` and ``?`` stay inside one path segment, ``**/`` spans any number of directories (also
    none) and ``**`` any characters. A pattern that does not start with ``/`` may match any
    trailing part of the path, so ``comfy/samplers.py`` matches ``/opt/ComfyUI/comfy/samplers.py``.
    """
    pattern = pattern.replace("\\", "/")
    out: list[str] = []
    i, n = 0, len(pattern)
    while i < n:
        c = pattern[i]
        if c == "*":
            if pattern.startswith("**", i):
                i += 2
                if pattern.startswith("/", i):
                    i += 1
                    out.append("(?:.*/)?")
                else:
                    out.append(".*")
                continue
            out.append("[^/]*")
        elif c == "?":
            out.append("[^/]")
        else:
            out.append(re.escape(c))
        i += 1
    body = "".join(out)
    prefix = "" if pattern.startswith("/") else "(?:.*/)?"
    return re.compile(prefix + body + r"\Z", re.DOTALL)


def _norm_path(path: str) -> str:
    return os.path.abspath(path).replace("\\", "/")


def name_matches(name: str, patterns: tuple[str, ...]) -> bool:
    return any(fnmatch.fnmatchcase(name, p) for p in patterns)


@dataclass(frozen=True)
class Rule:
    """One ``[[include]]`` table: which file, which qualified names, how much detail."""

    path: str
    names: tuple[str, ...] = ("*",)
    exclude: tuple[str, ...] = ()
    stats: str = "full"
    regex: re.Pattern[str] = field(init=False, repr=False, compare=False)

    def __post_init__(self) -> None:
        if self.stats not in STAT_LEVELS:
            raise ConfigError(f"include {self.path!r}: stats must be one of {STAT_LEVELS}")
        object.__setattr__(self, "regex", glob_to_regex(self.path))

    def matches_path(self, path: str) -> bool:
        return self.regex.match(path) is not None

    def wants(self, qualname: str) -> bool:
        """Whether a function or class with this file-local qualified name is instrumented."""
        return name_matches(qualname, self.names) and not name_matches(qualname, self.exclude)


@dataclass
class Config:
    rules: tuple[Rule, ...] = ()
    argv_glob: tuple[str, ...] = ()
    out_dir: str = DEFAULT_OUT_DIR
    control_file: str = DEFAULT_CONTROL_PATH
    control_poll_s: float = 0.5
    per_parent_cap: int = 10000
    plugins: tuple[str, ...] = ()
    # Record the value of every string, not only those of at most 64 characters.
    text: bool = False
    # How tensors that have no version counter (inference tensors) are cached: "probe" (sampled
    # fingerprint for large ones, recompute for small ones), "full" (always recompute) or
    # "trust" (cache by object identity only).
    inference_check: str = "probe"
    profile_bins: int = 256
    items: int = 4
    dict_items: int = 8
    fields: int = 12
    max_depth: int = 4
    max_nodes: int = 256
    max_tensors: int = 24
    jsonl: bool = True
    logfire: bool = True
    service_name: str = "comfyui"
    credentials_dir: str = ""
    logfire_base_url: str = ""
    logfire_flush_every: int = 20000
    logfire_flush_timeout_s: float = 300.0
    logfire_queue_size: int = 1_000_000
    raw: dict[str, Any] = field(default_factory=dict)
    source: str = ""

    def __post_init__(self) -> None:
        self._match_cache: dict[str, Rule | None] = {}

    def match_file(self, path: str) -> Rule | None:
        """First rule whose path glob matches (as given, or with symlinks resolved)."""
        hit = self._match_cache.get(path, False)
        if hit is not False:
            return hit  # type: ignore[return-value]
        found: Rule | None = None
        candidates = [_norm_path(path)]
        try:
            real = os.path.realpath(path).replace("\\", "/")
            if real != candidates[0]:
                candidates.append(real)
        except OSError:
            pass
        for rule in self.rules:
            if any(rule.matches_path(c) for c in candidates):
                found = rule
                break
        self._match_cache[path] = found
        return found

    def process_matches(self, argv: list[str]) -> bool | None:
        """Whether this process should be traced; None while ``sys.argv`` is not populated yet."""
        if not self.argv_glob:
            return True
        if not argv or (len(argv) == 1 and argv[0] == ""):
            return None
        first = argv[0]
        shapes = {first, _norm_path(first)}
        return any(fnmatch.fnmatchcase(s, g) for s in shapes for g in self.argv_glob)


def _tuple(value: Any, key: str, default: tuple[str, ...]) -> tuple[str, ...]:
    if value is None:
        return default
    if isinstance(value, str):
        return (value,)
    if isinstance(value, (list, tuple)) and all(isinstance(v, str) for v in value):
        return tuple(value)
    raise ConfigError(f"{key} must be a string or a list of strings")


def _typed(table: dict[str, Any], key: str, default: Any, kinds: tuple[type, ...]) -> Any:
    value = table.get(key, default)
    if isinstance(value, bool) and bool not in kinds:
        raise ConfigError(f"{key} must be {' or '.join(k.__name__ for k in kinds)}")
    if not isinstance(value, kinds):
        raise ConfigError(f"{key} must be {' or '.join(k.__name__ for k in kinds)}")
    return value


def from_dict(raw: dict[str, Any], source: str = "") -> Config:
    rules = []
    for i, table in enumerate(raw.get("include", ())):
        if not isinstance(table, dict) or "path" not in table:
            raise ConfigError(f"include #{i + 1} needs a 'path'")
        rules.append(
            Rule(
                path=str(table["path"]),
                names=_tuple(table.get("names"), "names", ("*",)),
                exclude=_tuple(table.get("exclude"), "exclude", ()),
                stats=str(table.get("stats", "full")),
            )
        )
    jsonl = raw.get("jsonl", {})
    lf = raw.get("logfire", {})
    limits = raw.get("summary", {})
    cfg = Config(
        rules=tuple(rules),
        argv_glob=_tuple(raw.get("argv_glob"), "argv_glob", ()),
        out_dir=str(raw.get("out_dir", DEFAULT_OUT_DIR)),
        control_file=str(raw.get("control_file", DEFAULT_CONTROL_PATH)),
        control_poll_s=float(_typed(raw, "control_poll_s", 0.5, (int, float))),
        per_parent_cap=int(_typed(raw, "per_parent_cap", 10000, (int,))),
        plugins=_tuple(raw.get("plugins"), "plugins", ()),
        text=bool(raw.get("text", False)),
        inference_check=str(raw.get("inference_check", "probe")),
        profile_bins=int(_typed(limits, "profile_bins", 256, (int,))),
        items=int(_typed(limits, "items", 4, (int,))),
        dict_items=int(_typed(limits, "dict_items", 8, (int,))),
        fields=int(_typed(limits, "fields", 12, (int,))),
        max_depth=int(_typed(limits, "max_depth", 4, (int,))),
        max_nodes=int(_typed(limits, "max_nodes", 256, (int,))),
        max_tensors=int(_typed(limits, "max_tensors", 24, (int,))),
        jsonl=bool(jsonl.get("enabled", True)),
        logfire=bool(lf.get("enabled", True)),
        service_name=str(lf.get("service_name", "comfyui")),
        credentials_dir=str(lf.get("credentials_dir", "")),
        logfire_base_url=str(lf.get("base_url", "")),
        logfire_flush_every=int(_typed(lf, "flush_every", 20000, (int,))),
        logfire_flush_timeout_s=float(_typed(lf, "flush_timeout_s", 300.0, (int, float))),
        logfire_queue_size=int(_typed(lf, "queue_size", 1_000_000, (int,))),
        raw=raw,
        source=source,
    )
    if cfg.inference_check not in ("probe", "full", "trust"):
        raise ConfigError("inference_check must be 'probe', 'full' or 'trust'")
    if cfg.per_parent_cap < 1:
        raise ConfigError("per_parent_cap must be at least 1")
    return cfg


def load(path: str) -> Config:
    import tomllib

    try:
        with open(path, "rb") as fh:
            raw = tomllib.load(fh)
    except tomllib.TOMLDecodeError as exc:
        raise ConfigError(f"{path}: {exc}") from exc
    return from_dict(raw, source=path)


def config_path_from_env() -> str:
    return os.environ.get("PODTRACE_CONFIG") or DEFAULT_CONFIG_PATH
