"""The only place that talks to bc250ctl.

Everything the interface knows comes through here: the module graph, the
settings schema, live readings. Nothing else in the application shells out, so
there is exactly one place to look when the engine and the UI disagree.

Reads are unprivileged and short, so they are synchronous. Actions need root,
go through pkexec, and stream their output, so they are asynchronous and never
block the GTK main loop.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
from dataclasses import dataclass
from typing import Callable, Sequence

#: Progress lines carry this prefix so they can be told apart from the log.
EVENT_PREFIX = "@@BC250 "

#: How long a read is allowed to take before we assume something is wrong.
READ_TIMEOUT = 20


class EngineError(Exception):
    """A bc250ctl call failed. The message is meant to be shown to a person."""

    def __init__(self, message: str, output: str = "", returncode: int = 1):
        super().__init__(message)
        self.message = message
        self.output = output
        self.returncode = returncode


@dataclass(frozen=True)
class Event:
    """One machine-readable progress line."""

    event: str
    module: str
    text: str

    @classmethod
    def parse(cls, line: str) -> "Event | None":
        if not line.startswith(EVENT_PREFIX):
            return None
        try:
            data = json.loads(line[len(EVENT_PREFIX):])
        except json.JSONDecodeError:
            return None
        return cls(
            event=str(data.get("event", "")),
            module=str(data.get("module", "")),
            text=str(data.get("text", "")),
        )


def find_bc250ctl() -> str:
    """Locate the engine.

    Checked-out repository first, so running the GUI from a clone drives the
    code next to it rather than an older copy under /usr/local.
    """
    override = os.environ.get("BC250CTL")
    if override:
        return override

    here = os.path.dirname(os.path.abspath(__file__))
    sibling = os.path.normpath(os.path.join(here, "..", "..", "bc250ctl"))
    if os.access(sibling, os.X_OK):
        return sibling

    found = shutil.which("bc250ctl")
    if found:
        return found

    raise EngineError(
        "bc250ctl introuvable. Installez-le avec ./install.sh, "
        "ou pointez la variable BC250CTL sur son chemin."
    )


class Engine:
    def __init__(self, path: str | None = None, pkexec: str = "pkexec"):
        self.path = path or find_bc250ctl()
        self.pkexec = pkexec

    # ----------------------------------------------------------- reading --

    def _read(self, *args: str) -> str:
        try:
            proc = subprocess.run(
                [self.path, *args],
                capture_output=True,
                text=True,
                timeout=READ_TIMEOUT,
            )
        except subprocess.TimeoutExpired as exc:
            raise EngineError(f"bc250ctl {' '.join(args)} n'a pas répondu") from exc
        except OSError as exc:
            raise EngineError(f"impossible de lancer {self.path}: {exc}") from exc

        if proc.returncode != 0:
            # stderr carries the human-readable reason; keep it, it is the
            # whole point of the engine validating things.
            raise EngineError(
                _first_meaningful_line(proc.stderr) or f"bc250ctl {args[0]} a échoué",
                output=proc.stderr,
                returncode=proc.returncode,
            )
        return proc.stdout

    def _read_json(self, *args: str) -> dict:
        raw = self._read(*args)
        try:
            return json.loads(raw)
        except json.JSONDecodeError as exc:
            raise EngineError(
                f"bc250ctl {args[0]} n'a pas renvoyé du JSON valide", output=raw
            ) from exc

    def catalog(self) -> dict:
        return self._read_json("catalog", "--json")

    def config(self) -> dict:
        return self._read_json("config", "--json")

    def profiles(self) -> dict:
        return self._read_json("profiles", "--json")

    def telemetry(self) -> dict:
        return self._read_json("telemetry", "--json")

    def doctor(self) -> str:
        """The diagnostic report. Never raises on a bad configuration: doctor
        is what you read when things are wrong."""
        try:
            return self._read("doctor")
        except EngineError as exc:
            return exc.output or exc.message

    def config_diff(self, assignments: Sequence[str]) -> tuple[bool, str]:
        """Preview a settings change. Returns (valid, rendered text)."""
        try:
            proc = subprocess.run(
                [self.path, "config", "diff", *assignments],
                capture_output=True,
                text=True,
                timeout=READ_TIMEOUT,
            )
        except (subprocess.TimeoutExpired, OSError) as exc:
            raise EngineError(f"impossible de prévisualiser: {exc}") from exc

        rendered = (proc.stdout + proc.stderr).strip()
        return proc.returncode == 0, rendered

    # ------------------------------------------------------------ acting --

    def privileged_argv(self, args: Sequence[str]) -> list[str]:
        """The command line for an elevated action.

        --yes because pkexec drops the environment, so BC250_ASSUME_YES would
        not survive; --events so the interface can follow progress.
        """
        return [self.pkexec, self.path, "--yes", "--events", *args]

    def run_privileged(
        self,
        args: Sequence[str],
        on_line: Callable[[str], None],
        on_event: Callable[[Event], None],
        on_done: Callable[[int], None],
    ) -> None:
        """Run an elevated action, streaming its output.

        Uses Gio so the GTK main loop keeps turning; gi is imported here so
        that the reading half of this module stays testable without GTK.
        """
        from gi.repository import Gio, GLib  # noqa: PLC0415  (deliberate)

        argv = self.privileged_argv(args)
        proc = Gio.Subprocess.new(
            argv, Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_MERGE
        )
        stream = Gio.DataInputStream.new(proc.get_stdout_pipe())

        def read_next(*_a):
            stream.read_line_async(GLib.PRIORITY_DEFAULT, None, on_read)

        def on_read(source, result):
            try:
                raw, _length = source.read_line_finish(result)
            except GLib.Error:
                raw = None

            if raw is None:
                proc.wait_async(None, lambda p, r: on_done(_exit_status(p, r)))
                return

            line = raw.decode("utf-8", "replace") if isinstance(raw, bytes) else str(raw)
            event = Event.parse(line)
            if event is not None:
                on_event(event)
            else:
                on_line(line)
            read_next()

        read_next()


def _exit_status(proc, result) -> int:
    from gi.repository import GLib  # noqa: PLC0415

    try:
        proc.wait_finish(result)
    except GLib.Error:
        return 1
    if proc.get_if_exited():
        return proc.get_exit_status()
    return 1


def _first_meaningful_line(text: str) -> str:
    """The first line of an error that actually says something.

    bc250ctl marks errors with a heavy cross and may print progress before
    them; the last error line is the one that explains the failure.
    """
    errors = [ln.strip() for ln in text.splitlines() if ln.strip().startswith("✘")]
    if errors:
        return errors[-1].lstrip("✘ ").strip()
    lines = [ln.strip() for ln in text.splitlines() if ln.strip()]
    return lines[-1] if lines else ""
