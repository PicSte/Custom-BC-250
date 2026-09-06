#!/usr/bin/env bats
#
# Configuration validation — the layer that stands between a typo and a dead
# board.

load helper

setup() { sandbox_setup; lib_source; }

@test "defaults are the safe profile: nothing overclocked" {
	[ "$BC250_CPU_OC_FREQ" -eq 0 ]
	[ "$BC250_CPU_OC_VID" -eq 0 ]
	[ "$BC250_GPU_WGP_LAYOUT" = stock ]
	[ "$BC250_CPU_CORES" -eq 6 ]
	run config_validate
	[ "$status" -eq 0 ]
}

@test "every shipped profile validates" {
	for p in "$REPO_ROOT"/profiles/*.env; do
		( config_load "$p"; config_validate ) || {
			echo "profile failed: $p"
			return 1
		}
	done
}

@test "a frequency without a voltage cap is refused" {
	BC250_CPU_OC_FREQ=3900 BC250_CPU_OC_VID=0
	run config_validate
	[ "$status" -ne 0 ]
	[[ $output == *"will damage the board"* ]]
}

@test "voltage above the 1275 mV ceiling needs an explicit opt-in" {
	BC250_CPU_OC_FREQ=3700 BC250_CPU_OC_VID=1300
	run config_validate
	[ "$status" -ne 0 ]
	[[ $output == *"1275"* ]]

	BC250_ALLOW_EXTREME_VID=1
	run config_validate
	[ "$status" -eq 0 ]
}

@test "1325 mV is refused even with the opt-in" {
	BC250_CPU_OC_FREQ=3700 BC250_CPU_OC_VID=1400 BC250_ALLOW_EXTREME_VID=1
	run config_validate
	[ "$status" -ne 0 ]
	[[ $output == *"hardware limit"* ]]
	[[ $output == *"not overridable"* ]]
}

@test "frequency outside the SMU's own range is refused" {
	BC250_CPU_OC_VID=1200
	BC250_CPU_OC_FREQ=5000
	run config_validate
	[ "$status" -ne 0 ]

	BC250_CPU_OC_FREQ=2000
	run config_validate
	[ "$status" -ne 0 ]
}

@test "non-numeric input is rejected rather than coerced" {
	BC250_CPU_OC_VID='1200; rm -rf /'
	run config_validate
	[ "$status" -ne 0 ]
	[[ $output == *"whole number"* ]]
}

@test "inverted governor ranges are caught" {
	BC250_GOV_FREQ_MIN=1600 BC250_GOV_FREQ_MAX=1000
	run config_validate
	[ "$status" -ne 0 ]
	[[ $output == *exceeds* ]]
}

@test "core count must be 6 or 8" {
	BC250_CPU_CORES=7
	run config_validate
	[ "$status" -ne 0 ]
}
