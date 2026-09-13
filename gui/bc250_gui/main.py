"""Entry point, with the dependency check in front of it.

GTK4, libadwaita and PyGObject are there on a Bazzite GNOME image and are not
guaranteed on the others. Finding that out as an ImportError traceback helps
nobody, so check first and say exactly what to install.
"""

from __future__ import annotations

import sys

MISSING = """\
bc250-gui a besoin de GTK4, libadwaita et PyGObject, qui manquent sur ce système.

Sur Bazzite :

    rpm-ostree install python3-gobject gtk4 libadwaita
    systemctl reboot

Détail : {error}
"""


def check_dependencies() -> str | None:
    """Returns an explanation when the toolkit is unusable, else None."""
    try:
        import gi

        gi.require_version("Gtk", "4.0")
        gi.require_version("Adw", "1")
        from gi.repository import Adw, Gtk  # noqa: F401
    except (ImportError, ValueError) as exc:
        return MISSING.format(error=exc)
    return None


def main(argv: list[str] | None = None) -> int:
    problem = check_dependencies()
    if problem:
        print(problem, file=sys.stderr)
        return 1

    from bc250_gui.app import Bc250Application

    return Bc250Application().run(argv if argv is not None else sys.argv)
