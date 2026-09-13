#!/usr/bin/env bats
#
# The diagnostic guards. They advise, they never block — doctor is what you
# run when something is already wrong.

load helper

setup() {
	sandbox_setup
	lib_source
	fake_bc250
	use_profile safe
	fake_kernel '6.18.18-200.fc42.x86_64'
}

mesa_version() { printf 'driverInfo = Mesa %s\n' "$1" >"$MOCK_STATE/vulkaninfo"; }

@test "a known-bad kernel is called out by name" {
	fake_kernel '6.17.9-200.fc42.x86_64'
	run bc250ctl doctor
	[ "$status" -eq 0 ]
	[[ $output == *"known to break the BC-250 GPU"* ]]
	[[ $output == *"6.17.8"* ]]
	[[ $output == *"6.18.18"* ]]   # and says where to go instead
}

@test "the other known-bad range is caught too" {
	fake_kernel '6.15.3-200.fc42.x86_64'
	run bc250ctl doctor
	[[ $output == *"known to break"* ]]
}

@test "a kernel just outside the bad range is not flagged" {
	fake_kernel '6.17.11-200.fc42.x86_64'
	run bc250ctl doctor
	[[ $output != *"known to break"* ]]
}

@test "Mesa below the minimum is called too old" {
	mesa_version 24.3.0
	run bc250ctl doctor
	[[ $output == *"TOO OLD"* ]]
	[[ $output == *"25.1.0"* ]]
}

@test "Mesa between the minimum and the recommendation says so" {
	mesa_version 25.1.5
	run bc250ctl doctor
	[[ $output == *"works, but"* ]]
	[[ $output == *"25.3.0"* ]]
}

@test "a current Mesa is reported without comment" {
	mesa_version 25.3.6
	run bc250ctl doctor
	[[ $output == *"mesa            25.3.6"* ]]
	[[ $output != *"TOO OLD"* ]]
	[[ $output != *"works, but"* ]]
}

@test "the DisplayPort audio bug is flagged on a kernel that predates the fix" {
	fake_kernel '6.18.18-200.fc42.x86_64'
	run bc250ctl doctor
	[[ $output == *"predates the fix"* ]]
	[[ $output == *"6.19.10"* ]]
	[[ $output == *"passive adapter"* ]]
}

@test "a kernel carrying the fix says so instead" {
	fake_kernel '6.19.12-200.fc43.x86_64'
	run bc250ctl doctor
	[[ $output == *"carries the clock fix"* ]]
	[[ $output != *"predates the fix"* ]]
}

@test "an active IOMMU is reported as a problem" {
	mkdir -p "$BC250_PREFIX/sys/class/iommu/ivhd0"
	run bc250ctl doctor
	[[ $output == *"IOMMU           ACTIVE"* ]]
	[[ $output == *"disable it in the BIOS"* ]]
}

@test "doctor reports an invalid configuration rather than dying on it" {
	write_config <<-EOC
		BC250_SENSORS=1
		BC250_FAN_CONTROL=1
	EOC
	run bc250ctl doctor
	[ "$status" -eq 0 ]
	[[ $output == *"configuration    INVALID"* ]]
	[[ $output == *"same chip"* ]]
}

@test "a healthy system gets a single clean line" {
	mesa_version 25.3.6
	fake_kernel '6.19.12-200.fc43.x86_64'
	run bc250ctl doctor
	[[ $output == *"no known-bad kernel, Mesa or IOMMU problem"* ]]
}
