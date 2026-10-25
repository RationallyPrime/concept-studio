#!/usr/bin/env bash
# Pod entrypoint (POD-SPEC §6.2): prepare storage, optional key-only SSH, then start the agent.
set -euo pipefail

WORKSPACE="${PODAGENT_WORKSPACE:-/workspace}"
mkdir -p "$WORKSPACE/datasets" "$WORKSPACE/runs" "$WORKSPACE/models/hf-cache" "$WORKSPACE/logs"
export HF_HOME="${HF_HOME:-$WORKSPACE/models/hf-cache}"

# RunPod's full-SSH convention: PUBLIC_KEY and an exposed 22/tcp port. No key means no listener.
if [[ -n "${PUBLIC_KEY:-}" ]]; then
    mkdir -p /root/.ssh /run/sshd
    chmod 700 /root/.ssh
    printf '%s\n' "$PUBLIC_KEY" > /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
    ssh-keygen -l -f /root/.ssh/authorized_keys > /dev/null
    ssh-keygen -A
    /usr/sbin/sshd \
        -o AuthorizedKeysFile=/root/.ssh/authorized_keys \
        -o AllowUsers=root \
        -o PubkeyAuthentication=yes \
        -o PasswordAuthentication=no \
        -o KbdInteractiveAuthentication=no \
        -o PermitRootLogin=prohibit-password \
        -o AuthenticationMethods=publickey
fi

# PODAGENT_TOKEN is checked by the agent itself; it exits 2 with a message when unset.
#
# tini is PID 1 (-s: subreaper), with the agent as its primary child and optional daemonised sshd.
# The supervisor tracks each GPU service
# by its process group and probes the group with killpg(pgid, 0), which stays true while any
# member exists, zombies included: orphans left by a crashed wrapper or vLLM API server must be
# reaped by init, or their GPUs would never be released. tini forwards SIGTERM to the agent.
exec tini -s -- /opt/venvs/agent/bin/python -m podagent --host 0.0.0.0 --port 8800
