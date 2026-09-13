"""The interface itself.

Widgets need a display, so these skip cleanly where there is none — the rest
of the suite still runs. What they check is the thing most likely to rot: that
the generated form keeps up with the engine's schema, and that the voltage
ceiling shown is the one the engine will accept.
"""

from __future__ import annotations

import pytest

gtk = pytest.importorskip("gi", reason="PyGObject absent")

import gi  # noqa: E402

try:
    gi.require_version("Gtk", "4.0")
    gi.require_version("Adw", "1")
    from gi.repository import Adw, Gtk
except ValueError as exc:  # pragma: no cover - depends on the host
    pytest.skip(f"GTK4/libadwaita absent: {exc}", allow_module_level=True)

if not Gtk.init_check():  # pragma: no cover - depends on the host
    pytest.skip("aucun affichage disponible", allow_module_level=True)

Adw.init()

from bc250_gui.model import Catalog, Settings, State  # noqa: E402
from bc250_gui.pages.dashboard import DashboardPage  # noqa: E402
from bc250_gui.pages.monitor import MonitorPage  # noqa: E402
from bc250_gui.pages.settings import SettingsPage  # noqa: E402
from bc250_gui.pages.setup import SetupPage  # noqa: E402
from bc250_gui.widgets.badges import risk_badge, state_badge  # noqa: E402


class FakeWindow:
    """Stands in for MainWindow: the pages only use these three things."""

    def __init__(self, engine):
        self.engine = engine
        self.errors: list[str] = []
        self.toasts: list[str] = []
        self.refreshed = 0

    def refresh(self):
        self.refreshed += 1

    def report_error(self, message):
        self.errors.append(message)

    def toast(self, message):
        self.toasts.append(message)


@pytest.fixture
def ui(engine, profile):
    profile("balanced")
    window = FakeWindow(engine)
    catalog = Catalog.from_json(engine.catalog())
    settings = Settings.from_json(engine.config())
    return window, catalog, settings


def test_every_page_builds(ui):
    window, catalog, settings = ui
    for page in (DashboardPage(window), SettingsPage(window), MonitorPage(window),
                 SetupPage(window)):
        assert page is not None

    dashboard = DashboardPage(window)
    dashboard.update(catalog)

    page = SettingsPage(window)
    page.update(settings, catalog)

    setup = SetupPage(window)
    setup.update(catalog)


def test_badges_exist_for_every_state_and_risk():
    for state in State:
        assert state_badge(state).get_label()
    for risk in ("none", "low", "medium", "high"):
        assert risk_badge(risk).get_label()


class TestSettingsForm:
    def test_the_form_covers_every_setting_the_engine_publishes(self, ui):
        window, catalog, settings = ui
        page = SettingsPage(window)
        page.update(settings, catalog)

        # If this fails, the engine grew a setting the interface silently drops.
        assert set(page._rows) == {s.key for s in settings.schema}

    def test_widgets_match_the_declared_types(self, ui):
        window, catalog, settings = ui
        page = SettingsPage(window)
        page.update(settings, catalog)

        assert isinstance(page._rows["BC250_ACPI"], Adw.SwitchRow)
        assert isinstance(page._rows["BC250_CPU_CORES"], Adw.ComboRow)
        assert isinstance(page._rows["BC250_GOV_FREQ_MAX"], Adw.SpinRow)
        assert isinstance(page._rows["BC250_GPU_WGP_LAYOUT"], Adw.EntryRow)

    def test_the_voltage_row_stops_at_the_enforced_ceiling(self, ui):
        window, catalog, settings = ui
        page = SettingsPage(window)
        page.update(settings, catalog)

        row = page._rows["BC250_CPU_OC_VID"]
        assert row.get_adjustment().get_upper() == settings.limits["vid_safe_max"]

    def test_lifting_the_lock_raises_the_ceiling_to_the_hardware_limit(self, ui):
        window, catalog, settings = ui
        page = SettingsPage(window)
        page.update(settings, catalog)

        page._rows["BC250_ALLOW_EXTREME_VID"].set_active(True)

        row = page._rows["BC250_CPU_OC_VID"]
        assert row.get_adjustment().get_upper() == settings.limits["vid_absolute_max"]

    def test_nothing_is_pending_until_something_is_edited(self, ui):
        window, catalog, settings = ui
        page = SettingsPage(window)
        page.update(settings, catalog)
        assert page.pending_changes() == []

        page._rows["BC250_DISABLE_ZRAM"].set_active(False)
        assert page.pending_changes() == ["BC250_DISABLE_ZRAM=0"]

    def test_discarding_puts_the_form_back(self, ui):
        window, catalog, settings = ui
        page = SettingsPage(window)
        page.update(settings, catalog)

        page._rows["BC250_DISABLE_ZRAM"].set_active(False)
        page._reset()
        assert page.pending_changes() == []

    def test_an_invalid_edit_is_refused_before_any_privilege_is_asked_for(self, ui):
        window, catalog, settings = ui
        page = SettingsPage(window)
        page.update(settings, catalog)

        # A frequency with no voltage cap: the engine refuses it, and the
        # interface must find that out without raising a password prompt.
        page._edited["BC250_CPU_OC_FREQ"] = "4000"
        page._on_apply()

        assert window.errors
        assert "damage the board" in window.errors[0]


class TestDashboard:
    def test_a_blocked_module_says_what_it_needs(self, ui):
        window, catalog, settings = ui
        page = DashboardPage(window)

        cores = catalog.get("50-cpu-cores")
        assert catalog.state(cores) is State.BLOCKED
        assert "nécessite : acpi" in page._subtitle(catalog, cores, State.BLOCKED)

    def test_a_conflicting_module_says_what_it_clashes_with(self, engine, sandbox, run_engine):
        (sandbox / "etc/bc250ctl/config.env").write_text("BC250_SENSORS=1\nBC250_ACPI=0\n")
        run_engine("install", "sensors")
        (sandbox / "etc/bc250ctl/config.env").write_text(
            "BC250_SENSORS=0\nBC250_FAN_CONTROL=1\nBC250_ACPI=0\n"
        )
        catalog = Catalog.from_json(engine.catalog())
        page = DashboardPage(FakeWindow(engine))

        fan = catalog.get("25-fan-control")
        assert "exclusif avec : sensors" in page._subtitle(catalog, fan, State.CONFLICT)

    def test_the_install_button_counts_the_whole_chain(self, ui):
        window, catalog, settings = ui
        page = DashboardPage(window)
        page.update(catalog)

        chain = catalog.install_chain(catalog.get("50-cpu-cores"))
        assert len(chain) == 2  # acpi, then cores


class TestMonitor:
    def test_readings_render_missing_values_as_unavailable(self, ui):
        window, catalog, settings = ui
        page = MonitorPage(window)
        page._poll()

        assert page.fan_rpm._value.get_label() == "indisponible"

    def test_a_note_explains_what_cannot_be_measured(self, ui):
        window, catalog, settings = ui
        page = MonitorPage(window)
        page._poll()

        notes = []
        child = page._notes.get_first_child()
        while child is not None:
            notes.append(child.get_title())
            child = child.get_next_sibling()
        assert any("VRAM" in note for note in notes)
        assert any("Nuvoton" in note for note in notes)
