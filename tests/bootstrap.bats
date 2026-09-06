#!/usr/bin/env bats
#
# The bootstrap: a fresh install has to survive the reboots that rpm-ostree
# forces, and it has to converge rather than loop.

load helper

setup() {
	sandbox_setup
	lib_source
	fake_bc250
	have_umr
}

resume_unit() { echo "$BC250_PREFIX/etc/systemd/system/bc250ctl-resume.service"; }

# reboot — what the reboot actually changes for us: layered packages become
# installed, and the extra CPU cores come online.
simulate_reboot() {
	local pkg
	while read -r pkg; do [[ -n $pkg ]] && layered_boot "$pkg"; done <"$MOCK_STATE/layered"
	[[ ${1:-} == with-cores ]] && fake_bc250 0000:01:00.0 16
	return 0
}

@test "stage 1 stops at the reboot and arms the resume unit" {
	run bc250ctl --profile balanced bootstrap
	[ "$status" -eq 0 ]
	[[ $output == *"a reboot is needed"* ]]

	[ -f "$(resume_unit)" ]
	grep -q 'resume' "$(resume_unit)"
	grep -qx bc250ctl-resume.service "$MOCK_STATE/units-enabled"

	run state_file
	[[ $output == *"bootstrap.phase=running"* ]]
}

@test "stage 1 applies kernel arguments and layers the governor" {
	bc250ctl --profile balanced bootstrap
	run cat "$MOCK_STATE/kargs"
	[[ $output == *"ttm.pages_limit=3959290"* ]]
	[[ $output == *"mitigations=off"* ]]
	run cat "$MOCK_STATE/layered"
	[[ $output == *cyan-skillfish-governor-smu* ]]
}

@test "the governor is configured after the reboot, not left half-installed" {
	bc250ctl --profile balanced bootstrap
	[ ! -f "$BC250_PREFIX/etc/cyan-skillfish-governor-smu/config.toml" ]

	simulate_reboot
	bc250ctl resume || true

	[ -f "$BC250_PREFIX/etc/cyan-skillfish-governor-smu/config.toml" ]
	grep -q 'max = 1500' "$BC250_PREFIX/etc/cyan-skillfish-governor-smu/config.toml"
}

@test "a full bootstrap converges and clears its own state" {
	bc250ctl --profile balanced bootstrap
	simulate_reboot
	bc250ctl resume            # applies the runtime stage, asks for one more reboot
	simulate_reboot with-cores
	run bc250ctl resume
	[ "$status" -eq 0 ]

	run state_file
	[[ $output != *bootstrap.phase* ]]
	[ ! -f "$(resume_unit)" ]
}

@test "the runtime stage unlocks the CUs and the cores" {
	bc250ctl --profile balanced bootstrap
	simulate_reboot
	bc250ctl resume

	run calls
	[[ $output == *"lm enable all"* ]]
	[[ $output == *"lm write-service-table"* ]]
	[[ $output == *"lm install-service"* ]]
	[[ $output == *"lm cpu-unlock"* ]]
	[ -f "$BC250_PREFIX/etc/systemd/system/bc250ctl-cpu-cores.service" ]
}

@test "an unattended resume defers the overclock calibration to a human" {
	bc250ctl --profile max bootstrap
	simulate_reboot
	run bc250ctl resume
	[[ $output == *"it needs a person present"* ]]
	[[ $output == *cpu-oc* ]]

	# ... and nothing was calibrated behind our back.
	run calls
	[[ $output != *bc250-detect* ]]
}

@test "a profile with no overclock does not nag about cpu-oc" {
	bc250ctl --profile balanced bootstrap
	simulate_reboot
	run bc250ctl resume
	[[ $output != *"it needs a person present"* ]]
}

@test "a bootstrap that keeps asking for reboots gives up instead of looping" {
	# Never let the layered packages land, so a reboot is owed every pass.
	bc250ctl --profile balanced bootstrap
	bc250ctl bootstrap
	bc250ctl bootstrap
	bc250ctl bootstrap
	run bc250ctl bootstrap
	[ "$status" -ne 0 ]
	[[ $output == *"Stopping rather than looping"* ]]
	[ ! -f "$(resume_unit)" ]
}
