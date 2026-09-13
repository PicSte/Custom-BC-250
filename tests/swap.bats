#!/usr/bin/env bats
#
# Swap. Turning zram off and stopping there leaves the board worse off than
# before, so the module has to say so and offer the documented replacement.

load helper

setup() {
	sandbox_setup
	lib_source
	fake_bc250
	unit_known swap-create@zram0.service
	systemctl enable swap-create@zram0.service
}

sysctl_file() { echo "$BC250_PREFIX/etc/sysctl.d/99-bc250ctl.conf"; }

@test "disabling zram with no swap left warns rather than staying quiet" {
	no_swap
	write_config <<-EOC
		BC250_DISABLE_ZRAM=1
		BC250_ACPI=0
		BC250_SENSORS=0
	EOC

	run bc250ctl install fixes
	[ "$status" -eq 0 ]
	[[ $output == *"aucun espace de swap"* ]]
	[[ $output == *"BC250_KARGS_ZSWAP"* ]]
}

@test "no warning when a swap file is already there" {
	fake_swap
	write_config <<-EOC
		BC250_DISABLE_ZRAM=1
		BC250_ACPI=0
		BC250_SENSORS=0
	EOC

	run bc250ctl install fixes
	[[ $output != *"aucun espace de swap"* ]]
}

@test "swappiness is written as a sysctl drop-in and applied now" {
	fake_swap
	write_config <<-EOC
		BC250_SWAPPINESS=180
		BC250_ACPI=0
		BC250_SENSORS=0
	EOC
	bc250ctl install fixes

	grep -q '^vm.swappiness = 180$' "$(sysctl_file)"
	run calls
	[[ $output == *"sysctl -q -w vm.swappiness=180"* ]]
}

@test "auto means we leave the system's value alone" {
	fake_swap
	write_config <<-EOC
		BC250_SWAPPINESS=180
		BC250_ACPI=0
		BC250_SENSORS=0
	EOC
	bc250ctl install fixes
	[ -f "$(sysctl_file)" ]

	write_config <<-EOC
		BC250_SWAPPINESS=auto
		BC250_ACPI=0
		BC250_SENSORS=0
	EOC
	bc250ctl install fixes
	[ ! -f "$(sysctl_file)" ]
}

@test "a swappiness outside the kernel's range is refused" {
	write_config <<-EOC
		BC250_SWAPPINESS=500
	EOC
	run bc250ctl install fixes
	[ "$status" -ne 0 ]
	[[ $output == *BC250_SWAPPINESS* ]]
}

@test "verify fails when the drop-in went missing" {
	fake_swap
	write_config <<-EOC
		BC250_SWAPPINESS=180
		BC250_ACPI=0
		BC250_SENSORS=0
	EOC
	bc250ctl install fixes
	rm -f "$(sysctl_file)"

	run bc250ctl verify fixes
	[ "$status" -ne 0 ]
	[[ $output == *swappiness* ]]
}

@test "revert puts zram back and drops our sysctl" {
	fake_swap
	write_config <<-EOC
		BC250_DISABLE_ZRAM=1
		BC250_SWAPPINESS=180
		BC250_ACPI=0
		BC250_SENSORS=0
	EOC
	bc250ctl install fixes

	bc250ctl revert fixes
	[ ! -f "$(sysctl_file)" ]
	grep -qx swap-create@zram0.service "$MOCK_STATE/units-enabled"
}
