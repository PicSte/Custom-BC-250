"""The catalogue and the settings schema, as Python objects.

Pure data and pure logic: no GTK here, so the rules the interface relies on —
what is blocked, what conflicts, what has to be installed first — can be tested
without a display.

Nothing in this file decides *policy*. The graph comes from the engine; this
only reads it and answers questions about it.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum
from typing import Iterable


class State(Enum):
    """What a module's row should say."""

    OK = "ok"              # applied and matching the configuration
    OFF = "off"            # matching the configuration by being switched off
    TODO = "todo"          # wants applying
    STALE = "stale"        # applied, but calibrated under different conditions
    BLOCKED = "blocked"    # something it requires is not in place
    CONFLICT = "conflict"  # something it is exclusive with is active


#: Ordered worst-first, for sorting attention.
SEVERITY = {
    State.CONFLICT: 0,
    State.STALE: 1,
    State.BLOCKED: 2,
    State.TODO: 3,
    State.OK: 4,
    State.OFF: 5,
}


@dataclass(frozen=True)
class Module:
    id: str
    name: str
    description: str
    stage: str
    risk: str
    upstream: str
    requires: tuple[str, ...]
    conflicts: tuple[str, ...]
    invalidates: tuple[str, ...]
    needs_smu: bool
    unattended: bool
    active: bool
    matches_config: bool
    stale: bool
    status: str

    @classmethod
    def from_json(cls, data: dict) -> "Module":
        return cls(
            id=data["id"],
            name=data["name"],
            description=data["description"],
            stage=data["stage"],
            risk=data["risk"],
            upstream=data.get("upstream", ""),
            requires=tuple(data.get("requires", ())),
            conflicts=tuple(data.get("conflicts", ())),
            invalidates=tuple(data.get("invalidates", ())),
            needs_smu=bool(data.get("needs_smu", False)),
            unattended=bool(data.get("unattended", True)),
            active=bool(data.get("active", False)),
            matches_config=bool(data.get("matches_config", False)),
            stale=bool(data.get("stale", False)),
            status=data.get("status", ""),
        )


@dataclass
class Hardware:
    bc250: bool = False
    gpu_card: str = ""
    cpu_cores: int = 0


@dataclass
class Catalog:
    modules: list[Module] = field(default_factory=list)
    profile: str = ""
    reboot_required: bool = False
    hardware: Hardware = field(default_factory=Hardware)

    @classmethod
    def from_json(cls, data: dict) -> "Catalog":
        hw = data.get("hardware", {})
        return cls(
            modules=[Module.from_json(m) for m in data.get("modules", ())],
            profile=data.get("profile", ""),
            reboot_required=bool(data.get("reboot_required", False)),
            hardware=Hardware(
                bc250=bool(hw.get("bc250", False)),
                gpu_card=hw.get("gpu_card") or "",
                cpu_cores=int(hw.get("cpu_cores") or 0),
            ),
        )

    # ------------------------------------------------------------ lookup --

    def get(self, key: str) -> Module | None:
        """By full id or short name — the engine accepts both, so we do too."""
        for module in self.modules:
            if module.id == key or module.name == key:
                return module
        return None

    def by_stage(self, stage: str) -> list[Module]:
        return [m for m in self.modules if m.stage == stage]

    # ------------------------------------------------------------- rules --

    def unmet_requirements(self, module: Module) -> list[Module]:
        """Required modules that are not in place, in catalogue order.

        Mirrors the engine's own check, which reads a requirement as satisfied
        when the required module matches its configuration.
        """
        unmet = []
        for dep_id in module.requires:
            dep = self.get(dep_id)
            if dep is not None and not dep.matches_config:
                unmet.append(dep)
        return self._in_order(unmet)

    def active_conflicts(self, module: Module) -> list[Module]:
        """Modules this one is exclusive with that are currently applied."""
        found = []
        for other_id in module.conflicts:
            other = self.get(other_id)
            if other is not None and other.active:
                found.append(other)
        return self._in_order(found)

    def state(self, module: Module) -> State:
        if module.stale:
            return State.STALE
        if not module.matches_config and self.active_conflicts(module):
            return State.CONFLICT
        if not module.matches_config and self.unmet_requirements(module):
            return State.BLOCKED
        if not module.matches_config:
            return State.TODO
        # Matching the configuration by not being applied at all is a
        # different thing from being applied, and saying "applied" for a
        # module the profile switched off is simply wrong.
        return State.OK if module.active else State.OFF

    def install_chain(self, module: Module) -> list[Module]:
        """Everything to install, in order, for this module to be in place.

        Requirements first, transitively, then the module itself. The engine
        applies modules in catalogue order, so the chain is returned that way
        and reads the same as what will actually happen.
        """
        collected: list[Module] = []

        def walk(current: Module) -> None:
            for dep in self.unmet_requirements(current):
                if dep not in collected:
                    walk(dep)
            if current not in collected:
                collected.append(current)

        walk(module)
        return self._in_order(collected)

    def attention(self) -> list[Module]:
        """Modules worth looking at, worst first."""
        interesting = [
            m for m in self.modules if self.state(m) not in (State.OK, State.OFF)
        ]
        return sorted(interesting, key=lambda m: (SEVERITY[self.state(m)], m.id))

    def _in_order(self, modules: Iterable[Module]) -> list[Module]:
        order = {m.id: i for i, m in enumerate(self.modules)}
        return sorted(set(modules), key=lambda m: order.get(m.id, 0))


# ------------------------------------------------------------- settings --


@dataclass(frozen=True)
class Setting:
    key: str
    type: str
    default: str
    module: str
    label: str
    unit: str
    help: str
    choices: tuple[str, ...] = ()
    minimum: int | None = None
    maximum: int | None = None

    @classmethod
    def from_json(cls, data: dict) -> "Setting":
        return cls(
            key=data["key"],
            type=data["type"],
            default=data.get("default", ""),
            module=data.get("module", ""),
            label=data.get("label", data["key"]),
            unit=data.get("unit", ""),
            help=data.get("help", ""),
            choices=tuple(data.get("choices", ())),
            minimum=data.get("min"),
            maximum=data.get("max"),
        )


@dataclass
class Settings:
    schema: list[Setting] = field(default_factory=list)
    values: dict[str, str] = field(default_factory=dict)
    sources: dict[str, str] = field(default_factory=dict)
    limits: dict[str, int] = field(default_factory=dict)
    path: str = ""

    @classmethod
    def from_json(cls, data: dict) -> "Settings":
        values = data.get("values", {})
        return cls(
            schema=[Setting.from_json(s) for s in data.get("schema", ())],
            values={k: str(v.get("value", "")) for k, v in values.items()},
            sources={k: str(v.get("source", "")) for k, v in values.items()},
            limits={k: int(v) for k, v in data.get("limits", {}).items()},
            path=data.get("path", ""),
        )

    def get(self, key: str) -> Setting | None:
        for setting in self.schema:
            if setting.key == key:
                return setting
        return None

    def by_module(self) -> dict[str, list[Setting]]:
        """Grouped the way the engine groups them, preserving schema order."""
        groups: dict[str, list[Setting]] = {}
        for setting in self.schema:
            groups.setdefault(setting.module, []).append(setting)
        return groups

    def effective_maximum(self, setting: Setting, unlocked: bool = False) -> int | None:
        """The highest value the interface should offer.

        The CPU voltage is the reason this exists: the engine refuses anything
        above the safe ceiling unless the override is set, so a slider that
        goes higher would be offering something that will be rejected.
        """
        if setting.key != "BC250_CPU_OC_VID":
            return setting.maximum
        if unlocked:
            return self.limits.get("vid_absolute_max", setting.maximum)
        return self.limits.get("vid_safe_max", setting.maximum)

    def changes(self, edited: dict[str, str]) -> list[str]:
        """KEY=VALUE for what actually differs, in schema order."""
        out = []
        for setting in self.schema:
            new = edited.get(setting.key)
            if new is None:
                continue
            if str(new) != self.values.get(setting.key, ""):
                out.append(f"{setting.key}={new}")
        return out
