"""Run the real startup shell against process stubs, without a privileged SSH daemon."""

import os
import subprocess
from pathlib import Path

import pytest

ENTRYPOINT = Path(__file__).resolve().parents[2] / "images/entrypoint.sh"


@pytest.mark.parametrize("with_key", [False, True])
def test_optional_key_only_ssh_preserves_tini_agent_start(tmp_path, with_key):
    commands = tmp_path / "commands"
    commands.mkdir()
    calls = tmp_path / "calls"
    for name in ("tini", "ssh-keygen", "sshd"):
        executable = commands / name
        executable.write_text('#!/bin/sh\nprintf "%s %s\\n" "${0##*/}" "$*" >> "$CALLS"\n')
        executable.chmod(0o755)
    ssh = tmp_path / "ssh"
    script = (
        ENTRYPOINT.read_text()
        .replace("/root/.ssh", str(ssh))
        .replace("/run/sshd", str(tmp_path / "run"))
    )
    script = script.replace("/usr/sbin/sshd", str(commands / "sshd"))
    startup = tmp_path / "entrypoint.sh"
    startup.write_text(script)
    key = "ssh-ed25519 synthetic-public-key test-only"
    env = {
        **os.environ,
        "PATH": str(commands) + os.pathsep + os.environ["PATH"],
        "CALLS": str(calls),
        "PODAGENT_WORKSPACE": str(tmp_path / "workspace"),
        "PUBLIC_KEY": key if with_key else "",
    }
    subprocess.run(["bash", str(startup)], env=env, check=True, capture_output=True)
    logged = calls.read_text().splitlines()
    assert (
        logged[-1]
        == "tini -s -- /opt/venvs/agent/bin/python -m podagent --host 0.0.0.0 --port 8800"
    )
    if with_key:
        assert (ssh / "authorized_keys").read_text() == key + "\n"
        assert (ssh.stat().st_mode & 0o777) == 0o700
        assert ((ssh / "authorized_keys").stat().st_mode & 0o777) == 0o600
        daemon = next(call for call in logged if call.startswith("sshd "))
        assert "PasswordAuthentication=no" in daemon
        assert "KbdInteractiveAuthentication=no" in daemon
        assert "AuthenticationMethods=publickey" in daemon
        assert "ssh-keygen -A" in logged
    else:
        assert not ssh.exists()
        assert len(logged) == 1
