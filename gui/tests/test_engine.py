"""The bridge to bc250ctl."""

from __future__ import annotations

import subprocess

import pytest

from bc250_gui.engine import Engine, EngineError, Event, find_bc250ctl


def test_reads_the_catalogue(engine, profile):
    profile("balanced")
    catalog = engine.catalog()
    assert catalog["version"] == 1
    assert {m["id"] for m in catalog["modules"]} >= {"15-acpi", "50-cpu-cores"}


def test_reads_settings_and_telemetry(engine, profile):
    profile("balanced")
    assert engine.config()["values"]["BC250_CPU_CORES"]["value"] == "8"
    assert "gpu" in engine.telemetry()


def test_reads_profiles(engine, profile):
    profile("safe")
    names = {p["name"] for p in engine.profiles()["profiles"]}
    assert names == {"safe", "balanced", "max"}


def test_a_failure_surfaces_the_engine_s_own_explanation(engine, sandbox):
    (sandbox / "etc/bc250ctl/config.env").write_text(
        "BC250_SENSORS=1\nBC250_FAN_CONTROL=1\n"
    )
    with pytest.raises(EngineError) as caught:
        engine._read("status")
    # The message a person sees is the engine's, not a generic wrapper's.
    assert "same chip" in caught.value.message
    assert caught.value.returncode != 0


def test_doctor_reports_rather_than_raising_on_a_broken_config(engine, sandbox):
    (sandbox / "etc/bc250ctl/config.env").write_text(
        "BC250_SENSORS=1\nBC250_FAN_CONTROL=1\n"
    )
    report = engine.doctor()
    assert "INVALID" in report or "same chip" in report


def test_diff_previews_without_writing(engine, profile, sandbox):
    profile("balanced")
    before = (sandbox / "etc/bc250ctl/config.env").read_bytes()

    valid, rendered = engine.config_diff(["BC250_GOV_FREQ_MAX=1600"])
    assert valid
    assert "1500 -> 1600" in rendered
    assert (sandbox / "etc/bc250ctl/config.env").read_bytes() == before


def test_diff_reports_an_invalid_result(engine, profile):
    profile("balanced")
    valid, rendered = engine.config_diff(["BC250_CPU_OC_FREQ=4000"])
    assert not valid
    assert "damage the board" in rendered


def test_missing_binary_says_what_to_do():
    with pytest.raises(EngineError) as caught:
        Engine(path="/nonexistent/bc250ctl").catalog()
    assert "/nonexistent/bc250ctl" in caught.value.message


def test_bad_json_is_an_error_not_a_crash(tmp_path):
    fake = tmp_path / "bc250ctl"
    fake.write_text("#!/bin/sh\necho 'not json'\n")
    fake.chmod(0o755)
    with pytest.raises(EngineError) as caught:
        Engine(path=str(fake)).catalog()
    assert "JSON" in caught.value.message


def test_a_slow_engine_times_out_instead_of_hanging(tmp_path, monkeypatch):
    fake = tmp_path / "bc250ctl"
    fake.write_text("#!/bin/sh\nsleep 30\n")
    fake.chmod(0o755)
    monkeypatch.setattr("bc250_gui.engine.READ_TIMEOUT", 1)
    with pytest.raises(EngineError) as caught:
        Engine(path=str(fake)).catalog()
    assert "répondu" in caught.value.message


def test_privileged_calls_go_through_pkexec_with_the_right_flags(engine):
    argv = engine.privileged_argv(["install", "gpu-cu"])
    assert argv[0] == "pkexec"
    # pkexec drops the environment, so consent and progress must be flags.
    assert "--yes" in argv and "--events" in argv
    assert argv[-2:] == ["install", "gpu-cu"]


class TestEventParsing:
    def test_parses_a_progress_line(self):
        event = Event.parse(
            '@@BC250 {"event": "module-begin", "module": "15-acpi", "text": "x"}'
        )
        assert event == Event("module-begin", "15-acpi", "x")

    def test_ordinary_output_is_not_an_event(self):
        assert Event.parse("==> acpi: doing something") is None

    def test_a_malformed_line_is_ignored_rather_than_fatal(self):
        assert Event.parse("@@BC250 {broken") is None


def test_events_come_back_from_a_real_run(engine, profile, run_engine):
    profile("balanced")
    proc = subprocess.run(
        engine.privileged_argv(["install", "kargs"])[1:],  # skip pkexec: no polkit here
        capture_output=True,
        text=True,
    )
    assert proc.returncode == 0
    events = [Event.parse(ln) for ln in proc.stdout.splitlines()]
    events = [e for e in events if e is not None]
    assert any(e.event == "module-begin" and e.module == "10-kargs" for e in events)
    assert any(e.event == "module-end" and e.text == "ok" for e in events)


def test_find_bc250ctl_prefers_the_repository_copy(monkeypatch):
    monkeypatch.delenv("BC250CTL", raising=False)
    assert find_bc250ctl().endswith("/bc250ctl")


def test_find_bc250ctl_honours_the_override(monkeypatch, tmp_path):
    monkeypatch.setenv("BC250CTL", str(tmp_path / "elsewhere"))
    assert find_bc250ctl() == str(tmp_path / "elsewhere")
