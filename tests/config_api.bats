#!/usr/bin/env bats
#
# The read/write surface the GUI is built on: the settings schema, the
# configuration commands, telemetry, and machine-readable progress.

load helper

setup() {
	sandbox_setup
	lib_source
	fake_bc250
	use_profile balanced
}

config_json() { bc250ctl config --json 2>/dev/null; }
pick() { python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }

# --- schema ---------------------------------------------------------------

@test "the schema covers every key config_load knows about" {
	local defaults schema
	defaults=$(sed -n '/^config_load()/,/^}/p' "$REPO_ROOT/lib/core.sh" |
		grep -o 'BC250_[A-Z0-9_]*' | grep -v BC250_CONFIG | sort -u)
	schema=$(settings_keys | sort)
	[ "$defaults" = "$schema" ]
}

@test "every schema row is complete and well typed" {
	local key type
	for key in $(settings_keys); do
		type=$(settings_type "$key")
		[[ $type == bool || $type == int || $type == int0 || $type == intauto ||
		   $type == choice || $type == text ]] || { echo "$key: type '$type'"; return 1; }
		[ -n "$(settings_label "$key")" ] || { echo "$key has no label"; return 1; }
		[ -n "$(settings_module "$key")" ] || { echo "$key has no module"; return 1; }
		# A range-bearing type must actually carry one.
		case $type in
			int|int0|intauto) [[ $(settings_constraint "$key") == *-* ]] ||
				{ echo "$key is $type with no range"; return 1; } ;;
			choice) [ -n "$(settings_constraint "$key")" ] ||
				{ echo "$key is a choice with no values"; return 1; } ;;
		esac
	done
}

@test "every schema row names a module that exists, or core" {
	local key mod
	for key in $(settings_keys); do
		mod=$(settings_module "$key")
		[[ $mod == core ]] && continue
		module_resolve "$mod" >/dev/null || { echo "$key points at '$mod'"; return 1; }
	done
}

@test "the safety ceilings are published for the interface" {
	local out
	out=$(config_json | pick "d['limits']['vid_safe_max'], d['limits']['vid_absolute_max']")
	[ "$out" = "1275 1325" ]
}

# --- config --json --------------------------------------------------------

@test "config --json is valid and carries schema plus values" {
	config_json | python3 -m json.tool >/dev/null
	local n
	n=$(config_json | pick "len(d['schema'])")
	[ "$n" -eq "$(settings_keys | wc -l)" ]
}

@test "a value written in the file is distinguished from a default" {
	local out
	out=$(config_json | pick "d['values']['BC250_CPU_CORES']['source'], d['values']['BC250_ALLOW_EXTREME_VID']['source']")
	[ "$out" = "file default" ]
}

# --- config diff / set ----------------------------------------------------

@test "diff reports the change and needs no privileges" {
	run bc250ctl config diff BC250_GOV_FREQ_MAX=1600
	[ "$status" -eq 0 ]
	[[ $output == *"1500 -> 1600"* ]]
	[[ $output == *"would be valid"* ]]
	# and it changed nothing
	grep -q '^BC250_GOV_FREQ_MAX=1500$' "$BC250_PREFIX/etc/bc250ctl/config.env"
}

@test "diff refuses a change that would not validate" {
	run bc250ctl config diff BC250_CPU_OC_FREQ=4000
	[ "$status" -ne 0 ]
	[[ $output == *"will damage the board"* ]]
}

@test "set writes the value" {
	bc250ctl config set BC250_GOV_FREQ_MAX=1600
	grep -q '^BC250_GOV_FREQ_MAX=1600$' "$BC250_PREFIX/etc/bc250ctl/config.env"
	local out
	out=$(config_json | pick "d['values']['BC250_GOV_FREQ_MAX']['value']")
	[ "$out" = 1600 ]
}

@test "set validates the whole resulting config, not just the keys touched" {
	# 8 cores is fine on its own, and wrong while the ACPI tables are off.
	bc250ctl config set BC250_ACPI=0 BC250_CPU_CORES=6
	run bc250ctl config set BC250_CPU_CORES=8
	[ "$status" -ne 0 ]
	[[ $output == *"needs BC250_ACPI=1"* ]]
}

@test "a rejected set leaves the file byte-for-byte intact" {
	local before after
	before=$(sha256sum "$BC250_PREFIX/etc/bc250ctl/config.env" | cut -d' ' -f1)
	run bc250ctl config set BC250_CPU_OC_FREQ=4000
	[ "$status" -ne 0 ]
	after=$(sha256sum "$BC250_PREFIX/etc/bc250ctl/config.env" | cut -d' ' -f1)
	[ "$before" = "$after" ]
	# no debris either
	run bash -c "ls '$BC250_PREFIX/etc/bc250ctl/' | grep -c '\.new\.'"
	[ "$output" -eq 0 ]
}

@test "an unknown setting is refused rather than written" {
	run bc250ctl config set BC250_TYPO=1
	[ "$status" -ne 0 ]
	[[ $output == *"unknown setting"* ]]
	! grep -q BC250_TYPO "$BC250_PREFIX/etc/bc250ctl/config.env"
}

@test "set appends a key the file did not have" {
	bc250ctl config set BC250_ALLOW_EXTREME_VID=1
	grep -q '^BC250_ALLOW_EXTREME_VID=1$' "$BC250_PREFIX/etc/bc250ctl/config.env"
}

@test "config commands still work when the current config is invalid" {
	# Hand-edited into an impossible state: the repair path must not be blocked.
	printf 'BC250_SENSORS=1\nBC250_FAN_CONTROL=1\n' >>"$BC250_PREFIX/etc/bc250ctl/config.env"

	run bc250ctl config --json
	[ "$status" -eq 0 ]

	run bc250ctl config set BC250_FAN_CONTROL=0
	[ "$status" -eq 0 ]
}

@test "an ordinary command still refuses to run on an invalid config" {
	printf 'BC250_SENSORS=1\nBC250_FAN_CONTROL=1\n' >>"$BC250_PREFIX/etc/bc250ctl/config.env"
	run bc250ctl status
	[ "$status" -ne 0 ]
}

# --- profiles -------------------------------------------------------------

@test "profiles lists what is shipped, with descriptions" {
	bc250ctl profiles --json 2>/dev/null | python3 -m json.tool >/dev/null
	local names
	names=$(bc250ctl profiles --json 2>/dev/null | pick "' '.join(sorted(p['name'] for p in d['profiles']))")
	[ "$names" = "balanced max safe" ]

	local desc
	desc=$(bc250ctl profiles --json 2>/dev/null | pick "[p for p in d['profiles'] if p['name']=='safe'][0]['description']")
	[[ $desc == *"safe"* ]]
	[[ $desc != *shellcheck* ]]
}

# --- telemetry ------------------------------------------------------------

@test "telemetry is valid JSON on a machine with no sensors at all" {
	bc250ctl telemetry --json 2>/dev/null | python3 -m json.tool >/dev/null
	local out
	out=$(bc250ctl telemetry --json 2>/dev/null | pick "d['gpu']['temp_c'], d['fan']['rpm']")
	[ "$out" = "None None" ]
}

@test "telemetry reports what it can read" {
	fake_hwmon amdgpu temp1_input 61000
	fake_hwmon k10temp temp1_input 54000

	local out
	out=$(bc250ctl telemetry --json 2>/dev/null | pick "d['gpu']['temp_c'], d['cpu']['temp_c'], d['cpu']['cores_online']")
	[ "$out" = "61 54 6" ]
}

@test "telemetry flags the GPU clock as untrustworthy once 8 cores are up" {
	local out
	out=$(bc250ctl telemetry --json 2>/dev/null | pick "d['gpu']['sclk_trustworthy']")
	[ "$out" = True ]

	fake_bc250 0000:01:00.0 16
	out=$(bc250ctl telemetry --json 2>/dev/null | pick "d['gpu']['sclk_trustworthy']")
	[ "$out" = False ]
}

@test "telemetry says outright what this board cannot measure" {
	local out
	out=$(bc250ctl telemetry --json 2>/dev/null | pick "d['unavailable']")
	[[ $out == *vram_temp* ]]
}

# --- events ---------------------------------------------------------------

@test "--events emits a parsable line per module" {
	run bc250ctl --events install kargs acpi
	[ "$status" -eq 0 ]

	local events
	events=$(grep '^@@BC250 ' <<<"$output" | sed 's/^@@BC250 //')
	[ -n "$events" ]
	while IFS= read -r line; do
		python3 -c "import json,sys; json.loads(sys.argv[1])" "$line"
	done <<<"$events"

	grep -q '"event": "module-begin", "module": "10-kargs"' <<<"$events"
	grep -q '"event": "module-end", "module": "15-acpi", "text": "ok"' <<<"$events"
}

@test "without --events the human output is unchanged" {
	local plain evented
	plain=$(bc250ctl install kargs 2>&1)
	bc250ctl revert kargs >/dev/null 2>&1
	evented=$(bc250ctl --events install kargs 2>&1 | grep -v '^@@BC250 ')
	[ "$plain" = "$evented" ]
}

@test "a failure is reported as an event too" {
	run bc250ctl --events verify governor
	[ "$status" -ne 0 ]
	[[ $output == *'"event": "error"'* ]]
	[[ $output == *'"event": "module-end", "module": "30-governor", "text": "failed"'* ]]
}
