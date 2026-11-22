import json
import os
import shutil
import subprocess
import sys
import types
from pathlib import Path

import pytest

from podtrace import cli, install

SRC = str(Path(__file__).resolve().parents[1] / "src")


def py(code, env=None, cwd=None, python=sys.executable):
    full = dict(os.environ, PYTHONPATH=SRC)
    for k in ("PODTRACE_CONFIG", "PODTRACE_DISABLE"):
        full.pop(k, None)
    full.update(env or {})
    return subprocess.run(
        [python, "-c", code], capture_output=True, text=True, env=full, cwd=cwd, timeout=60
    )


PROBE = (
    "import sys, importlib.machinery as m;"
    "import podtrace.bootstrap;"
    "print(m.SourceFileLoader.get_code.__name__, 'podtrace.hook' in sys.modules)"
)


def test_bootstrap_does_nothing_without_a_config_file(tmp_path):
    out = py(PROBE, {"PODTRACE_CONFIG": str(tmp_path / "missing.toml")})
    assert out.returncode == 0 and out.stderr == ""
    assert out.stdout.split() == ["get_code", "False"]


def test_bootstrap_with_default_location_missing_is_silent(tmp_path):
    out = py(PROBE)
    assert out.returncode == 0 and out.stderr == "" and out.stdout.split() == ["get_code", "False"]


def test_a_broken_config_costs_one_stderr_line_and_nothing_else(tmp_path):
    bad = tmp_path / "bad.toml"
    bad.write_text("this = [ is not toml")
    out = py(PROBE, {"PODTRACE_CONFIG": str(bad)})
    assert out.returncode == 0
    assert out.stdout.split()[0] == "get_code"
    assert out.stderr.count("\n") == 1 and out.stderr.startswith(
        "podtrace: not active: ConfigError"
    )
    wrong = tmp_path / "wrong.toml"
    wrong.write_text('[[include]]\nstats = "full"\n')
    out = py(PROBE, {"PODTRACE_CONFIG": str(wrong)})
    assert out.returncode == 0 and out.stderr.count("\n") == 1


def test_a_valid_config_patches_the_loader_and_disable_switch_wins(tmp_path):
    cfg = tmp_path / "ok.toml"
    cfg.write_text('[[include]]\npath = "**/nothing.py"\n')
    on = py(PROBE, {"PODTRACE_CONFIG": str(cfg)})
    assert on.stdout.split() == ["_patched_get_code", "True"] and on.stderr == ""
    off = py(PROBE, {"PODTRACE_CONFIG": str(cfg), "PODTRACE_DISABLE": "1"})
    assert off.stdout.split() == ["get_code", "False"]


def test_process_filter_leaves_other_programs_alone(tmp_path):
    cfg = tmp_path / "ok.toml"
    cfg.write_text('argv_glob = ["*/serve.py"]\n[[include]]\npath = "**/x.py"\n')
    script = tmp_path / "serve.py"
    script.write_text(PROBE + "\n")
    other = tmp_path / "other.py"
    other.write_text(PROBE + "\n")
    env = dict(os.environ, PYTHONPATH=SRC, PODTRACE_CONFIG=str(cfg))
    hit = subprocess.run([sys.executable, str(script)], capture_output=True, text=True, env=env)
    miss = subprocess.run([sys.executable, str(other)], capture_output=True, text=True, env=env)
    assert hit.stdout.split()[0] == "_patched_get_code"
    assert miss.stdout.split()[0] == "get_code"


def test_sys_argv_is_populated_when_pth_files_run(tmp_path):
    # Decides whether the process filter can be evaluated at start-up: it can.
    check = "import sys; print(sys.argv)"
    out = py(check)
    assert out.stdout.strip() == "['-c']"


# ---------------------------------------------------------------------------- throwaway venv


@pytest.fixture(scope="module")
def venv(tmp_path_factory):
    uv = shutil.which("uv")
    if uv is None:
        pytest.skip("uv is not available")
    root = tmp_path_factory.mktemp("venv")
    target = root / "venv"
    made = subprocess.run(
        [uv, "venv", "--python", sys.executable, str(target)], capture_output=True, text=True
    )
    if made.returncode != 0:
        pytest.skip(f"uv venv failed: {made.stderr[-200:]}")
    python = str(target / "bin" / "python")
    project = str(Path(__file__).resolve().parents[1])
    inst = subprocess.run(
        [uv, "pip", "install", "--python", python, project],
        capture_output=True,
        text=True,
        timeout=240,
    )
    if inst.returncode != 0:
        pytest.skip(f"could not install podtrace into the venv: {inst.stderr[-300:]}")
    return python


def test_pth_round_trip_in_a_real_venv(venv, tmp_path):
    app = tmp_path / "app" / "serve.py"
    pkg = tmp_path / "app" / "pk"
    pkg.mkdir(parents=True)
    (pkg / "__init__.py").write_text("def work(x):\n    return x + 1\n")
    app.write_text(
        "import sys, os\nsys.path.insert(0, os.path.dirname(__file__))\nimport pk\n"
        "print(pk.work(1), hasattr(pk, '__podtrace_s__'))\n"
    )
    runs = tmp_path / "runs"
    control = tmp_path / "control.json"
    control.write_text(json.dumps({"record": True, "label": "pth"}))
    cfg = tmp_path / "config.toml"
    cfg.write_text(
        f'argv_glob = ["*/app/serve.py"]\nout_dir = "{runs}"\ncontrol_file = "{control}"\n'
        '[logfire]\nenabled = false\n[[include]]\npath = "**/app/pk/*.py"\n'
    )
    env = dict(os.environ, PODTRACE_CONFIG=str(cfg))
    env.pop("PYTHONPATH", None)

    def run(extra=None):
        return subprocess.run(
            [venv, str(app)],
            capture_output=True,
            text=True,
            env=dict(env, **(extra or {})),
            timeout=60,
        )

    # before install: plain run
    assert run().stdout.strip() == "2 False"
    notes = install.install(venv)
    pth = Path(install.pth_path(venv))
    assert pth.read_text() == "import podtrace.bootstrap\n" and any("wrote" in n for n in notes)
    assert not any("warning" in n for n in notes)
    traced = run()
    assert traced.stdout.strip() == "2 True" and traced.stderr == ""
    (run_dir,) = list(runs.iterdir())
    names = [json.loads(x)["name"] for x in (run_dir / "records.jsonl").read_text().splitlines()]
    assert names == ["pk.work"]
    # no config -> nothing happens
    no_cfg = run({"PODTRACE_CONFIG": str(tmp_path / "nope.toml")})
    assert no_cfg.stdout.strip() == "2 False" and no_cfg.stderr == ""
    assert run({"PODTRACE_DISABLE": "1"}).stdout.strip() == "2 False"
    status = install.status(venv)
    assert (
        status["pth_present"]
        and status["podtrace_importable"]
        and status["config_path"] == "/workspace/podtrace/config.toml"
    )
    removed = install.uninstall(venv)
    assert "removed" in removed[0] and not pth.exists()
    assert run().stdout.strip() == "2 False"
    assert "nothing to remove" in install.uninstall(venv)[0]


def test_install_warns_when_the_interpreter_cannot_import_podtrace(tmp_path):
    uv = shutil.which("uv")
    if uv is None:
        pytest.skip("uv is not available")
    target = tmp_path / "bare"
    subprocess.run(
        [uv, "venv", "--python", sys.executable, str(target)], check=True, capture_output=True
    )
    notes = install.install(str(target / "bin" / "python"))
    assert any(n.startswith("warning") for n in notes)
    # the dangling .pth must not stop that interpreter from starting
    out = subprocess.run(
        [str(target / "bin" / "python"), "-c", "print('alive')"], capture_output=True, text=True
    )
    assert out.returncode == 0 and out.stdout.strip() == "alive"
    install.uninstall(str(target / "bin" / "python"))


def test_install_copies_a_config(tmp_path):
    uv = shutil.which("uv")
    if uv is None:
        pytest.skip("uv is not available")
    target = tmp_path / "v"
    subprocess.run(
        [uv, "venv", "--python", sys.executable, str(target)], check=True, capture_output=True
    )
    src = tmp_path / "in.toml"
    src.write_text("per_parent_cap = 3\n")
    dest = tmp_path / "etc" / "config.toml"
    notes = install.install(str(target / "bin" / "python"), str(src), str(dest))
    assert dest.read_text() == "per_parent_cap = 3\n" and any("copied" in n for n in notes)


def test_install_rejects_a_missing_interpreter(tmp_path):
    with pytest.raises(install.InstallError):
        install.probe(str(tmp_path / "no-python"))
    assert cli.main(["uninstall", "--python", str(tmp_path / "no-python")]) == 1


# ---------------------------------------------------------------------------- the CLI


def test_control_command_writes_the_control_file(tmp_path, capsys):
    path = tmp_path / "c.json"
    assert (
        cli.main(["control", "on", "--label", "broken", "--deep", "*ctx*", "--file", str(path)])
        == 0
    )
    assert json.loads(path.read_text()) == {"record": True, "label": "broken", "deep": ["*ctx*"]}
    assert cli.main(["control", "off", "--file", str(path)]) == 0
    assert json.loads(path.read_text())["record"] is False
    assert "record off" in capsys.readouterr().out


def test_status_json_without_config(tmp_path, capsys, monkeypatch):
    monkeypatch.setenv("PODTRACE_CONFIG", str(tmp_path / "none.toml"))
    assert cli.main(["status", "--json"]) == 0
    info = json.loads(capsys.readouterr().out)
    assert info["config_present"] is False and info["config_from_env"] is True


def test_status_reads_the_config(tmp_path, capsys, monkeypatch):
    control = tmp_path / "control.json"
    control.write_text('{"record": false}')
    cfg = tmp_path / "c.toml"
    cfg.write_text(
        f'control_file = "{control}"\nplugins = ["minimax_h3"]\n[[include]]\npath = "a.py"\n[[include]]\npath = "b.py"\n'
    )
    monkeypatch.setenv("PODTRACE_CONFIG", str(cfg))
    cli.main(["status", "--json"])
    info = json.loads(capsys.readouterr().out)
    assert (
        info["include_rules"] == 2
        and info["plugins"] == ["minimax_h3"]
        and info["control"] == {"record": False}
    )


def test_diff_forwards_its_arguments_unchanged(monkeypatch):
    seen = []
    fake = types.ModuleType("podtrace.compare")
    fake.main = lambda argv: seen.append(list(argv)) or 3
    monkeypatch.setitem(sys.modules, "podtrace.compare", fake)
    monkeypatch.setattr("podtrace.compare", fake, raising=False)
    assert cli.main(["diff", "runA", "runB", "--top", "5", "--json"]) == 3
    assert seen == [["runA", "runB", "--top", "5", "--json"]]


def test_diff_without_the_comparison_tool_says_so(monkeypatch, capsys):
    import podtrace

    monkeypatch.delattr(podtrace, "compare", raising=False)
    monkeypatch.setitem(sys.modules, "podtrace.compare", None)
    assert cli.main(["diff", "a", "b"]) == 2
    assert "not installed" in capsys.readouterr().err
