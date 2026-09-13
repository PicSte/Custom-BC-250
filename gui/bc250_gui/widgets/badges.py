"""Small status pills.

The words and the colours both come from the engine's own vocabulary: a
module's risk is whatever mod_risk says, and its state is computed from the
catalogue. Nothing here decides either.
"""

from __future__ import annotations

from gi.repository import Gtk

from bc250_gui.model import State

STATE_LABEL = {
    State.OK: "appliqué",
    State.OFF: "désactivé",
    State.TODO: "à appliquer",
    State.STALE: "caduc",
    State.BLOCKED: "bloqué",
    State.CONFLICT: "conflit",
}

RISK_LABEL = {
    "none": "sans risque",
    "low": "risque faible",
    "medium": "risque moyen",
    "high": "risque élevé",
}


def _pill(text: str, css: str) -> Gtk.Label:
    label = Gtk.Label(label=text, valign=Gtk.Align.CENTER)
    label.add_css_class("badge")
    label.add_css_class(css)
    return label


def state_badge(state: State) -> Gtk.Label:
    return _pill(STATE_LABEL[state], f"badge-{state.value}")


def risk_badge(risk: str) -> Gtk.Label:
    return _pill(RISK_LABEL.get(risk, risk), f"badge-risk-{risk}")
