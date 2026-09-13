"""The settings form, generated from the engine's schema.

No field is written out here. Every row comes from `bc250ctl config --json`,
so a setting added to lib/settings.sh shows up with the right widget, the
right range and the right help text without this file changing.

Edits are held locally until Appliquer: the privileged call is one per apply,
not one per slider, and the diff is shown first.
"""

from __future__ import annotations

from gi.repository import Adw, Gtk

from bc250_gui.model import CAPPED_SETTINGS, Catalog, Setting, Settings, lock_key
from bc250_gui.widgets.action import ActionDialog

#: A setting's module id maps to the group it is shown under.
GROUP_TITLE = {
    "core": "Général",
    "10-kargs": "Arguments noyau",
    "15-acpi": "Tables ACPI",
    "20-sensors": "Capteurs",
    "25-fan-control": "Ventilation",
    "30-governor": "Governor GPU",
    "40-gpu-cu": "Unités de calcul GPU",
    "50-cpu-cores": "Cœurs CPU",
    "60-cpu-oc": "Overclock CPU",
    "70-fixes": "Correctifs",
}

#: The flags that lift a ceiling; changing one has to re-bound its rows.
UNLOCK_KEYS = {flag for flag, _safe, _absolute in CAPPED_SETTINGS.values()}


class SettingsPage(Gtk.Box):
    def __init__(self, window):
        super().__init__(orientation=Gtk.Orientation.VERTICAL)
        self.window = window
        self._settings: Settings | None = None
        self._edited: dict[str, str] = {}
        self._rows: dict[str, Gtk.Widget] = {}

        self._scroller = Gtk.ScrolledWindow(vexpand=True)
        self.append(self._scroller)

        self._apply = Gtk.Button(label="Appliquer les changements")
        self._apply.add_css_class("suggested-action")
        self._apply.set_sensitive(False)
        self._apply.connect("clicked", self._on_apply)

        self._discard = Gtk.Button(label="Annuler")
        self._discard.set_sensitive(False)
        self._discard.connect("clicked", lambda *_: self._reset())

        bar = Gtk.Box(
            orientation=Gtk.Orientation.HORIZONTAL, spacing=8, halign=Gtk.Align.END,
            margin_top=8, margin_bottom=8, margin_start=12, margin_end=12,
        )
        bar.append(self._discard)
        bar.append(self._apply)
        self.append(bar)

    # ------------------------------------------------------------- build --

    def update(self, settings: Settings, catalog: Catalog | None = None) -> None:
        self._settings = settings
        self._edited = dict(settings.values)
        self._rows = {}

        page = Adw.PreferencesPage()
        for module, group_settings in settings.by_module().items():
            group = Adw.PreferencesGroup(title=GROUP_TITLE.get(module, module))
            for setting in group_settings:
                group.add(self._build_row(setting))
            page.add(group)

        self._scroller.set_child(page)
        self._refresh_buttons()

    def _build_row(self, setting: Setting) -> Gtk.Widget:
        value = self._edited.get(setting.key, setting.default)
        subtitle = setting.help
        if setting.unit:
            subtitle = f"{subtitle} ({setting.unit})" if subtitle else setting.unit

        if setting.type == "bool":
            row = Adw.SwitchRow(title=setting.label, subtitle=subtitle)
            row.set_active(value == "1")
            row.connect("notify::active", self._on_bool, setting)
        elif setting.type == "choice":
            row = Adw.ComboRow(title=setting.label, subtitle=subtitle)
            model = Gtk.StringList()
            for choice in setting.choices:
                model.append(choice)
            row.set_model(model)
            if value in setting.choices:
                row.set_selected(setting.choices.index(value))
            row.connect("notify::selected", self._on_choice, setting)
        elif setting.type in ("int", "int0", "intauto"):
            row = self._build_number_row(setting, value, subtitle)
        else:
            row = Adw.EntryRow(title=setting.label)
            row.set_text(value)
            row.connect("changed", self._on_text, setting)

        self._rows[setting.key] = row
        return row

    def _build_number_row(self, setting: Setting, value: str, subtitle: str) -> Gtk.Widget:
        """A spin row, bounded by what the engine will actually accept.

        int0 and intauto carry an 'off' value outside the range — 0 and auto.
        They get a switch that turns the number on, so the off state stays
        reachable without typing a magic value.
        """
        maximum = self._settings.effective_maximum(setting, self._unlocked(setting))
        minimum = setting.minimum or 0

        off_value = "0" if setting.type == "int0" else "auto"
        optional = setting.type in ("int0", "intauto")
        is_off = optional and value == off_value

        adjustment = Gtk.Adjustment(
            lower=minimum, upper=maximum or minimum, step_increment=1, page_increment=10,
        )
        row = Adw.SpinRow(title=setting.label, subtitle=subtitle, adjustment=adjustment)
        row.set_value(float(value) if value.isdigit() else float(minimum))

        if optional:
            toggle = Gtk.Switch(valign=Gtk.Align.CENTER, active=not is_off)
            row.add_prefix(toggle)
            row.set_sensitive(not is_off)
            toggle.connect("notify::active", self._on_optional_toggle, setting, row)

        row.connect("notify::value", self._on_number, setting)
        return row

    def _unlocked(self, setting: Setting) -> bool:
        flag = lock_key(setting)
        return flag is not None and self._edited.get(flag, "0") == "1"

    # ------------------------------------------------------------ edits --

    def _set(self, key: str, value: str) -> None:
        self._edited[key] = value
        # Lifting a voltage lock changes what its rows may offer, so they have
        # to be re-bounded rather than left showing a stale ceiling.
        if key in UNLOCK_KEYS:
            self._rebound_capped_rows(key)
        self._refresh_buttons()

    def _on_bool(self, row, _param, setting: Setting) -> None:
        self._set(setting.key, "1" if row.get_active() else "0")

    def _on_choice(self, row, _param, setting: Setting) -> None:
        index = row.get_selected()
        if 0 <= index < len(setting.choices):
            self._set(setting.key, setting.choices[index])

    def _on_text(self, row, setting: Setting) -> None:
        self._set(setting.key, row.get_text())

    def _on_number(self, row, _param, setting: Setting) -> None:
        if row.get_sensitive():
            self._set(setting.key, str(int(row.get_value())))

    def _on_optional_toggle(self, toggle, _param, setting: Setting, row) -> None:
        on = toggle.get_active()
        row.set_sensitive(on)
        if on:
            self._set(setting.key, str(int(row.get_value())))
        else:
            self._set(setting.key, "0" if setting.type == "int0" else "auto")

    def _rebound_capped_rows(self, flag: str) -> None:
        """Re-apply the ceilings the given lock controls."""
        if self._settings is None:
            return
        for key, (owner, _safe, _absolute) in CAPPED_SETTINGS.items():
            if owner != flag:
                continue
            row = self._rows.get(key)
            setting = self._settings.get(key)
            if row is None or setting is None:
                continue
            maximum = self._settings.effective_maximum(setting, self._unlocked(setting))
            if maximum is None:
                continue
            row.get_adjustment().set_upper(maximum)
            # Lowering a ceiling has to drag the value down with it, or the
            # form would hold a number the engine is about to reject.
            if row.get_value() > maximum:
                row.set_value(maximum)

    def _reset(self) -> None:
        if self._settings:
            self.update(self._settings)

    def _refresh_buttons(self) -> None:
        changed = bool(self.pending_changes())
        self._apply.set_sensitive(changed)
        self._discard.set_sensitive(changed)

    def pending_changes(self) -> list[str]:
        if self._settings is None:
            return []
        return self._settings.changes(self._edited)

    # ----------------------------------------------------------- applying --

    def _on_apply(self, *_args) -> None:
        changes = self.pending_changes()
        if not changes:
            return

        valid, rendered = self.window.engine.config_diff(changes)
        if not valid:
            self.window.report_error(
                "Ces réglages seraient refusés :\n\n" + rendered
            )
            return

        dialog = ActionDialog(
            parent=self.window,
            engine=self.window.engine,
            title="Appliquer les réglages",
            explanation="Ces valeurs vont être écrites :\n\n" + rendered,
            args=["config", "set", *changes],
            on_finished=self._applied,
        )
        dialog.present()

    def _applied(self, status: int) -> None:
        self.window.refresh()
        if status == 0:
            self.window.toast(
                "Réglages enregistrés. Réappliquez les modules concernés pour "
                "qu'ils prennent effet."
            )
