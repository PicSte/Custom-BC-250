#!/usr/bin/env bats
#
# The catalog: the machine-readable module graph the GUI will consume. It must
# be valid JSON, and it must describe the graph the modules actually declare —
# a GUI built on a stale or wrong catalog is worse than no GUI.

load helper

setup() {
	sandbox_setup
	lib_source
	fake_bc250
	use_profile balanced
}

catalog() { bc250ctl catalog --json 2>/dev/null; }

@test "the output is valid JSON" {
	catalog | python3 -m json.tool >/dev/null
}

@test "it lists every module, once" {
	local n
	n=$(catalog | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["modules"]))')
	[ "$n" -eq "$(module_ids | wc -l)" ]

	local ids
	ids=$(catalog | python3 -c 'import json,sys; print(" ".join(m["id"] for m in json.load(sys.stdin)["modules"]))')
	[ "$ids" = "$(module_ids | tr '\n' ' ' | sed 's/ $//')" ]
}

@test "the graph it publishes is the graph the modules declare" {
	local id
	for id in $(module_ids); do
		for field in requires conflicts invalidates; do
			local declared published
			declared=$(module_call "$id" "$field" | tr '\n' ' ' | sed 's/ $//')
			published=$(catalog | python3 -c "
import json,sys
m = next(m for m in json.load(sys.stdin)['modules'] if m['id'] == '$id')
print(' '.join(m['$field']))")
			[ "$declared" = "$published" ] || {
				echo "$id.$field: modules say '$declared', catalog says '$published'"
				return 1
			}
		done
	done
}

@test "risk, stage and the SMU flag are carried through" {
	local out
	out=$(catalog | python3 -c "
import json,sys
d = json.load(sys.stdin)
m = {x['id']: x for x in d['modules']}
print(m['60-cpu-oc']['risk'], m['60-cpu-oc']['needs_smu'], m['60-cpu-oc']['unattended'],
      m['15-acpi']['stage'], m['40-gpu-cu']['stage'])")
	[ "$out" = "high True False pre-reboot runtime" ]
}

@test "upstreams come from the pinned source table, not a hardcoded string" {
	local up
	up=$(catalog | python3 -c "
import json,sys
m = {x['id']: x for x in json.load(sys.stdin)['modules']}
print(m['40-gpu-cu']['upstream'])")
	[ "$up" = "$(src_get CU_LIVE_MANAGER REPO)" ]

	up=$(catalog | python3 -c "
import json,sys
m = {x['id']: x for x in json.load(sys.stdin)['modules']}
print(m['60-cpu-oc']['upstream'])")
	[ "$up" = "$(src_get SMU_OC REPO)" ]

	# A module with no upstream of its own says so, rather than inventing one.
	up=$(catalog | python3 -c "
import json,sys
m = {x['id']: x for x in json.load(sys.stdin)['modules']}
print(repr(m['10-kargs']['upstream']))")
	[ "$up" = "''" ]
}

@test "live state is reported: active, matches_config, stale" {
	bc250ctl install acpi
	bc250ctl install cpu-cores

	local out
	out=$(catalog | python3 -c "
import json,sys
m = {x['id']: x for x in json.load(sys.stdin)['modules']}
print(m['15-acpi']['active'], m['50-cpu-cores']['active'], m['70-fixes']['active'])")
	[ "$out" = "True True False" ]
}

@test "the header carries the profile and the hardware" {
	local out
	out=$(catalog | python3 -c "
import json,sys
d = json.load(sys.stdin)
print(d['profile'], d['hardware']['bc250'], d['hardware']['gpu_card'], d['version'])")
	[ "$out" = "balanced True card1 1" ]
}

@test "text that needs escaping survives the round trip" {
	# The WGP layout is free text, so it is the one value a person can put a
	# quote or a backslash into. Written through the tool it has to come back
	# out intact, and leave a file the tool can still read.
	local awkward
	awkward='a"b\c'
	bc250ctl config set "BC250_GPU_WGP_LAYOUT=${awkward}"

	bc250ctl config --json 2>/dev/null | python3 -m json.tool >/dev/null

	local round_trip
	round_trip=$(bc250ctl config --json 2>/dev/null | python3 -c "
import json,sys
print(json.load(sys.stdin)['values']['BC250_GPU_WGP_LAYOUT']['value'])")
	[ "$round_trip" = "$awkward" ]
}

@test "catalog rejects an argument it does not understand" {
	run bc250ctl catalog --yaml
	[ "$status" -ne 0 ]
}
