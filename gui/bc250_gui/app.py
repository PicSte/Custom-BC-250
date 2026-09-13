"""The application object."""

from __future__ import annotations

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")

from gi.repository import Adw, Gdk, Gio, Gtk  # noqa: E402

from bc250_gui.engine import Engine, EngineError  # noqa: E402
from bc250_gui.window import MainWindow  # noqa: E402

APP_ID = "fr.picste.bc250ctl"

STYLE = """
.badge {
    font-size: 0.8em;
    font-weight: bold;
    padding: 1px 8px;
    border-radius: 9999px;
}
.badge-ok       { background: alpha(@success_color, .18); color: @success_color; }
.badge-todo     { background: alpha(@window_fg_color, .10); }
.badge-off      { background: alpha(@window_fg_color, .06); opacity: .75; }
.badge-blocked  { background: alpha(@warning_color, .18); color: @warning_color; }
.badge-stale    { background: alpha(@warning_color, .25); color: @warning_color; }
.badge-conflict { background: alpha(@error_color, .18); color: @error_color; }
.badge-risk-none, .badge-risk-low { background: alpha(@window_fg_color, .08); }
.badge-risk-medium { background: alpha(@warning_color, .18); color: @warning_color; }
.badge-risk-high   { background: alpha(@error_color, .18); color: @error_color; }
.console { font-family: monospace; font-size: 0.9em; }
.reading-value { font-size: 1.6em; font-weight: bold; }
"""


def install_css() -> None:
    """Attach the stylesheet to the display.

    Split out so the screenshot harness and the tests style their windows the
    same way the application does, rather than rendering an unstyled variant
    nobody will ever see.
    """
    provider = Gtk.CssProvider()
    # load_from_data changed signature in GTK 4.12 and fails silently from
    # Python on newer versions; load_from_string is the one that works there.
    # Without this the badges render as plain text.
    if hasattr(provider, "load_from_string"):
        provider.load_from_string(STYLE)
    else:
        provider.load_from_data(STYLE.encode())

    display = Gdk.Display.get_default()
    if display is not None:
        Gtk.StyleContext.add_provider_for_display(
            display, provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
        )


class Bc250Application(Adw.Application):
    def __init__(self):
        super().__init__(
            application_id=APP_ID, flags=Gio.ApplicationFlags.DEFAULT_FLAGS
        )
        self.engine: Engine | None = None
        self._startup_error: str | None = None

    def do_startup(self):
        Adw.Application.do_startup(self)

        provider = Gtk.CssProvider()
        # load_from_data changed signature in GTK 4.12 and fails silently from
        # Python on newer versions; load_from_string is the one that works
        # there. Without this the badges render as plain text.
        if hasattr(provider, "load_from_string"):
            provider.load_from_string(STYLE)
        else:
            provider.load_from_data(STYLE.encode())
        display = Gdk.Display.get_default()
        if display is not None:
            Gtk.StyleContext.add_provider_for_display(
                display, provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
            )

        try:
            self.engine = Engine()
        except EngineError as exc:
            self._startup_error = exc.message

    def do_activate(self):
        window = self.props.active_window
        if not window:
            window = MainWindow(application=self, engine=self.engine)
        window.present()

        if self._startup_error:
            window.report_fatal(self._startup_error)
