"""``podtrace install | uninstall | status | control | diff``."""

from __future__ import annotations

import argparse
import json
import sys

from . import __version__, install
from .config import DEFAULT_CONFIG_PATH, DEFAULT_CONTROL_PATH, config_path_from_env
from .control import write_control


def _parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="podtrace", description="Load-time tracing of chosen source files."
    )
    p.add_argument("--version", action="version", version=f"podtrace {__version__}")
    sub = p.add_subparsers(dest="cmd", required=True)

    i = sub.add_parser("install", help="write podtrace.pth into an interpreter's site-packages")
    i.add_argument("--python", required=True, help="the venv's python, e.g. .venv-cu128/bin/python")
    i.add_argument("--config", help="a config file to copy to the config location")
    i.add_argument(
        "--config-dest",
        default=None,
        help=f"where to copy it (default {DEFAULT_CONFIG_PATH})",
    )

    u = sub.add_parser("uninstall", help="remove podtrace.pth")
    u.add_argument("--python", required=True)

    s = sub.add_parser("status", help="report the installation, config and control file")
    s.add_argument("--python", help="also inspect this interpreter's site-packages")
    s.add_argument("--json", action="store_true")

    c = sub.add_parser("control", help="write the control file (turn recording on or off)")
    c.add_argument("state", choices=["on", "off"])
    c.add_argument("--label", help="run label, used in the run directory name")
    c.add_argument(
        "--deep", action="append", default=[], help="qualified-name pattern (repeatable)"
    )
    c.add_argument(
        "--file", help=f"control file (default: from the config, else {DEFAULT_CONTROL_PATH})"
    )

    sub.add_parser(
        "diff", help="compare two runs (arguments go to podtrace.compare)", add_help=False
    )
    return p


def _control_path(explicit: str | None) -> str:
    if explicit:
        return explicit
    try:
        from .config import load

        return load(config_path_from_env()).control_file
    except Exception:
        return DEFAULT_CONTROL_PATH


def _diff(argv: list[str]) -> int:
    try:
        from podtrace import compare
    except ModuleNotFoundError as exc:
        if exc.name != "podtrace.compare":
            raise
        sys.stderr.write("podtrace diff: the comparison tool (podtrace.compare) is not installed\n")
        return 2
    result = compare.main(argv)
    return result if isinstance(result, int) else 0


def main(argv: list[str] | None = None) -> int:
    args_in = list(sys.argv[1:] if argv is None else argv)
    if args_in and args_in[0] == "diff":
        return _diff(args_in[1:])
    args = _parser().parse_args(args_in)
    try:
        if args.cmd == "install":
            for line in install.install(args.python, args.config, args.config_dest):
                print(line)
        elif args.cmd == "uninstall":
            for line in install.uninstall(args.python):
                print(line)
        elif args.cmd == "status":
            info = install.status(args.python)
            if args.json:
                print(json.dumps(info, indent=2))
            else:
                for key, value in info.items():
                    print(f"{key}: {value}")
        elif args.cmd == "control":
            path = _control_path(args.file)
            write_control(path, record=args.state == "on", label=args.label, deep=args.deep)
            print(
                f"wrote {path}: record {args.state}"
                + (f", label {args.label}" if args.label else "")
            )
    except install.InstallError as exc:
        sys.stderr.write(f"podtrace: {exc}\n")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
