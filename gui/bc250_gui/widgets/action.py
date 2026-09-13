"""Running an elevated action, with its output visible.

Every privileged call goes through here, which is what keeps the password
prompts down to one per action: the dialog says what is about to happen, asks
once, then runs the whole batch.
"""

from __future__ import annotations

from typing import Callable, Sequence

from gi.repository import Adw, GLib, Gtk

from bc250_gui.engine import Engine, Event
from bc250_gui.widgets.console import Console


class ActionDialog(Adw.Window):
    """Confirm, run, report. Modal over the main window."""

    def __init__(
        self,
        parent: Gtk.Window,
        engine: Engine,
        title: str,
        explanation: str,
        args: Sequence[str],
        on_finished: Callable[[int], None] | None = None,
        warning: str = "",
    ):
        super().__init__(
            transient_for=parent, modal=True, default_width=620, default_height=460,
            title=title,
        )
        self._engine = engine
        self._args = list(args)
        self._on_finished = on_finished
        self._finished = False

        self._console = Console()
        self._progress = Gtk.ProgressBar(show_text=True, text="prêt")

        self._run_button = Gtk.Button(label="Lancer")
        self._run_button.add_css_class("suggested-action")
        self._run_button.connect("clicked", self._on_run)

        self._close_button = Gtk.Button(label="Annuler")
        self._close_button.connect("clicked", lambda *_: self.close())

        header = Adw.HeaderBar(show_end_title_buttons=False)
        header.pack_start(self._close_button)
        header.pack_end(self._run_button)

        body = Gtk.Box(
            orientation=Gtk.Orientation.VERTICAL, spacing=12,
            margin_top=12, margin_bottom=12, margin_start=12, margin_end=12,
        )
        body.append(Gtk.Label(label=explanation, wrap=True, xalign=0))
        if warning:
            banner = Adw.Banner(title=warning, revealed=True)
            body.append(banner)
        body.append(self._progress)
        body.append(self._console)

        view = Adw.ToolbarView()
        view.add_top_bar(header)
        view.set_content(body)
        self.set_content(view)

    # ------------------------------------------------------------ running --

    def _on_run(self, *_args) -> None:
        self._run_button.set_sensitive(False)
        self._close_button.set_sensitive(False)
        self._progress.set_text("en cours…")
        self._progress.pulse()

        self._engine.run_privileged(
            self._args,
            on_line=lambda line: GLib.idle_add(self._append, line),
            on_event=lambda event: GLib.idle_add(self._handle_event, event),
            on_done=lambda status: GLib.idle_add(self._done, status),
        )

    def _append(self, line: str) -> bool:
        self._console.append(line.rstrip("\n"))
        self._progress.pulse()
        return False

    def _handle_event(self, event: Event) -> bool:
        if event.event == "module-begin":
            self._progress.set_text(f"{event.module} — {event.text}")
        elif event.event == "reboot-required":
            self._progress.set_text("redémarrage nécessaire")
        self._progress.pulse()
        return False

    def _done(self, status: int) -> bool:
        self._finished = True
        self._progress.set_fraction(1.0)
        if status == 0:
            self._progress.set_text("terminé")
        else:
            self._progress.set_text(f"échec (code {status})")
            self._console.append(
                "\nL'opération a échoué. Rien d'autre n'a été tenté."
            )
        self._close_button.set_label("Fermer")
        self._close_button.set_sensitive(True)
        if self._on_finished:
            self._on_finished(status)
        return False
