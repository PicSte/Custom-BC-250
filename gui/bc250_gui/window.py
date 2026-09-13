"""The main window: four pages and the banners that sit above them."""

from __future__ import annotations

from gi.repository import Adw, GLib, Gtk

from bc250_gui.engine import Engine, EngineError
from bc250_gui.model import Catalog, Settings
from bc250_gui.pages.dashboard import DashboardPage
from bc250_gui.pages.monitor import MonitorPage
from bc250_gui.pages.settings import SettingsPage
from bc250_gui.pages.setup import SetupPage


class MainWindow(Adw.ApplicationWindow):
    def __init__(self, application, engine: Engine | None):
        super().__init__(
            application=application, title="BC-250", default_width=920,
            default_height=680,
        )
        self.engine = engine

        self._toasts = Adw.ToastOverlay()
        self._reboot_banner = Adw.Banner(
            title="Un redémarrage est nécessaire pour terminer l'application des changements.",
            button_label="Redémarrer",
        )
        self._reboot_banner.connect("button-clicked", self._on_reboot)

        self.stack = Adw.ViewStack()
        self.dashboard = DashboardPage(self)
        self.settings_page = SettingsPage(self)
        self.monitor = MonitorPage(self)
        self.setup = SetupPage(self)

        self.stack.add_titled_with_icon(
            self.dashboard, "dashboard", "Modules", "view-list-symbolic"
        )
        self.stack.add_titled_with_icon(
            self.settings_page, "settings", "Réglages", "preferences-system-symbolic"
        )
        self.stack.add_titled_with_icon(
            self.monitor, "monitor", "Supervision", "utilities-system-monitor-symbolic"
        )
        self.stack.add_titled_with_icon(
            self.setup, "setup", "Installation", "go-next-symbolic"
        )

        switcher = Adw.ViewSwitcher(
            stack=self.stack, policy=Adw.ViewSwitcherPolicy.WIDE
        )
        header = Adw.HeaderBar(title_widget=switcher)

        refresh = Gtk.Button(icon_name="view-refresh-symbolic", tooltip_text="Actualiser")
        refresh.connect("clicked", lambda *_: self.refresh())
        header.pack_end(refresh)

        content = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        content.append(self._reboot_banner)
        content.append(self.stack)

        view = Adw.ToolbarView()
        view.add_top_bar(header)
        view.set_content(content)
        self._toasts.set_child(view)
        self.set_content(self._toasts)

        self.catalog: Catalog | None = None
        self.settings: Settings | None = None

        # Let the window map before the first read, so an engine that is slow
        # to answer does not look like an application that failed to start.
        GLib.idle_add(self.refresh)

    # ------------------------------------------------------------- state --

    def refresh(self) -> bool:
        """Re-read everything and hand it to the pages."""
        if self.engine is None:
            return False
        try:
            self.catalog = Catalog.from_json(self.engine.catalog())
            self.settings = Settings.from_json(self.engine.config())
        except EngineError as exc:
            self.report_error(exc.message)
            return False

        self._reboot_banner.set_revealed(self.catalog.reboot_required)
        self.dashboard.update(self.catalog)
        self.settings_page.update(self.settings, self.catalog)
        self.setup.update(self.catalog)
        return False

    # ----------------------------------------------------------- messages --

    def toast(self, message: str) -> None:
        self._toasts.add_toast(Adw.Toast(title=message, timeout=4))

    def report_error(self, message: str) -> None:
        dialog = Adw.MessageDialog(
            transient_for=self, heading="Erreur", body=message
        )
        dialog.add_response("ok", "Fermer")
        dialog.present()

    def report_fatal(self, message: str) -> None:
        dialog = Adw.MessageDialog(
            transient_for=self,
            heading="bc250ctl est introuvable",
            body=message,
        )
        dialog.add_response("quit", "Quitter")
        dialog.connect("response", lambda *_: self.close())
        dialog.present()

    def _on_reboot(self, *_args) -> None:
        dialog = Adw.MessageDialog(
            transient_for=self,
            heading="Redémarrer maintenant ?",
            body="Les changements en attente ne prennent effet qu'au redémarrage.",
        )
        dialog.add_response("cancel", "Plus tard")
        dialog.add_response("reboot", "Redémarrer")
        dialog.set_response_appearance("reboot", Adw.ResponseAppearance.DESTRUCTIVE)
        dialog.connect("response", self._reboot_response)
        dialog.present()

    def _reboot_response(self, _dialog, response: str) -> None:
        if response != "reboot":
            return
        from gi.repository import Gio

        try:
            Gio.Subprocess.new(
                ["systemctl", "reboot"], Gio.SubprocessFlags.NONE
            )
        except Exception as exc:  # noqa: BLE001 — surfaced, not swallowed
            self.report_error(f"impossible de redémarrer : {exc}")
