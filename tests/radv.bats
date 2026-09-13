#!/usr/bin/env bats
#
# RADV configuration. One file, /etc/drirc, which Mesa reads system-wide and
# which may already belong to somebody else.

load helper

setup() {
	sandbox_setup
	lib_source
	fake_bc250
	write_config <<-EOC
		BC250_RADV_UNIFIED_HEAP=1
		BC250_ACPI=0
		BC250_SENSORS=0
	EOC
}

drirc() { echo "$BC250_PREFIX/etc/drirc"; }

@test "the unified heap option is written for the shared memory design" {
	bc250ctl install radv

	[ -f "$(drirc)" ]
	grep -q 'radv_enable_unified_heap_on_apu' "$(drirc)"
	grep -q 'value="true"' "$(drirc)"
}

@test "the file we write is marked as ours" {
	bc250ctl install radv
	grep -q 'Managed by bc250ctl' "$(drirc)"
}

@test "an existing file we did not write is never overwritten" {
	mkdir -p "$(dirname "$(drirc)")"
	printf '<driconf><!-- someone else --></driconf>\n' >"$(drirc)"
	local before
	before=$(sha256sum "$(drirc)" | cut -d' ' -f1)

	run bc250ctl install radv
	[ "$status" -eq 0 ]
	[[ $output == *"n'a pas été écrit par bc250ctl"* ]]
	[ "$(sha256sum "$(drirc)" | cut -d' ' -f1)" = "$before" ]
}

@test "verify fails when a foreign file lacks the option" {
	mkdir -p "$(dirname "$(drirc)")"
	printf '<driconf></driconf>\n' >"$(drirc)"

	run bc250ctl verify radv
	[ "$status" -ne 0 ]
	[[ $output == *"radv_enable_unified_heap_on_apu"* ]]
}

@test "verify passes on a foreign file that already carries the option" {
	mkdir -p "$(dirname "$(drirc)")"
	printf '<driconf>radv_enable_unified_heap_on_apu</driconf>\n' >"$(drirc)"

	run bc250ctl verify radv
	[ "$status" -eq 0 ]
}

@test "revert removes only a file we wrote" {
	bc250ctl install radv
	bc250ctl revert radv
	[ ! -f "$(drirc)" ]

	printf '<driconf><!-- theirs --></driconf>\n' >"$(drirc)"
	bc250ctl revert radv
	[ -f "$(drirc)" ]
}

@test "turning the setting off removes our file" {
	bc250ctl install radv
	[ -f "$(drirc)" ]

	write_config <<-EOC
		BC250_RADV_UNIFIED_HEAP=0
		BC250_ACPI=0
		BC250_SENSORS=0
	EOC
	bc250ctl install radv
	[ ! -f "$(drirc)" ]
}
