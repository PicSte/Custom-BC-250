#!/usr/bin/env bats
#
# The rules that keep modules from contradicting each other: a CPU overclock
# is not valid across a change in core count or GPU routing, and it should not
# be calibrated before either is settled.

load helper

setup() {
	sandbox_setup
	lib_source
	fake_bc250
	have_umr
}

# oc_installed — put an already-calibrated overclock in place.
oc_installed() {
	unit_file bc250-smu-oc.service
	printf 'frequency = 3700\n' >"$BC250_PREFIX/etc/bc250-smu-oc.conf"
}

@test "unlocking CPU cores marks an existing overclock stale" {
	use_profile max
	oc_installed

	run bc250ctl install cpu-cores
	[ "$status" -eq 0 ]
	[[ $output == *"60-cpu-oc is now stale"* ]]

	run state_file
	[[ $output == *"stale.60-cpu-oc=1"* ]]
}

@test "changing GPU routing marks an existing overclock stale" {
	use_profile max
	oc_installed

	run bc250ctl install gpu-cu
	[ "$status" -eq 0 ]
	run state_file
	[[ $output == *"stale.60-cpu-oc=1"* ]]
}

@test "a stale overclock shows up in status and fails verification" {
	use_profile max
	oc_installed
	bc250ctl install cpu-cores

	run bc250ctl status
	[[ $output == *stale* ]]

	run bc250ctl verify cpu-oc
	[ "$status" -ne 0 ]
	[[ $output == *"calibrated before"* ]]
}

@test "the overclock refuses to calibrate before the core count is settled" {
	# Profile asks for 8 cores, but the unlock has not been applied.
	use_profile max

	run bc250ctl install cpu-oc
	[ "$status" -ne 0 ]
	[[ $output == *"requires 50-cpu-cores"* ]]
}

@test "with the core count settled, the dependency is satisfied" {
	use_profile max
	bc250ctl install cpu-cores
	bc250ctl install gpu-cu

	# Stand in for the venv the real install would have created.
	mkdir -p "$BC250_PREFIX/var/lib/bc250ctl/venv/bin"
	ln -sf "$REPO_ROOT/tests/mocks/bc250-detect" "$BC250_PREFIX/var/lib/bc250ctl/venv/bin/bc250-detect"
	ln -sf "$REPO_ROOT/tests/mocks/bc250-apply"  "$BC250_PREFIX/var/lib/bc250ctl/venv/bin/bc250-apply"

	run bc250ctl configure cpu-oc
	[ "$status" -eq 0 ]
	[ -f "$BC250_PREFIX/etc/bc250-smu-oc.conf" ]
	[ -f "$BC250_PREFIX/etc/systemd/system/bc250-smu-oc.service" ]
}

@test "re-calibrating clears the stale mark" {
	use_profile max
	bc250ctl install cpu-cores
	bc250ctl install gpu-cu
	mkdir -p "$BC250_PREFIX/var/lib/bc250ctl/venv/bin"
	ln -sf "$REPO_ROOT/tests/mocks/bc250-detect" "$BC250_PREFIX/var/lib/bc250ctl/venv/bin/bc250-detect"
	ln -sf "$REPO_ROOT/tests/mocks/bc250-apply"  "$BC250_PREFIX/var/lib/bc250ctl/venv/bin/bc250-apply"

	bc250ctl configure cpu-oc

	run state_file
	[[ $output != *"stale.60-cpu-oc=1"* ]]
}

@test "the calibration passes the profile's numbers through unchanged" {
	use_profile max
	bc250ctl install cpu-cores
	bc250ctl install gpu-cu
	mkdir -p "$BC250_PREFIX/var/lib/bc250ctl/venv/bin"
	ln -sf "$REPO_ROOT/tests/mocks/bc250-detect" "$BC250_PREFIX/var/lib/bc250ctl/venv/bin/bc250-detect"
	ln -sf "$REPO_ROOT/tests/mocks/bc250-apply"  "$BC250_PREFIX/var/lib/bc250ctl/venv/bin/bc250-apply"
	bc250ctl configure cpu-oc

	run calls
	[[ $output == *"bc250-detect -f 3700 -v 1231 -t 90"* ]]
}
