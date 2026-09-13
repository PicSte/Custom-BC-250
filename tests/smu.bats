#!/usr/bin/env bats
#
# The SMU critical section.
#
# The governor and the core/overclock tools reach the SMU through the same PCI
# index/data window. Whatever else happens, an SMU write must not run with the
# governor live, and the governor must come back afterwards.

load helper

setup() {
	sandbox_setup
	lib_source
	fake_bc250
	have_umr
}

governor_running() {
	unit_file cyan-skillfish-governor-smu.service
	systemctl enable --now cyan-skillfish-governor-smu.service
	: >"$MOCK_STATE/calls"
}

order_of() { grep -n "$1" "$MOCK_STATE/calls" | head -1 | cut -d: -f1; }

@test "the governor is stopped before the write and started after" {
	governor_running

	smu_critical echo "writing to the SMU"

	local stop write start
	stop=$(order_of 'systemctl stop cyan-skillfish-governor-smu')
	start=$(order_of 'systemctl start cyan-skillfish-governor-smu')
	[ -n "$stop" ] && [ -n "$start" ]
	[ "$stop" -lt "$start" ]
}

@test "the governor comes back even when the write fails" {
	governor_running

	run smu_critical false
	[ "$status" -ne 0 ]           # the failure is propagated, not swallowed

	run grep -c 'systemctl start cyan-skillfish-governor-smu' "$MOCK_STATE/calls"
	[ "$output" -ge 1 ]
}

@test "a governor that was not running is left alone" {
	: >"$MOCK_STATE/calls"

	smu_critical true

	run grep -c 'systemctl stop cyan-skillfish-governor-smu' "$MOCK_STATE/calls"
	[ "$output" -eq 0 ]
	run grep -c 'systemctl start cyan-skillfish-governor-smu' "$MOCK_STATE/calls"
	[ "$output" -eq 0 ]
}

@test "the core unlock takes the lock" {
	use_profile balanced
	bc250ctl install acpi
	governor_running

	bc250ctl install cpu-cores

	local stop unlock start
	stop=$(order_of 'systemctl stop cyan-skillfish-governor-smu')
	unlock=$(order_of 'lm cpu-unlock')
	start=$(order_of 'systemctl start cyan-skillfish-governor-smu')
	[ -n "$stop" ] && [ -n "$unlock" ] && [ -n "$start" ]
	[ "$stop" -lt "$unlock" ]
	[ "$unlock" -lt "$start" ]
}

@test "the overclock calibration takes the lock" {
	use_profile max
	bc250ctl install acpi
	bc250ctl install cpu-cores
	bc250ctl install gpu-cu
	mkdir -p "$BC250_PREFIX/var/lib/bc250ctl/venv/bin"
	ln -sf "$REPO_ROOT/tests/mocks/bc250-detect" "$BC250_PREFIX/var/lib/bc250ctl/venv/bin/bc250-detect"
	ln -sf "$REPO_ROOT/tests/mocks/bc250-apply"  "$BC250_PREFIX/var/lib/bc250ctl/venv/bin/bc250-apply"
	governor_running

	bc250ctl configure cpu-oc

	local stop detect
	stop=$(order_of 'systemctl stop cyan-skillfish-governor-smu')
	detect=$(order_of 'bc250-detect')
	[ -n "$stop" ] && [ -n "$detect" ]
	[ "$stop" -lt "$detect" ]
}

@test "exactly the two SMU writers declare that they need the lock" {
	local id
	for id in $(module_ids); do
		if [[ $id == 50-cpu-cores || $id == 60-cpu-oc ]]; then
			module_call "$id" needs_smu
		else
			! module_call "$id" needs_smu
		fi
	done
}
