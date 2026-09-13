#!/usr/bin/env bats
#
# The rebuilt ACPI tables. Without them CPUs 12-15 come up with no idle states
# at all after the core unlock.

load helper

setup() {
	sandbox_setup
	lib_source
	fake_bc250
	write_config <<-EOC
		BC250_ACPI=1
		BC250_SENSORS=0
	EOC
}

cpio_path() { echo "$BC250_PREFIX/boot/SSDT_ACPI.cpio"; }
grub_conf() { echo "$BC250_PREFIX/etc/default/grub"; }

@test "both tables land in the archive at the path the kernel looks for" {
	bc250ctl install acpi

	[ -f "$(cpio_path)" ]
	grep -q 'kernel/firmware/acpi/SSDT-CST.aml' "$(cpio_path)"
	grep -q 'kernel/firmware/acpi/SSDT-PST.aml' "$(cpio_path)"
}

@test "GRUB is told to load the archive early, and regenerated" {
	bc250ctl install acpi

	grep -q '^GRUB_EARLY_INITRD_LINUX_CUSTOM=' "$(grub_conf)"
	grep -q 'SSDT_ACPI.cpio' "$(grub_conf)"
	run calls
	[[ $output == *"ujust regenerate-grub"* ]]
}

@test "installing twice does not append the GRUB line twice" {
	bc250ctl install acpi
	bc250ctl install acpi
	run grep -c '^GRUB_EARLY_INITRD_LINUX_CUSTOM=' "$(grub_conf)"
	[ "$output" -eq 1 ]
}

@test "a reboot is marked as needed" {
	bc250ctl install acpi
	run state_file
	[[ $output == *"reboot.required=1"* ]]
}

@test "verify fails while CPUs still report no idle states" {
	bc250ctl install acpi
	run bc250ctl verify acpi
	[ "$status" -ne 0 ]
	[[ $output == *"no idle states"* ]]
}

@test "verify passes once the tables are actually loaded" {
	bc250ctl install acpi
	acpi_tables_loaded
	run bc250ctl verify acpi
	[ "$status" -eq 0 ]
	[[ $output == *"every CPU has idle states"* ]]
}

@test "verify fails when the archive is missing entirely" {
	run bc250ctl verify acpi
	[ "$status" -ne 0 ]
	[[ $output == *"missing"* ]]
}

@test "revert removes the archive and the GRUB line" {
	bc250ctl install acpi
	bc250ctl revert acpi

	[ ! -f "$(cpio_path)" ]
	run grep -c '^GRUB_EARLY_INITRD_LINUX_CUSTOM=' "$(grub_conf)"
	[ "$output" -eq 0 ]
}

@test "8 cores without the tables is refused at the configuration level" {
	write_config <<-EOC
		BC250_CPU_CORES=8
		BC250_ACPI=0
	EOC
	run bc250ctl status
	[ "$status" -ne 0 ]
	[[ $output == *"BC250_ACPI=1"* ]]
	[[ $output == *"burn power"* ]]
}

@test "the tables are installed even on the safe profile" {
	use_profile safe
	run bash -c "grep '^BC250_ACPI=' '$BC250_PREFIX/etc/bc250ctl/config.env'"
	[ "$output" = "BC250_ACPI=1" ]
}

@test "the CPU governor is installed with the tables that make it possible" {
	bc250ctl install acpi

	local unit="$BC250_PREFIX/etc/systemd/system/bc250ctl-cpu-governor.service"
	[ -f "$unit" ]
	grep -q 'bc250ctl-cpu-governor schedutil' "$unit"
	[ -x "$BC250_PREFIX/usr/local/bin/bc250ctl-cpu-governor" ]
	grep -qx bc250ctl-cpu-governor.service "$MOCK_STATE/units-enabled"
}

@test "the governor choice from the profile is the one installed" {
	write_config <<-EOC
		BC250_ACPI=1
		BC250_CPU_GOVERNOR=performance
		BC250_SENSORS=0
	EOC
	bc250ctl install acpi
	grep -q 'bc250ctl-cpu-governor performance' \
		"$BC250_PREFIX/etc/systemd/system/bc250ctl-cpu-governor.service"
}

@test "none leaves the governor to the system" {
	bc250ctl install acpi
	[ -f "$BC250_PREFIX/etc/systemd/system/bc250ctl-cpu-governor.service" ]

	write_config <<-EOC
		BC250_ACPI=1
		BC250_CPU_GOVERNOR=none
		BC250_SENSORS=0
	EOC
	bc250ctl install acpi
	[ ! -f "$BC250_PREFIX/etc/systemd/system/bc250ctl-cpu-governor.service" ]
}

@test "the governor script refuses a governor the kernel does not offer" {
	bc250ctl install acpi
	run "$BC250_PREFIX/usr/local/bin/bc250ctl-cpu-governor" nonsense
	[ "$status" -ne 0 ]
}

@test "revert takes the governor unit away too" {
	bc250ctl install acpi
	bc250ctl revert acpi
	[ ! -f "$BC250_PREFIX/etc/systemd/system/bc250ctl-cpu-governor.service" ]
	[ ! -f "$BC250_PREFIX/usr/local/bin/bc250ctl-cpu-governor" ]
}

@test "verify complains when the governor unit is missing" {
	bc250ctl install acpi
	acpi_tables_loaded
	rm -f "$BC250_PREFIX/etc/systemd/system/bc250ctl-cpu-governor.service"

	run bc250ctl verify acpi
	[ "$status" -ne 0 ]
	[[ $output == *"governor CPU"* ]]
}
