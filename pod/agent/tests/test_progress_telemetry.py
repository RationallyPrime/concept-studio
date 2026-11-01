from datetime import UTC, datetime
from pathlib import Path

from podagent.gpus import FakeBackend, InventoryUnavailable
from podagent.progress_telemetry import ProgressReporter, read_progress
from podagent.supervisor import ServiceState, Supervisor


def test_progress_rate_staleness_and_restart(settings, monkeypatch, caplog):
    state = ServiceState(
        name="trainer-aitoolkit",
        state="running",
        run_id="run1",
        gpus=[0],
        started_at=datetime.now(UTC),
    )
    supervisor = Supervisor(settings, FakeBackend(1))
    monkeypatch.setattr(supervisor, "states", lambda: [state])
    points = iter([(10, 0.25, 0.001), (20, 0.30, 0.001), (20, 0.30, 0.001), (2, 0.3, 0.001)])
    monkeypatch.setattr("podagent.progress_telemetry.read_progress", lambda path: next(points))
    clock = iter([100, 120, 400, 420])
    monkeypatch.setattr("podagent.progress_telemetry.time.monotonic", lambda: next(clock))
    reporter = ProgressReporter(supervisor)
    with caplog.at_level("INFO", logger="podagent.progress"):
        for _ in range(4):
            reporter.collect()
    records = caplog.records
    assert records[0].progress_status == "unknown" and records[0].seconds_per_step is None
    assert records[1].progress_status == "current" and records[1].seconds_per_step == 2
    assert records[2].progress_status == "stale" and records[2].seconds_per_step is None
    assert records[3].step == 2 and records[3].seconds_per_step is None
    assert records[0].gpu_memory_total_mib == 81920
    assert all(not hasattr(record, "logdir") for record in records)


def test_gpu_unavailable_is_not_zero(settings, monkeypatch, caplog):
    supervisor = Supervisor(settings, FakeBackend(1))
    state = ServiceState(
        name="trainer-ltx", state="running", run_id="run1", gpus=[0], started_at=datetime.now(UTC)
    )
    monkeypatch.setattr(supervisor, "states", lambda: [state])

    def unavailable():
        raise InventoryUnavailable("private detail")

    monkeypatch.setattr(supervisor.backend, "list_gpus", unavailable)
    monkeypatch.setattr("podagent.progress_telemetry.read_progress", lambda path: None)
    with caplog.at_level("INFO", logger="podagent.progress"):
        ProgressReporter(supervisor).collect()
    assert caplog.records[-1].gpu_memory_used_mib is None
    assert "private detail" not in caplog.text


def test_bounded_progress_parser_uses_training_bars_only(tmp_path: Path):
    log = tmp_path / "trainer.log"
    log.write_text("dataset: 99/100 [00:01]\ntrain: 12/7000 [00:04, lr: 1e-4 loss: 0.2]\n")
    assert read_progress(log) == (12, 0.2, 0.0001)
    log.write_text("dataset: 99/100 [00:01]\n")
    assert read_progress(log) is None


def test_bad_checkpoint_does_not_block_another_run(settings, monkeypatch, caplog):
    from podagent.errors import NotFound

    supervisor = Supervisor(settings, FakeBackend(2))
    started = datetime.now(UTC)
    finished = ServiceState(name="trainer-ltx", state="exited", run_id="bad", started_at=started)
    running = ServiceState(
        name="trainer-aitoolkit", state="running", run_id="good", gpus=[0], started_at=started
    )
    monkeypatch.setattr(supervisor, "states", lambda: [finished, running])
    monkeypatch.setattr("podagent.progress_telemetry.read_progress", lambda path: None)

    def bad_checkpoint(run_dir, trainer, run_id):
        if run_id == "bad":
            raise NotFound("private path")
        return None

    monkeypatch.setattr("podagent.progress_telemetry.latest_checkpoint", bad_checkpoint)
    with caplog.at_level("INFO", logger="podagent.progress"):
        ProgressReporter(supervisor).collect()
    assert any(record.run_id == "good" for record in caplog.records)
    assert "private path" not in caplog.text


def test_final_checkpoint_requires_complete_file(settings, monkeypatch, caplog):
    import json
    import struct
    from datetime import timedelta

    supervisor = Supervisor(settings, FakeBackend(1))
    started = datetime.now(UTC) - timedelta(seconds=5)
    state = ServiceState(
        name="trainer-aitoolkit", state="exited", run_id="run1", started_at=started
    )
    monkeypatch.setattr(supervisor, "states", lambda: [state])
    settings.paths.workspace.mkdir(parents=True, exist_ok=True)
    checkpoint = settings.paths.workspace / "weights.safetensors"
    header = json.dumps({"tensor": {"data_offsets": [0, 4]}}).encode()
    checkpoint.write_bytes(struct.pack("<Q", len(header)) + header + b"12")
    monkeypatch.setattr("podagent.progress_telemetry.latest_checkpoint", lambda *args: checkpoint)
    with caplog.at_level("INFO", logger="podagent.progress"):
        ProgressReporter(supervisor).collect()
        assert not caplog.records
        checkpoint.write_bytes(struct.pack("<Q", len(header)) + header + b"1234")
        ProgressReporter(supervisor).collect()
    assert caplog.records[-1].getMessage() == "checkpoint observed"
    assert caplog.records[-1].step is None


def test_malformed_terminal_checkpoint_does_not_block_running_trainer(
    settings, monkeypatch, tmp_path, caplog
):
    import json
    import struct
    from datetime import timedelta

    supervisor = Supervisor(settings, FakeBackend(1))
    started = datetime.now(UTC) - timedelta(seconds=5)
    finished = ServiceState(name="trainer-ltx", state="exited", run_id="bad", started_at=started)
    running = ServiceState(
        name="trainer-aitoolkit", state="running", run_id="good", gpus=[0], started_at=started
    )
    monkeypatch.setattr(supervisor, "states", lambda: [finished, running])
    monkeypatch.setattr("podagent.progress_telemetry.read_progress", lambda path: None)
    file = tmp_path / "invalid.safetensors"
    header = json.dumps({"tensor": {"data_offsets": []}}).encode()
    file.write_bytes(struct.pack("<Q", len(header)) + header)
    monkeypatch.setattr(
        "podagent.progress_telemetry.latest_checkpoint",
        lambda run_dir, trainer, run_id: file if run_id == "bad" else None,
    )
    with caplog.at_level("INFO", logger="podagent.progress"):
        ProgressReporter(supervisor).collect()
    assert any(record.run_id == "good" for record in caplog.records)
