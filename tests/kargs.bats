#!/usr/bin/env bats
#
# Kernel arguments. Their values are configurable now, so the module has to
# manage them by key rather than by fixed string.

load helper

setup() {
	sandbox_setup
	lib_source
	fake_bc250
	fake_kernel '6.18.18-200.fc42.x86_64'
}

kargs() { cat "$MOCK_STATE/kargs"; }

@test "the TTM limits come with the GTT size that makes them useful" {
	use_profile balanced
	bc250ctl install kargs

	run kargs
	[[ $output == *"ttm.pages_limit=3959290"* ]]
	[[ $output == *"ttm.page_pool_size=3959290"* ]]
	[[ $output == *"amdgpu.gttsize=14750"* ]]
}

@test "the TTM limit is configurable, for a different VRAM split" {
	write_config <<-EOC
		BC250_KARGS_TTM=1
		BC250_TTM_PAGES_LIMIT=3014656
		BC250_ACPI=0
	EOC
	bc250ctl install kargs

	run kargs
	[[ $output == *"ttm.pages_limit=3014656"* ]]
	[[ $output != *"3959290"* ]]
}

@test "changing the limit replaces the old value instead of stacking" {
	write_config <<-EOC
		BC250_KARGS_TTM=1
		BC250_TTM_PAGES_LIMIT=3959290
		BC250_ACPI=0
	EOC
	bc250ctl install kargs

	write_config <<-EOC
		BC250_KARGS_TTM=1
		BC250_TTM_PAGES_LIMIT=3014656
		BC250_ACPI=0
	EOC
	bc250ctl revert kargs
	bc250ctl install kargs

	run grep -c 'ttm.pages_limit' "$MOCK_STATE/kargs"
	[ "$output" -eq 1 ]
	run kargs
	[[ $output == *"ttm.pages_limit=3014656"* ]]
}

@test "zswap is opt-in and brings its whole set of arguments" {
	write_config <<-EOC
		BC250_KARGS_ZSWAP=1
		BC250_ACPI=0
	EOC
	bc250ctl install kargs

	run kargs
	[[ $output == *"zswap.enabled=1"* ]]
	[[ $output == *"zswap.compressor=lz4"* ]]
	[[ $output == *"zswap.zpool=zsmalloc"* ]]
}

@test "sg_display is only set on a kernel old enough to have the option" {
	fake_kernel '6.9.12-200.fc40.x86_64'
	write_config <<-EOC
		BC250_ACPI=0
	EOC
	bc250ctl install kargs
	run kargs
	[[ $output == *"amdgpu.sg_display=0"* ]]
}

@test "sg_display is left alone on a current kernel" {
	fake_kernel '6.18.18-200.fc42.x86_64'
	write_config <<-EOC
		BC250_ACPI=0
	EOC
	bc250ctl install kargs
	run kargs
	[[ $output != *"sg_display"* ]]
}

@test "revert removes every argument we manage, whatever its value" {
	use_profile max
	bc250ctl install kargs
	[ -s "$MOCK_STATE/kargs" ]

	bc250ctl revert kargs
	run kargs
	[ -z "$output" ]
}

@test "status names the keys that are set" {
	use_profile balanced
	bc250ctl install kargs
	run bc250ctl status
	[[ $output == *"ttm.pages_limit"* ]]
	[[ $output == *"amdgpu.gttsize"* ]]
}
