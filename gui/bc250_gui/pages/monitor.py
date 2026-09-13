"""Live readings.

Polls `bc250ctl telemetry --json` once a second. What it cannot measure it
says so, rather than drawing a zero: this board has no VRAM sensor at all, and
the GPU clock table stops telling the truth once the extra CPU cores are up.
"""

from __future__ import annotations

from collections import deque

from gi.repository import Adw, Gdk, GLib, Graphene, Gtk

from bc250_gui.engine import EngineError

POLL_SECONDS = 1
HISTORY = 60


class Sparkline(Gtk.Widget):
    """The last minute of a value, as bars.

    Drawn with snapshot rather than a cairo draw function on purpose: the
    cairo binding is a separate package that is not always installed, and a
    missing python3-cairo would take the whole monitoring page down. Bars need
    nothing but append_color, which is always there.
    """

    HEIGHT = 44

    def __init__(self, ceiling: float):
        super().__init__()
        self.set_hexpand(True)
        self.ceiling = ceiling
        self.history: deque[float] = deque(maxlen=HISTORY)

    def do_measure(self, orientation, _for_size):  # noqa: N802 (GObject naming)
        if orientation == Gtk.Orientation.VERTICAL:
            return self.HEIGHT, self.HEIGHT, -1, -1
        return 0, 120, -1, -1

    def push(self, value: float) -> None:
        self.history.append(float(value))
        self.queue_draw()

    def do_snapshot(self, snapshot) -> None:  # noqa: N802 (GObject naming)
        if not self.history:
            return
        width = self.get_width()
        height = self.get_height()
        if width <= 0 or height <= 0:
            return

        top = max(self.ceiling, max(self.history)) or 1.0
        bar_width = width / HISTORY

        # Follow the theme's foreground rather than a fixed colour, so the
        # chart stays legible in light and dark alike.
        colour = self.get_color()
        colour = Gdk.RGBA(
            red=colour.red, green=colour.green, blue=colour.blue, alpha=0.55
        )

        for index, value in enumerate(self.history):
            bar_height = max(1.0, (value / top) * (height - 1))
            rect = Graphene.Rect().init(
                index * bar_width,
                height - bar_height,
                max(1.0, bar_width - 1.0),
                bar_height,
            )
            snapshot.append_color(colour, rect)


class Reading(Gtk.Box):
    """One value, with its recent history under it."""

    def __init__(self, title: str, unit: str, ceiling: float, warn_above: float | None = None):
        super().__init__(orientation=Gtk.Orientation.VERTICAL, spacing=2)
        self.unit = unit
        self.warn_above = warn_above

        self._title = Gtk.Label(label=title, xalign=0)
        self._title.add_css_class("dim-label")
        self._value = Gtk.Label(label="—", xalign=0)
        self._value.add_css_class("reading-value")
        self._chart = Sparkline(ceiling)

        self.append(self._title)
        self.append(self._value)
        self.append(self._chart)

    @property
    def history(self) -> deque:
        return self._chart.history

    def set(self, value: float | None) -> None:
        if value is None:
            self._value.set_label("indisponible")
            self._value.add_css_class("dim-label")
            return
        self._value.remove_css_class("dim-label")
        self._value.set_label(f"{value:g} {self.unit}".strip())

        # Say when a reading is past the point the documentation calls safe,
        # rather than leaving the number to be read against nothing.
        if self.warn_above is not None and value >= self.warn_above:
            self._value.add_css_class("reading-hot")
        else:
            self._value.remove_css_class("reading-hot")

        self._chart.push(value)


class MonitorPage(Gtk.Box):
    def __init__(self, window):
        super().__init__(orientation=Gtk.Orientation.VERTICAL)
        self.window = window
        self._timer: int | None = None

        # 85 °C is where the BC-250 documentation puts the APU ceiling.
        self.gpu_temp = Reading("Température GPU", "°C", 100, warn_above=85)
        self.gpu_clock = Reading("Fréquence GPU", "MHz", 2000)
        self.gpu_power = Reading("Puissance GPU", "W", 200)
        self.cpu_temp = Reading("Température CPU", "°C", 100, warn_above=90)
        self.fan_rpm = Reading("Ventilateur", "tr/min", 5000)
        self.gpu_busy = Reading("Charge GPU", "%", 100)

        grid = Gtk.Grid(
            column_spacing=28, row_spacing=24, margin_top=18, margin_bottom=18,
            margin_start=18, margin_end=18, column_homogeneous=True,
        )
        # The card wraps the grid rather than being the grid, so the grid's
        # margins read as padding inside it instead of space around it.
        card = Gtk.Box(valign=Gtk.Align.START)
        card.add_css_class("card")
        card.append(grid)
        for index, reading in enumerate(
            (self.gpu_temp, self.gpu_clock, self.gpu_power,
             self.cpu_temp, self.fan_rpm, self.gpu_busy)
        ):
            grid.attach(reading, index % 3, index // 3, 1, 1)

        self._notes = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6,
                              margin_start=18, margin_end=18, margin_bottom=18)

        clamp = Adw.Clamp(maximum_size=900, margin_top=18, margin_start=18,
                          margin_end=18, child=card)

        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        box.append(clamp)
        box.append(Adw.Clamp(maximum_size=900, child=self._notes))
        self.append(Gtk.ScrolledWindow(child=box, vexpand=True))

        # Only poll while the page is on screen; there is no reason to read
        # sysfs once a second behind a tab nobody is looking at.
        self.connect("map", lambda *_: self._start())
        self.connect("unmap", lambda *_: self._stop())

    def _start(self) -> None:
        if self._timer is None:
            self._timer = GLib.timeout_add_seconds(POLL_SECONDS, self._poll)
            self._poll()

    def _stop(self) -> None:
        if self._timer is not None:
            GLib.source_remove(self._timer)
            self._timer = None

    def _poll(self) -> bool:
        if self.window.engine is None:
            return True
        try:
            data = self.window.engine.telemetry()
        except EngineError:
            # A transient read failure is not worth a dialog; the values simply
            # stop moving and the next tick tries again.
            return True

        gpu = data.get("gpu", {})
        cpu = data.get("cpu", {})
        fan = data.get("fan", {})

        self.gpu_temp.set(gpu.get("temp_c"))
        self.gpu_clock.set(gpu.get("sclk_mhz"))
        self.gpu_power.set(gpu.get("power_w"))
        self.gpu_busy.set(gpu.get("busy_percent"))
        self.cpu_temp.set(cpu.get("temp_c"))
        self.fan_rpm.set(fan.get("rpm"))

        self._update_notes(data)
        return True

    def _update_notes(self, data: dict) -> None:
        notes = []
        if not data.get("gpu", {}).get("sclk_trustworthy", True):
            notes.append(
                "La fréquence GPU affichée est fausse : la table pp_dpm_sclk ne "
                "remonte plus de valeur correcte une fois les 8 cœurs débloqués. "
                "Lisez-la avec amdgpu_top ou nvtop."
            )
        if not data.get("fan", {}).get("driver"):
            notes.append(
                "Aucun pilote Nuvoton chargé : ni températures ni vitesse de "
                "ventilation. Installez le module « sensors » ou « fan-control »."
            )
        if "vram_temp" in data.get("unavailable", []):
            notes.append(
                "Cette carte n'a pas de sonde de température VRAM — la valeur "
                "n'existe pas, elle n'est pas manquante."
            )

        child = self._notes.get_first_child()
        while child is not None:
            self._notes.remove(child)
            child = self._notes.get_first_child()

        for note in notes:
            self._notes.append(Adw.Banner(title=note, revealed=True))
