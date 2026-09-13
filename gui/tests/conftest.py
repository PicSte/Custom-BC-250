"""Test fixtures.

The application is driven against the real bc250ctl from the repository, in a
sandbox prefix with the same mocked system commands the bats suite uses. So
these tests exercise the actual engine — no BC-250, no root, no network.
"""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "gui"))

from bc250_gui.engine import Engine  # noqa: E402


@pytest.fixture
def sandbox(tmp_path, monkeypatch):
    """A prefix the engine can write to, with the mocks in front of PATH."""
    root = tmp_path / "root"
    mock = tmp_path / "mock"
    for sub in (
        "etc/systemd/system", "etc/modprobe.d", "etc/modules-load.d",
        "etc/yum.repos.d", "etc/default", "etc/bc250ctl",
        "usr/local/bin", "var/lib/bc250ctl", "boot", "proc",
        "sys/class/hwmon", "sys/class/drm",
    ):
        (root / sub).mkdir(parents=True, exist_ok=True)
    (mock / "bin").mkdir(parents=True, exist_ok=True)
    for name in ("calls", "rpm-installed", "lsmod", "unit-files"):
        (mock / name).write_text("")
    (mock / "modules-available").write_text("nct6687\n")

    # A BC-250 on card1, six cores.
    dev = root / "sys/bus/pci/devices/0000:01:00.0"
    dev.mkdir(parents=True)
    (dev / "vendor").write_text("0x1002\n")
    (dev / "device").write_text("0x13fe\n")
    (dev / "pp_dpm_sclk").write_text("name\n0: 500Mhz\n1: 1500Mhz *\n")
    card = root / "sys/class/drm/card1"
    card.mkdir(parents=True)
    (card / "device").symlink_to(dev)
    (root / "proc/cpuinfo").write_text("".join(f"processor\t: {i}\n\n" for i in range(12)))

    # Point the pinned-source table at local fixtures, so the suite never
    # reaches the network. The fetch and checksum code under test is the real
    # one; only the URLs are local.
    fixtures = tmp_path / "src"
    fixtures.mkdir()
    lm = REPO / "tests/mocks/bc250-cu-live-manager"
    cst = fixtures / "SSDT-CST.aml"
    pst = fixtures / "SSDT-PST.aml"
    cst.write_text("SSDT-CST fixture\n")
    pst.write_text("SSDT-PST fixture\n")

    def sha(path: Path) -> str:
        import hashlib
        return hashlib.sha256(path.read_bytes()).hexdigest()

    sources = tmp_path / "sources.env"
    sources.write_text(
        f"SRC_CU_LIVE_MANAGER_REPO=file://{REPO}\n"
        f"SRC_CU_LIVE_MANAGER_REF={'1' * 40}\n"
        f"SRC_CU_LIVE_MANAGER_URL=file://{lm}\n"
        f"SRC_CU_LIVE_MANAGER_SHA256={sha(lm)}\n"
        f"SRC_SMU_OC_REPO=file://{REPO}\n"
        f"SRC_SMU_OC_REF={'2' * 40}\n"
        f"SRC_SMU_OC_URL=file://{REPO}\n"
        f"SRC_ACPI_CST_REPO=file://{REPO}\n"
        f"SRC_ACPI_CST_REF={'3' * 40}\n"
        f"SRC_ACPI_CST_URL=file://{cst}\n"
        f"SRC_ACPI_CST_SHA256={sha(cst)}\n"
        f"SRC_ACPI_PST_REPO=file://{REPO}\n"
        f"SRC_ACPI_PST_REF={'3' * 40}\n"
        f"SRC_ACPI_PST_URL=file://{pst}\n"
        f"SRC_ACPI_PST_SHA256={sha(pst)}\n"
    )
    monkeypatch.setenv("BC250_SOURCES_FILE", str(sources))

    monkeypatch.setenv("BC250_PREFIX", str(root))
    monkeypatch.setenv("MOCK_STATE", str(mock))
    monkeypatch.setenv("BC250_ASSUME_YES", "1")
    monkeypatch.setenv(
        "PATH", f"{mock / 'bin'}:{REPO / 'tests/mocks'}:{os.environ['PATH']}"
    )
    return root


@pytest.fixture
def engine(sandbox):
    return Engine(path=str(REPO / "bc250ctl"))


@pytest.fixture
def profile(sandbox):
    """Install a shipped profile as the active configuration."""

    def _apply(name: str) -> None:
        target = sandbox / "etc/bc250ctl/config.env"
        target.write_text((REPO / "profiles" / f"{name}.env").read_text())
        target.chmod(0o600)

    return _apply


@pytest.fixture
def run_engine(sandbox):
    """Call bc250ctl directly, for arranging state a test depends on."""

    def _run(*args: str) -> subprocess.CompletedProcess:
        return subprocess.run(
            [str(REPO / "bc250ctl"), *args], capture_output=True, text=True
        )

    return _run
