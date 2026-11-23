import json
import os
import time

import pytest

from podtrace import config
from podtrace.config import ConfigError, glob_to_regex
from podtrace.control import Control, write_control


@pytest.mark.parametrize(
    ("pattern", "path", "ok"),
    [
        ("comfy/samplers.py", "/opt/ComfyUI/comfy/samplers.py", True),
        ("comfy/samplers.py", "/opt/ComfyUI/mycomfy/samplers.py", False),
        ("**/comfy/ldm/minimax/*.py", "/a/b/comfy/ldm/minimax/model.py", True),
        ("**/comfy/ldm/minimax/*.py", "/a/comfy/ldm/minimax/sub/model.py", False),
        ("**/ComfyUI-H3Forge/**/*.py", "/w/custom_nodes/ComfyUI-H3Forge/h3forge/x.py", True),
        ("**/ComfyUI-H3Forge/**/*.py", "/w/custom_nodes/ComfyUI-H3Forge/__init__.py", True),
        ("**/ComfyUI-H3Forge/**/*.py", "/w/custom_nodes/Other/x.py", False),
        ("/abs/only/*.py", "/abs/only/x.py", True),
        ("/abs/only/*.py", "/x/abs/only/x.py", False),
        ("x?.py", "/p/xa.py", True),
        ("x?.py", "/p/xab.py", False),
    ],
)
def test_glob(pattern, path, ok):
    assert bool(glob_to_regex(pattern).match(path)) is ok


def test_first_matching_rule_wins_and_names_filter():
    cfg = config.from_dict(
        {
            "include": [
                {"path": "**/vae.py", "stats": "basic"},
                {"path": "**/*.py", "names": ["A", "A.*"], "exclude": ["A.hidden"]},
            ]
        }
    )
    assert cfg.match_file("/x/vae.py").stats == "basic"
    rule = cfg.match_file("/x/other.py")
    assert (
        rule.stats == "full"
        and rule.wants("A.run")
        and not rule.wants("A.hidden")
        and not rule.wants("B")
    )
    assert config.from_dict({}).match_file("/x/y.py") is None


def test_bad_configs_are_rejected():
    with pytest.raises(ConfigError):
        config.from_dict({"include": [{"names": ["x"]}]})
    with pytest.raises(ConfigError):
        config.from_dict({"include": [{"path": "x", "stats": "lots"}]})
    with pytest.raises(ConfigError):
        config.from_dict({"inference_check": "maybe"})
    with pytest.raises(ConfigError):
        config.from_dict({"per_parent_cap": 0})


def test_load_toml_and_defaults(tmp_path):
    p = tmp_path / "c.toml"
    p.write_text(
        'argv_glob = ["*/main.py"]\n[logfire]\nservice_name = "x"\n[[include]]\npath = "a.py"\n'
    )
    cfg = config.load(str(p))
    assert cfg.service_name == "x" and cfg.per_parent_cap == 10000 and cfg.jsonl and cfg.logfire
    assert cfg.control_file == "/workspace/podtrace/control.json"
    p.write_text("not toml [")
    with pytest.raises(ConfigError):
        config.load(str(p))


def test_process_filter_defers_while_argv_is_not_populated():
    cfg = config.from_dict({"argv_glob": ["*/ComfyUI/main.py", "main.py"]})
    assert cfg.process_matches([]) is None and cfg.process_matches([""]) is None
    assert cfg.process_matches(["main.py"]) is True
    assert cfg.process_matches(["/opt/ComfyUI/main.py"]) is True
    assert cfg.process_matches(["/usr/bin/pip"]) is False
    assert config.from_dict({}).process_matches([]) is True


def test_control_file_is_reread_when_it_changes(tmp_path):
    path = tmp_path / "control.json"
    ctl = Control(str(path))
    assert ctl.refresh() is False and ctl.record is False
    write_control(str(path), record=True, label="broken", deep=["*ctx*"])
    assert ctl.refresh() is True
    assert (ctl.record, ctl.label, ctl.deep, ctl.session, ctl.deep_gen) == (
        True,
        "broken",
        ("*ctx*",),
        1,
        1,
    )
    assert ctl.refresh() is False
    write_control(str(path), record=True, label="clean", deep=["*ctx*"])
    os.utime(path, ns=(time.time_ns(), time.time_ns() + 5_000_000))
    ctl.refresh()
    assert ctl.label == "clean" and ctl.session == 1 and ctl.deep_gen == 1
    write_control(str(path), record=False, label=None, deep=[])
    os.utime(path, ns=(time.time_ns(), time.time_ns() + 9_000_000))
    ctl.refresh()
    assert ctl.record is False
    write_control(str(path), record=True, label="again", deep=[])
    os.utime(path, ns=(time.time_ns(), time.time_ns() + 12_000_000))
    ctl.refresh()
    assert ctl.session == 2


def test_control_file_errors_keep_the_previous_setting(tmp_path):
    path = tmp_path / "control.json"
    path.write_text('{"record": true, "label": "a"}')
    ctl = Control(str(path))
    ctl.refresh()
    assert ctl.record
    path.write_text('{"record": tr')  # half-written
    os.utime(path, ns=(time.time_ns(), time.time_ns() + 3_000_000))
    ctl.refresh()
    assert ctl.record and ctl.error
    path.write_text('{"record": false}')
    os.utime(path, ns=(time.time_ns(), time.time_ns() + 6_000_000))
    ctl.refresh()
    assert not ctl.record and ctl.error is None
    path.unlink()
    ctl.record = True
    ctl.refresh()
    assert ctl.record is False  # no file means off


def test_runtime_follows_the_control_file_without_a_restart(h):
    h.start()
    m = h.module("def f(): return 1\n")
    m.f()
    h.record(False)
    for _ in range(3):
        m.f()
    h.record(True, label="later")
    m.f()
    assert len(h.run_dirs()) == 2
    assert len(h.records(0)) == 1 and len(h.records(1)) == 1


def test_background_poller_flips_recording_on(h):
    from podtrace import runtime

    h.start()
    h.record(False)
    m = h.module("def f(): return 1\n")
    assert runtime.state.on is False
    h.control.write_text(json.dumps({"record": True, "label": "x"}))
    deadline = time.time() + 5
    while not runtime.state.on and time.time() < deadline:
        time.sleep(0.02)
    assert runtime.state.on
    m.f()
    assert len(h.records()) == 1
