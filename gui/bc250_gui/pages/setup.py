"""The first-run assistant.

Walks a fresh install: what the hardware looks like, which profile, what that
profile is going to change, then the run itself with its output visible.

It has to survive reboots, because on an ostree system the bootstrap cannot
avoid them. The engine already records where it got to, so the assistant asks
the catalogue rather than keeping its own idea of progress.
"""

from __future__ import annotations

from gi.repository import Adw, Gtk

from bc250_gui.engine import EngineError
from bc250_gui.model import Catalog
from bc250_gui.widgets.action import ActionDialog

PROFILE_RISK = {
    "safe": "",
    "balanced": (
        "Débloque les 40 CU et les 8 cœurs. Une coupure d'alimentation — pas "
        "un simple redémarrage — annule les deux si la carte devient instable."
    ),
    "max": (
        "En plus du reste, calibre un overclock CPU sous charge. À ne lancer "
        "qu'avec un refroidissement correct, et en étant présent : cette étape "
        "pose des questions."
    ),
}


class SetupPage(Gtk.Box):
    def __init__(self, window):
        super().__init__(orientation=Gtk.Orientation.VERTICAL)
        self.window = window
        self._catalog: Catalog | None = None
        self._profiles: list[dict] = []
        self._chosen: str = "safe"

        self._navigation = Adw.NavigationView()
        self.append(self._navigation)
        self._navigation.add(self._welcome_page())

    # ------------------------------------------------------------ pages --

    def _wrap(self, title: str, child: Gtk.Widget) -> Adw.NavigationPage:
        toolbar = Adw.ToolbarView()
        # The window already has a header bar with the close buttons; this one
        # only carries the page title and the back arrow.
        toolbar.add_top_bar(
            Adw.HeaderBar(
                show_start_title_buttons=False, show_end_title_buttons=False
            )
        )
        toolbar.set_content(Gtk.ScrolledWindow(child=child, vexpand=True))
        return Adw.NavigationPage(title=title, child=toolbar)

    def _welcome_page(self) -> Adw.NavigationPage:
        self._status = Adw.StatusPage(
            title="Préparer cette carte",
            description=(
                "L'assistant installe et configure ce qu'il faut pour une "
                "BC-250 sous Bazzite, et reprend tout seul après chaque "
                "redémarrage."
            ),
            icon_name="preferences-other-symbolic",
        )

        self._start = Gtk.Button(label="Commencer", halign=Gtk.Align.CENTER)
        self._start.add_css_class("suggested-action")
        self._start.add_css_class("pill")
        self._start.connect("clicked", lambda *_: self._go_diagnostics())

        self._resume = Gtk.Button(label="Reprendre", halign=Gtk.Align.CENTER)
        self._resume.add_css_class("suggested-action")
        self._resume.add_css_class("pill")
        self._resume.set_visible(False)
        self._resume.connect("clicked", lambda *_: self._run_bootstrap(resume=True))

        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        box.append(self._start)
        box.append(self._resume)
        self._status.set_child(box)

        return self._wrap("Installation", self._status)

    def _go_diagnostics(self) -> None:
        report = self.window.engine.doctor() if self.window.engine else ""

        view = Gtk.TextView(
            editable=False, cursor_visible=False, monospace=True,
            top_margin=12, bottom_margin=12, left_margin=12, right_margin=12,
        )
        view.get_buffer().set_text(report)
        view.add_css_class("console")

        proceed = Gtk.Button(label="Continuer", halign=Gtk.Align.CENTER, margin_bottom=12)
        proceed.add_css_class("suggested-action")
        proceed.add_css_class("pill")
        proceed.connect("clicked", lambda *_: self._go_profiles())

        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        box.append(
            Gtk.Label(
                label="Ce que l'outil voit de cette machine. Lisez les "
                      "avertissements avant de continuer.",
                wrap=True, xalign=0, margin_top=12, margin_start=12, margin_end=12,
            )
        )
        box.append(view)
        box.append(proceed)

        self._navigation.push(self._wrap("Diagnostic", box))

    def _go_profiles(self) -> None:
        page = Adw.PreferencesPage()
        group = Adw.PreferencesGroup(
            title="Choisir un profil",
            description="Commencez par « safe » sur une install fraîche ; "
                        "vous monterez ensuite.",
        )

        first: Gtk.CheckButton | None = None
        for profile in self._profiles:
            row = Adw.ActionRow(
                title=profile["name"], subtitle=profile.get("description", "")
            )
            radio = Gtk.CheckButton(valign=Gtk.Align.CENTER)
            if first is None:
                first = radio
                radio.set_active(True)
                self._chosen = profile["name"]
            else:
                radio.set_group(first)
            radio.connect("toggled", self._on_profile_chosen, profile["name"])
            row.add_prefix(radio)
            row.set_activatable_widget(radio)
            group.add(row)

        page.add(group)

        self._risk_banner = Adw.Banner(revealed=False)
        run = Gtk.Button(label="Lancer l'installation", halign=Gtk.Align.CENTER,
                         margin_top=6, margin_bottom=12)
        run.add_css_class("suggested-action")
        run.add_css_class("pill")
        run.connect("clicked", lambda *_: self._run_bootstrap())

        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        box.append(self._risk_banner)
        box.append(page)
        box.append(run)

        self._on_profile_chosen(None, self._chosen)
        self._navigation.push(self._wrap("Profil", box))

    def _on_profile_chosen(self, radio, name: str) -> None:
        if radio is not None and not radio.get_active():
            return
        self._chosen = name
        warning = PROFILE_RISK.get(name, "")
        self._risk_banner.set_title(warning)
        self._risk_banner.set_revealed(bool(warning))

    # ---------------------------------------------------------- running --

    def _run_bootstrap(self, resume: bool = False) -> None:
        if resume:
            args = ["bootstrap"]
            explanation = (
                "Reprise de l'installation là où elle s'était arrêtée avant le "
                "redémarrage."
            )
        else:
            args = ["--profile", self._chosen, "bootstrap"]
            explanation = (
                f"Application du profil « {self._chosen} ».\n\n"
                "L'installation s'arrêtera d'elle-même quand un redémarrage "
                "sera nécessaire, et reprendra ensuite toute seule."
            )

        dialog = ActionDialog(
            parent=self.window,
            engine=self.window.engine,
            title="Installation",
            explanation=explanation,
            args=args,
            warning=PROFILE_RISK.get(self._chosen, ""),
            on_finished=lambda _status: self.window.refresh(),
        )
        dialog.present()

    # ----------------------------------------------------------- refresh --

    def update(self, catalog: Catalog) -> None:
        self._catalog = catalog

        if self.window.engine is not None and not self._profiles:
            try:
                self._profiles = self.window.engine.profiles()["profiles"]
            except (EngineError, KeyError):
                self._profiles = []

        # The engine marks a reboot as owed while a bootstrap is mid-flight;
        # that is the signal to offer resuming rather than starting over.
        pending = catalog.reboot_required
        self._resume.set_visible(pending)
        self._start.set_label("Recommencer" if pending else "Commencer")
        if pending:
            self._status.set_description(
                "Une installation est en cours et attend un redémarrage. "
                "Redémarrez, puis reprenez — ou laissez le service de reprise "
                "s'en charger tout seul."
            )
