import json
import os
import subprocess
import sys

import pytest
import scenario_pkg as sp


@pytest.fixture
def scenario(tmp_path):
    root = tmp_path / "root"
    pkg = root / "e2e_pkg"
    pkg.mkdir(parents=True)
    (pkg / "__init__.py").write_text(sp.INIT)
    (pkg / "helper.py").write_text(sp.HELPER)
    driver = tmp_path / "driver.py"
    driver.write_text(sp.DRIVER)
    out = tmp_path / "runs"
    control = tmp_path / "control.json"
    control.write_text(json.dumps({"record": True, "label": "e2e"}))
    cfg = tmp_path / "config.toml"
    cfg.write_text(
        f'out_dir = "{out}"\ncontrol_file = "{control}"\n[logfire]\nenabled = false\n'
        f'[[include]]\npath = "**/e2e_pkg/**/*.py"\n'
    )

    def run(mode, trace, tag=None):
        env = dict(os.environ)
        env.pop("PODTRACE_CONFIG", None)
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        if trace:
            env["PODTRACE_CONFIG"] = str(cfg)
            env["SCENARIO_TRACE"] = "1"
        proc = subprocess.run(
            [sys.executable, str(driver), mode, str(root)],
            capture_output=True,
            text=True,
            env=env,
            cwd=str(tmp_path),
            timeout=120,
        )
        assert proc.returncode == 0, proc.stderr
        return proc

    def latest_run():
        dirs = sorted(out.iterdir(), key=lambda p: p.stat().st_mtime_ns)
        return dirs[-1]

    def records(run_dir):
        return [json.loads(x) for x in (run_dir / "records.jsonl").read_text().splitlines()]

    class S:
        pass

    s = S()
    s.run, s.latest_run, s.records, s.out, s.root = run, latest_run, records, out, root
    return s


def normalize(recs):
    """Drop wall-clock values and span ids; keep parent links as seq numbers."""
    by_id = {r["span_id"]: r["seq"] for r in recs}
    rows = []
    for r in sorted(recs, key=lambda r: r["seq"]):
        row = {
            k: v
            for k, v in r.items()
            if k not in ("start_ns", "end_ns", "trace_id", "span_id", "parent_id", "file")
        }
        row["parent"] = by_id.get(r["parent_id"])
        rows.append(row)
    return rows


@pytest.mark.parametrize("mode", ["import", "spec"])
def test_output_is_identical_with_tracing_on_and_off(scenario, mode):
    off = scenario.run(mode, trace=False)
    on = scenario.run(mode, trace=True)
    assert on.stdout == off.stdout
    assert on.stderr == "" or "UserWarning" in on.stderr, on.stderr
    assert json.loads(on.stdout)["total"] == 18.0


@pytest.mark.parametrize("mode", ["import", "spec"])
def test_records_describe_the_run(scenario, mode):
    scenario.run(mode, trace=True)
    run_dir = scenario.latest_run()
    recs = scenario.records(run_dir)
    assert (run_dir / "meta.json").exists()
    prefix = "e2e_pkg" if mode == "import" else "my-pack v2!"
    names = {r["name"] for r in recs}
    for expected in [
        f"{prefix}.run",
        f"{prefix}.make_scaler",
        f"{prefix}.make_scaler.<locals>.scale",
        f"{prefix}.make_scaler.<locals>.scale.<locals>.one",
        f"{prefix}.Accumulator.__init__",
        f"{prefix}.Accumulator.add",
        f"{prefix}.Accumulator.mean",
        f"{prefix}.Accumulator.clamp",
        f"{prefix}.Accumulator.default",
        f"{prefix}.Settings.__init__",
        f"{prefix}.Mode.label",
        f"{prefix}.timer",
        f"{prefix}.numbers",
        f"{prefix}.write_in_place",
        f"{prefix}.fails",
        f"{prefix}.helper.double",
    ]:
        assert expected in names, expected
    roots = [r for r in recs if r["parent_id"] is None]
    assert [r["name"] for r in roots] == [f"{prefix}.run"]
    by_id = {r["span_id"]: r for r in recs}
    assert all(r["parent_id"] in by_id or r["parent_id"] is None for r in recs)
    assert all(by_id[r["parent_id"]]["seq"] < r["seq"] for r in recs if r["parent_id"])
    assert len({r["trace_id"] for r in recs}) == 1
    assert len({r["seq"] for r in recs}) == len(recs)
    kinds = {r["name"].rsplit(".", 1)[-1]: r["kind"] for r in recs}
    assert kinds["numbers"] == "gen" and kinds["timer"] == "gen" and kinds["__init__"] == "init"
    nested = {r["name"]: by_id[r["parent_id"]]["name"] for r in recs if r["parent_id"]}
    assert nested[f"{prefix}.make_scaler.<locals>.scale.<locals>.one"].endswith("scale")
    # the raising function
    (bad,) = [r for r in recs if r["exc"]]
    assert bad["name"].endswith(".fails") and bad["exc"] == {
        "type": "ValueError",
        "msg": "bad value",
    }
    # state: self mutation, in-place array write, init attributes
    add = next(r for r in recs if r["name"].endswith("Accumulator.add"))
    attrs = {s["attr"] for s in add["state"]}
    assert {"total", "log"} <= attrs
    write = next(r for r in recs if r["name"].endswith(".write_in_place"))
    (entry,) = write["state"]
    assert entry["target"] == "arg:arr" and entry["before"]["fp"] != entry["after"]["fp"]
    assert entry["before"]["id"] == entry["after"]["id"]
    init = next(r for r in recs if r["name"].endswith("Accumulator.__init__"))
    assert {s["attr"] for s in init["state"]} == {"settings", "total", "log", "buffer"}
    # the file path is the real one, keyed on path not on module name
    assert all(r["file"].startswith(str(scenario.root)) for r in recs)
    # no bytecode was cached for instrumented files
    assert not list(scenario.root.rglob("*.pyc"))


@pytest.mark.parametrize("mode", ["import", "spec"])
def test_two_runs_give_identical_records_and_aliases(scenario, mode):
    scenario.run(mode, trace=True)
    first = normalize(scenario.records(scenario.latest_run()))
    scenario.run(mode, trace=True)
    second_dir = scenario.latest_run()
    second = normalize(scenario.records(second_dir))
    assert len(first) == len(second) > 20
    for a, b in zip(first, second, strict=True):
        assert a == b, (a["name"], b["name"])


def test_tensors_in_the_scenario_when_torch_is_available(scenario):
    pytest.importorskip("torch")
    scenario.run("import", trace=True)
    recs = scenario.records(scenario.latest_run())
    touch = [r for r in recs if r["name"].endswith("helper.touch")]
    assert len(touch) == 2
    normal, inference = touch
    assert normal["state"] and inference["state"]
    assert normal["args"]["t"]["shape"] == [1, 2, 3, 4, 1] and "profile" in normal["args"]["t"]
    assert normal["args"]["t"]["profile"]["axis"] == 2
    assert inference["args"]["t"]["inference"] is True
    assert inference["state"][0]["after"]["mean"] == 2.0
