"""What is applied, what is not, and what stands in the way.

Every row is built from the catalogue. The interface holds no list of modules
and no idea of what depends on what — a module added to modules/ appears here
by itself.
"""

from __future__ import annotations

from gi.repository import Adw, Gtk

from bc250_gui.model import Catalog, Module, State
from bc250_gui.widgets.action import ActionDialog
from bc250_gui.widgets.badges import risk_badge, state_badge

def _sentence(text: str) -> str:
    """Upper-case the first letter and leave the rest alone.

    str.capitalize() would lower-case the acronyms this project is full of —
    ACPI, TTM, PWM — so it is not what we want here.
    """
    return text[:1].upper() + text[1:]


STAGE_TITLE = {
    "pre-reboot": "Appliqué au démarrage suivant",
    "runtime": "Appliqué immédiatement",
}

#: Shown before running something that changes the power or thermal envelope.
RISK_WARNING = {
    "high": (
        "Une coupure d'alimentation — pas un simple redémarrage — annule le "
        "déblocage des cœurs et des CU. C'est la porte de sortie si la carte "
        "devient instable."
    ),
    "medium": "Vérifiez les températures après application.",
}


class DashboardPage(Gtk.Box):
    def __init__(self, window):
        super().__init__(orientation=Gtk.Orientation.VERTICAL)
        self.window = window
        self._scroller = Gtk.ScrolledWindow(vexpand=True)
        self.append(self._scroller)
        self._catalog: Catalog | None = None

    def update(self, catalog: Catalog) -> None:
        self._catalog = catalog

        page = Adw.PreferencesPage()
        page.add(self._summary_group(catalog))
        for stage, title in STAGE_TITLE.items():
            modules = catalog.by_stage(stage)
            if not modules:
                continue
            group = Adw.PreferencesGroup(title=title)
            for module in modules:
                group.add(self._row(catalog, module))
            page.add(group)

        self._scroller.set_child(page)

    # -------------------------------------------------------------- rows --

    def _summary_group(self, catalog: Catalog) -> Adw.PreferencesGroup:
        hardware = catalog.hardware
        group = Adw.PreferencesGroup(title="Cette carte")

        detected = Adw.ActionRow(
            title="Matériel",
            subtitle=(
                f"BC-250 détectée sur {hardware.gpu_card}, "
                f"{hardware.cpu_cores} cœurs en ligne"
                if hardware.bc250
                else "Aucune BC-250 détectée — les écritures de registres seront refusées"
            ),
        )
        detected.add_prefix(
            Gtk.Image(
                icon_name="computer-symbolic" if hardware.bc250 else "dialog-warning-symbolic"
            )
        )
        group.add(detected)

        profile_row = Adw.ActionRow(title="Profil actif", subtitle=catalog.profile)
        group.add(profile_row)

        needing = catalog.attention()
        if needing:
            attention = Adw.ActionRow(
                title="À regarder", subtitle=self._attention_summary(catalog, needing)
            )
            attention.add_prefix(Gtk.Image(icon_name="dialog-information-symbolic"))
            group.add(attention)

        return group

    def _attention_summary(self, catalog: Catalog, needing: list[Module]) -> str:
        """A count and the reasons, rather than a list of every module.

        On a fresh install nearly everything needs applying, and naming them
        all says less than saying how many and what is in the way.
        """
        counts: dict[State, int] = {}
        for module in needing:
            state = catalog.state(module)
            counts[state] = counts.get(state, 0) + 1

        parts = []
        for state, wording in (
            (State.CONFLICT, "{n} en conflit"),
            (State.STALE, "{n} caduc"),
            (State.BLOCKED, "{n} bloqué"),
            (State.TODO, "{n} à appliquer"),
        ):
            if state in counts:
                parts.append(wording.format(n=counts[state]))
        return ", ".join(parts)

    def _row(self, catalog: Catalog, module: Module) -> Adw.ActionRow:
        state = catalog.state(module)
        # The description reads as a title; the command-line name goes in the
        # subtitle so it stays discoverable without shouting.
        row = Adw.ActionRow(
            title=_sentence(module.description),
            subtitle=self._subtitle(catalog, module, state),
        )

        badges = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
        badges.append(state_badge(state))
        # A badge on every row for "low risk" is noise; the point of the pill
        # is to make the two that matter stand out.
        if module.risk in ("medium", "high"):
            badges.append(risk_badge(module.risk))
        row.add_suffix(badges)

        row.add_suffix(self._action_button(catalog, module, state))
        row.set_activatable(False)
        return row

    def _subtitle(self, catalog: Catalog, module: Module, state: State) -> str:
        """What the row says under its name.

        For a blocked or conflicting module this is the reason, taken from the
        graph, not a generic 'unavailable'.
        """
        if state is State.BLOCKED:
            missing = ", ".join(m.name for m in catalog.unmet_requirements(module))
            return f"{module.name} · nécessite : {missing}"
        if state is State.CONFLICT:
            others = ", ".join(m.name for m in catalog.active_conflicts(module))
            return f"{module.name} · exclusif avec : {others}"
        if state is State.STALE:
            return (
                f"{module.name} · calibré avant un changement de cœurs ou de "
                "routage GPU, à refaire"
            )
        return f"{module.name} · {module.status}"

    def _action_button(self, catalog: Catalog, module: Module, state: State) -> Gtk.Widget:
        box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6, valign=Gtk.Align.CENTER)

        if state is State.CONFLICT:
            other = catalog.active_conflicts(module)[0]
            button = Gtk.Button(label="Basculer")
            button.connect("clicked", lambda *_: self._switch(module, other))
            box.append(button)
            return box

        if state in (State.TODO, State.BLOCKED, State.STALE):
            chain = catalog.install_chain(module)
            label = "Installer" if len(chain) == 1 else f"Installer ({len(chain)})"
            button = Gtk.Button(label=label)
            button.add_css_class("suggested-action")
            button.connect("clicked", lambda *_: self._install(module, chain))
            box.append(button)

        if module.active:
            verify = Gtk.Button(icon_name="emblem-ok-symbolic", tooltip_text="Vérifier")
            verify.connect("clicked", lambda *_: self._verify(module))
            box.append(verify)

            revert = Gtk.Button(icon_name="edit-undo-symbolic", tooltip_text="Revenir en arrière")
            revert.add_css_class("destructive-action")
            revert.connect("clicked", lambda *_: self._revert(module))
            box.append(revert)

        return box

    # ----------------------------------------------------------- actions --

    def _run(self, title, explanation, args, warning="", then=None) -> None:
        def finished(status: int) -> None:
            self.window.refresh()
            if status == 0 and then is not None:
                then()

        dialog = ActionDialog(
            parent=self.window,
            engine=self.window.engine,
            title=title,
            explanation=explanation,
            args=args,
            warning=warning,
            on_finished=finished,
        )
        dialog.present()

    def _install(self, module: Module, chain: list[Module]) -> None:
        names = [m.name for m in chain]
        if len(chain) == 1:
            explanation = f"Installer {module.name} : {module.description}."
        else:
            explanation = (
                f"{module.name} dépend de modules qui ne sont pas en place. "
                "Ils seront installés dans cet ordre :\n\n  "
                + "\n  ".join(f"{i + 1}. {m.name} — {m.description}" for i, m in enumerate(chain))
            )
        self._run(
            f"Installer {module.name}",
            explanation,
            ["install", *names],
            warning=RISK_WARNING.get(module.risk, ""),
        )

    def _verify(self, module: Module) -> None:
        self._run(
            f"Vérifier {module.name}",
            "Contrôle que le module est réellement en effet, et pas seulement installé.",
            ["verify", module.name],
        )

    def _revert(self, module: Module) -> None:
        self._run(
            f"Revenir en arrière : {module.name}",
            f"Remet {module.name} dans son état d'origine.",
            ["revert", module.name],
        )

    def _switch(self, wanted: Module, active: Module) -> None:
        """Hand the hardware from one driver to the other.

        Two elevated calls, so two prompts: the engine refuses to install the
        second while the first is still in place, and that refusal is the
        safeguard — we work with it rather than around it.
        """

        def then_install() -> None:
            self._run(
                f"Installer {wanted.name}",
                f"{active.name} a été retiré. Installation de {wanted.name}.",
                ["install", wanted.name],
                warning=RISK_WARNING.get(wanted.risk, ""),
            )

        self._run(
            f"Basculer vers {wanted.name}",
            (
                f"{wanted.name} et {active.name} visent le même matériel et ne "
                f"peuvent pas coexister.\n\n{active.name} va être retiré, puis "
                f"{wanted.name} installé. Deux autorisations vous seront demandées."
            ),
            ["revert", active.name],
            then=then_install,
        )
