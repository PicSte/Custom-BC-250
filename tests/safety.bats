#!/usr/bin/env bats
#
# The guards: dry-run really is dry, register writes need a BC-250, installs
# are idempotent, and revert puts things back.

load helper

setup() {
	sandbox_setup
	lib_source
	have_umr
}

@test "--dry-run changes nothing on disk" {
	fake_bc250
	use_profile balanced

	run bc250ctl --dry-run install all
	[ "$status" -eq 0 ]
	[[ $output == *"[dry-run]"* ]]

	[ ! -s "$MOCK_STATE/kargs" ]
	[ ! -s "$MOCK_STATE/layered" ]
	[ ! -f "$BC250_PREFIX/etc/modprobe.d/99-bc250-sensors.conf" ]
	[ ! -f "$BC250_PREFIX/etc/systemd/system/bc250ctl-cpu-cores.service" ]
	[ ! -f "$BC250_PREFIX/var/lib/bc250ctl/state" ]
}

@test "register writes are refused when no BC-250 is present" {
	use_profile balanced          # no fake_bc250: this is some other machine
	run bc250ctl install gpu-cu
	[ "$status" -ne 0 ]
	[[ $output == *"no BC-250 GPU found"* ]]

	run bc250ctl install cpu-cores
	[ "$status" -ne 0 ]
}

@test "--force overrides detection for a board lspci gets wrong" {
	use_profile balanced
	run bc250ctl --force install gpu-cu
	[ "$status" -eq 0 ]
	[[ $output == *"--force was given"* ]]
}

@test "installing twice does not duplicate anything" {
	fake_bc250
	use_profile balanced

	bc250ctl install kargs
	bc250ctl install kargs
	run grep -c 'ttm.pages_limit=3959290' "$MOCK_STATE/kargs"
	[ "$output" -eq 1 ]

	bc250ctl install sensors
	bc250ctl install sensors
	run grep -c nct6683 "$BC250_PREFIX/etc/modules-load.d/99-bc250-sensors.conf"
	[ "$output" -eq 1 ]
}

@test "a second CU unlock does not stack a second boot service" {
	fake_bc250
	use_profile balanced
	bc250ctl install gpu-cu
	bc250ctl install gpu-cu
	run grep -c bc250-cu-live-manager.service "$MOCK_STATE/units-enabled"
	[ "$output" -le 1 ]
}

@test "revert takes the modules back to stock" {
	fake_bc250
	use_profile balanced
	bc250ctl install kargs acpi sensors gpu-cu cpu-cores

	run bc250ctl revert all
	[ "$status" -eq 0 ]

	[ ! -f "$BC250_PREFIX/etc/modprobe.d/99-bc250-sensors.conf" ]
	[ ! -f "$BC250_PREFIX/etc/systemd/system/bc250ctl-cpu-cores.service" ]
	[ ! -f "$BC250_PREFIX/etc/systemd/system/bc250-cu-live-manager.service" ]
	[ ! -s "$MOCK_STATE/kargs" ]

	run calls
	[[ $output == *"lm stock-dispatch"* ]]
}

@test "revert runs in reverse apply order" {
	fake_bc250
	use_profile balanced
	bc250ctl install all 2>/dev/null || true
	: >"$MOCK_STATE/calls"

	run bc250ctl revert all
	[ "$status" -eq 0 ]
	# The CU routing must be handed back before the governor's package goes.
	local cu_line gov_line
	cu_line=$(grep -n 'lm stock-dispatch' "$MOCK_STATE/calls" | head -1 | cut -d: -f1)
	gov_line=$(grep -n 'rpm-ostree uninstall' "$MOCK_STATE/calls" | head -1 | cut -d: -f1)
	[ -n "$cu_line" ] && [ -n "$gov_line" ] && [ "$cu_line" -lt "$gov_line" ]
}

@test "an unknown module name is an error, not a silent no-op" {
	run bc250ctl install nonsense
	[ "$status" -ne 0 ]
	[[ $output == *"unknown module"* ]]
}

@test "an unknown profile lists the real ones" {
	run bc250ctl --profile nope status
	[ "$status" -ne 0 ]
	[[ $output == *balanced* ]]
	[[ $output == *safe* ]]
}
