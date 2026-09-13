#!/usr/bin/env bats
#
# Mutually exclusive modules. One driver owns the Nuvoton chip: nct6683 reads,
# nct6687 reads and writes. Loading both leaves neither working.

load helper

setup() {
	sandbox_setup
	lib_source
	fake_bc250
}

fan_profile() {
	write_config <<-EOC
		BC250_SENSORS=0
		BC250_FAN_CONTROL=1
		BC250_FAN_PWM=auto
		BC250_ACPI=0
	EOC
}

@test "fan control refuses to install over the read-only sensor driver" {
	write_config <<-EOC
		BC250_SENSORS=1
		BC250_ACPI=0
	EOC
	bc250ctl install sensors

	fan_profile
	run bc250ctl install fan-control
	[ "$status" -ne 0 ]
	[[ $output == *"claim the same hardware"* ]]
	[[ $output == *"bc250ctl revert sensors"* ]]
}

@test "the config is rejected before anything is touched when both are asked for" {
	write_config <<-EOC
		BC250_SENSORS=1
		BC250_FAN_CONTROL=1
	EOC
	run bc250ctl status
	[ "$status" -ne 0 ]
	[[ $output == *"same chip"* ]]
	[[ $output == *"BC250_SENSORS=0"* ]]
}

@test "reverting the sensors clears the way for fan control" {
	write_config <<-EOC
		BC250_SENSORS=1
		BC250_ACPI=0
	EOC
	bc250ctl install sensors
	bc250ctl revert sensors

	fan_profile
	run bc250ctl install fan-control
	[ "$status" -eq 0 ]
	[ -f "$BC250_PREFIX/etc/modprobe.d/99-bc250-fan.conf" ]
	grep -q 'nct6687' "$BC250_PREFIX/etc/modules-load.d/99-bc250-fan.conf"
}

@test "installing fan control takes the read-only drop-ins away itself" {
	write_config <<-EOC
		BC250_SENSORS=1
		BC250_ACPI=0
	EOC
	bc250ctl install sensors
	[ -f "$BC250_PREFIX/etc/modprobe.d/99-bc250-sensors.conf" ]

	# Same switch, but reached through configure, which skips the guard.
	fan_profile
	bc250ctl configure fan-control

	[ ! -f "$BC250_PREFIX/etc/modprobe.d/99-bc250-sensors.conf" ]
	[ ! -f "$BC250_PREFIX/etc/modules-load.d/99-bc250-sensors.conf" ]
	[ -f "$BC250_PREFIX/etc/modprobe.d/99-bc250-fan.conf" ]
}

@test "'install all' never stacks the two drivers" {
	use_profile balanced
	bc250ctl install all

	local sensors=0 fan=0
	[ -f "$BC250_PREFIX/etc/modprobe.d/99-bc250-sensors.conf" ] && sensors=1
	[ -f "$BC250_PREFIX/etc/modprobe.d/99-bc250-fan.conf" ] && fan=1
	[ $(( sensors + fan )) -eq 1 ]
}

@test "a fixed duty cycle gets a unit that reapplies it at boot" {
	write_config <<-EOC
		BC250_SENSORS=0
		BC250_FAN_CONTROL=1
		BC250_FAN_PWM=140
		BC250_ACPI=0
	EOC
	bc250ctl install fan-control

	[ -f "$BC250_PREFIX/etc/systemd/system/bc250ctl-fan.service" ]
	grep -q ' 140$' "$BC250_PREFIX/etc/systemd/system/bc250ctl-fan.service"
	[ -x "$BC250_PREFIX/usr/local/bin/bc250ctl-fan-duty" ]
}

@test "a duty cycle outside 0-255 is refused" {
	write_config <<-EOC
		BC250_SENSORS=0
		BC250_FAN_CONTROL=1
		BC250_FAN_PWM=999
	EOC
	run bc250ctl install fan-control
	[ "$status" -ne 0 ]
	[[ $output == *"BC250_FAN_PWM"* ]]
}

@test "auto leaves the curve to CoolerControl, with no unit of ours" {
	fan_profile
	bc250ctl install fan-control
	[ ! -f "$BC250_PREFIX/etc/systemd/system/bc250ctl-fan.service" ]
}

@test "the read-only driver is blacklisted, not merely unconfigured" {
	fan_profile
	bc250ctl install fan-control

	# Removing our drop-in is not enough: nct6683 is in-tree and would be
	# free to bind first.
	grep -q '^blacklist nct6683$' "$BC250_PREFIX/etc/modprobe.d/99-bc250-fan.conf"
}
