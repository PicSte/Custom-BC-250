"""The rules the interface renders: blocked, conflicting, what to install first."""

from __future__ import annotations

from bc250_gui.model import Catalog, Module, Settings, State


def load(engine) -> Catalog:
    return Catalog.from_json(engine.catalog())


def test_the_catalogue_is_read_whole(engine, profile):
    profile("balanced")
    catalog = load(engine)
    assert catalog.profile == "balanced"
    assert catalog.hardware.bc250 and catalog.hardware.gpu_card == "card1"
    assert len(catalog.modules) == 9


def test_modules_resolve_by_either_name(engine, profile):
    profile("balanced")
    catalog = load(engine)
    assert catalog.get("gpu-cu") is catalog.get("40-gpu-cu")
    assert catalog.get("nonsense") is None


def test_a_module_whose_requirement_is_missing_is_blocked(engine, profile):
    profile("balanced")          # asks for 8 cores, ACPI not applied yet
    catalog = load(engine)

    cores = catalog.get("50-cpu-cores")
    assert catalog.state(cores) is State.BLOCKED
    assert [m.id for m in catalog.unmet_requirements(cores)] == ["15-acpi"]


def test_the_install_chain_is_in_the_order_the_engine_applies_it(engine, profile):
    profile("max")
    catalog = load(engine)

    chain = catalog.install_chain(catalog.get("60-cpu-oc"))
    ids = [m.id for m in chain]
    # Requirements first, transitively, and never out of catalogue order.
    assert ids == ["15-acpi", "40-gpu-cu", "50-cpu-cores", "60-cpu-oc"]


def test_the_chain_collapses_once_the_requirements_are_in_place(engine, profile, run_engine):
    profile("balanced")
    run_engine("install", "acpi")
    catalog = load(engine)

    chain = catalog.install_chain(catalog.get("50-cpu-cores"))
    assert [m.id for m in chain] == ["50-cpu-cores"]


def test_a_conflict_is_seen_from_the_side_that_wants_to_install(engine, profile, sandbox, run_engine):
    (sandbox / "etc/bc250ctl/config.env").write_text(
        "BC250_SENSORS=1\nBC250_ACPI=0\n"
    )
    run_engine("install", "sensors")

    (sandbox / "etc/bc250ctl/config.env").write_text(
        "BC250_SENSORS=0\nBC250_FAN_CONTROL=1\nBC250_ACPI=0\n"
    )
    catalog = load(engine)

    fan = catalog.get("25-fan-control")
    assert catalog.state(fan) is State.CONFLICT
    assert [m.id for m in catalog.active_conflicts(fan)] == ["20-sensors"]


def test_a_stale_module_outranks_everything_else_it_might_be(engine, profile, run_engine):
    profile("max")
    run_engine("install", "acpi")
    # Put an overclock in place, then change the core count under it.
    unit = "bc250-smu-oc.service"
    import os
    root = os.environ["BC250_PREFIX"]
    open(f"{root}/etc/systemd/system/{unit}", "w").write("[Unit]\nDescription=x\n")
    open(f"{root}/etc/bc250-smu-oc.conf", "w").write("frequency = 3700\n")
    run_engine("install", "cpu-cores")

    catalog = load(engine)
    assert catalog.state(catalog.get("60-cpu-oc")) is State.STALE


def test_attention_lists_the_worst_first(engine, profile):
    profile("balanced")
    catalog = load(engine)
    states = [catalog.state(m) for m in catalog.attention()]
    severities = [
        {State.CONFLICT: 0, State.STALE: 1, State.BLOCKED: 2, State.TODO: 3}[s]
        for s in states
    ]
    assert severities == sorted(severities)
    assert State.OK not in states


def test_state_of_a_satisfied_module(engine, profile, run_engine):
    profile("safe")
    run_engine("install", "acpi")
    catalog = load(engine)
    assert catalog.state(catalog.get("15-acpi")) is State.OK


def _module(**kw) -> Module:
    base = dict(
        id="99-x", name="x", description="", stage="runtime", risk="low",
        upstream="", requires=(), conflicts=(), invalidates=(),
        needs_smu=False, unattended=True, active=False,
        matches_config=False, stale=False, status="",
    )
    base.update(kw)
    return Module(**base)


def test_a_requirement_naming_an_unknown_module_is_ignored_not_fatal():
    catalog = Catalog(modules=[_module(requires=("does-not-exist",))])
    assert catalog.unmet_requirements(catalog.modules[0]) == []


class TestSettings:
    def test_reads_schema_values_and_limits(self, engine, profile):
        profile("balanced")
        settings = Settings.from_json(engine.config())

        assert settings.get("BC250_CPU_OC_VID").type == "int0"
        assert settings.values["BC250_CPU_CORES"] == "8"
        assert settings.sources["BC250_ALLOW_EXTREME_VID"] == "default"
        assert settings.limits["vid_safe_max"] == 1275

    def test_every_setting_belongs_to_a_group(self, engine, profile):
        profile("balanced")
        settings = Settings.from_json(engine.config())
        grouped = sum(len(v) for v in settings.by_module().values())
        assert grouped == len(settings.schema)

    def test_the_voltage_ceiling_offered_is_the_one_the_engine_enforces(self, engine, profile):
        profile("max")
        settings = Settings.from_json(engine.config())
        vid = settings.get("BC250_CPU_OC_VID")

        # The schema's own maximum is the hardware limit; the interface must
        # not offer it until the override is on, or it would propose a value
        # the engine refuses.
        assert vid.maximum == 1325
        assert settings.effective_maximum(vid) == 1275
        assert settings.effective_maximum(vid, unlocked=True) == 1325

    def test_other_settings_are_not_affected_by_that_rule(self, engine, profile):
        profile("max")
        settings = Settings.from_json(engine.config())
        freq = settings.get("BC250_CPU_OC_FREQ")
        assert settings.effective_maximum(freq) == freq.maximum

    def test_changes_lists_only_what_differs(self, engine, profile):
        profile("balanced")
        settings = Settings.from_json(engine.config())

        edited = dict(settings.values)
        edited["BC250_GOV_FREQ_MAX"] = "1600"
        assert settings.changes(edited) == ["BC250_GOV_FREQ_MAX=1600"]

        assert settings.changes(dict(settings.values)) == []

    def test_changes_come_back_in_schema_order(self, engine, profile):
        profile("balanced")
        settings = Settings.from_json(engine.config())
        edited = dict(settings.values)
        edited["BC250_DISABLE_ZRAM"] = "0"
        edited["BC250_ACPI"] = "0"
        # ACPI is declared before the quirk flags, and that is the order the
        # engine will see them in.
        assert settings.changes(edited) == ["BC250_ACPI=0", "BC250_DISABLE_ZRAM=0"]
