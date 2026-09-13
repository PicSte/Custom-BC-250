#!/usr/bin/env bats
#
# The module registry and the contract every module has to honour.

load helper

setup() { sandbox_setup; lib_source; }

@test "modules are discovered in apply order" {
	run bash -c "$(declare -f module_ids); module_ids"
	[ "$status" -eq 0 ]
	[ "${lines[0]}" = 10-kargs ]
	[ "${lines[1]}" = 15-acpi ]
	[ "${lines[2]}" = 20-sensors ]
	[ "${lines[3]}" = 25-fan-control ]
	[ "${lines[4]}" = 30-governor ]
	[ "${lines[5]}" = 40-gpu-cu ]
	[ "${lines[6]}" = 50-cpu-cores ]
	[ "${lines[7]}" = 60-cpu-oc ]
	[ "${lines[8]}" = 70-fixes ]
	[ "${#lines[@]}" -eq 9 ]
}

@test "the ACPI tables are ordered before the core unlock that needs them" {
	local ids acpi cores
	ids=$(module_ids)
	acpi=$(grep -n '^15-acpi$' <<<"$ids" | cut -d: -f1)
	cores=$(grep -n '^50-cpu-cores$' <<<"$ids" | cut -d: -f1)
	[ "$acpi" -lt "$cores" ]
}

@test "modules resolve by short or full name" {
	[ "$(module_resolve gpu-cu)" = 40-gpu-cu ]
	[ "$(module_resolve 40-gpu-cu)" = 40-gpu-cu ]
	! module_resolve nonsense
}

@test "every module implements the full contract" {
	local id action
	for id in $(module_ids); do
		for action in describe requires conflicts invalidates stage unattended risk \
		              needs_smu upstream active detect status install configure verify \
		              uninstall; do
			module_has "$id" "$action" || {
				echo "$id is missing mod_$action"
				return 1
			}
		done
	done
}

@test "every module declares a known risk level" {
	local id risk
	for id in $(module_ids); do
		risk=$(module_call "$id" risk)
		[[ $risk == none || $risk == low || $risk == medium || $risk == high ]] || {
			echo "$id has risk '$risk'"
			return 1
		}
	done
}

@test "conflicts are declared on both sides" {
	local id other resolved
	for id in $(module_ids); do
		for other in $(module_call "$id" conflicts); do
			resolved=$(module_resolve "$other")
			module_call "$resolved" conflicts | grep -qx "$id" || {
				echo "$id conflicts with $resolved but not the other way round"
				return 1
			}
		done
	done
}

@test "every module declares a known stage" {
	local id stage
	for id in $(module_ids); do
		stage=$(module_call "$id" stage)
		[[ $stage == pre-reboot || $stage == runtime ]] || {
			echo "$id has stage '$stage'"
			return 1
		}
	done
}

@test "the CPU overclock is the only module barred from unattended runs" {
	local id
	for id in $(module_ids); do
		if [[ $id == 60-cpu-oc ]]; then
			! module_call "$id" unattended
		else
			module_call "$id" unattended
		fi
	done
}

@test "declared dependencies all name real modules" {
	local id dep
	for id in $(module_ids); do
		for dep in $(module_call "$id" requires) $(module_call "$id" invalidates) \
		           $(module_call "$id" conflicts); do
			module_resolve "$dep" >/dev/null || {
				echo "$id points at unknown module '$dep'"
				return 1
			}
		done
	done
}

@test "'bc250ctl modules' lists them for a human" {
	run bc250ctl modules
	[ "$status" -eq 0 ]
	[[ $output == *"gpu-cu"* ]]
	[[ $output == *"40 CU"* ]]
	[[ $output == *"runtime"* ]]
}
