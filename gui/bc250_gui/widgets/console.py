"""A scrollback pane for what an elevated action is printing."""

from __future__ import annotations

from gi.repository import Gtk


class Console(Gtk.ScrolledWindow):
    def __init__(self, **kwargs):
        super().__init__(vexpand=True, **kwargs)
        self._view = Gtk.TextView(
            editable=False, cursor_visible=False, monospace=True,
            wrap_mode=Gtk.WrapMode.WORD_CHAR,
        )
        self._view.add_css_class("console")
        self._buffer = self._view.get_buffer()
        self.set_child(self._view)
        self.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.AUTOMATIC)

    def append(self, text: str) -> None:
        end = self._buffer.get_end_iter()
        self._buffer.insert(end, text if text.endswith("\n") else text + "\n")
        # Follow the tail, which is where the interesting part is.
        self._view.scroll_to_mark(self._buffer.get_insert(), 0.0, True, 0.0, 1.0)

    def clear(self) -> None:
        self._buffer.set_text("")

    @property
    def text(self) -> str:
        start, end = self._buffer.get_bounds()
        return self._buffer.get_text(start, end, False)
