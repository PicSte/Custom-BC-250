# shellcheck shell=bash
#
# Live readings, from sysfs only.
#
# Nothing here needs privileges, so the interface can poll it without asking
# for a password. Every field is null when its source is absent rather than
# zero: a machine where nct6687 is not loaded has no fan reading, and showing
# 0 RPM would be a lie.

SYSFS_HWMON="${BC250_PREFIX}/sys/class/hwmon"

# telem_hwmon <driver-name> — the hwmon directory for a driver, if bound.
telem_hwmon() {
	local dir name
	for dir in "$SYSFS_HWMON"/hwmon[0-9]*; do
		[[ -r $dir/name ]] || continue
		read -r name <"$dir/name"
		[[ $name == "$1" ]] && { printf '%s\n' "$dir"; return 0; }
	done
	return 1
}

# telem_read <file> [divisor] — a number, or nothing.
telem_read() {
	local file=$1 div=${2:-1} value
	[[ -r $file ]] || return 1
	read -r value <"$file" 2>/dev/null || return 1
	[[ $value =~ ^-?[0-9]+$ ]] || return 1
	(( div == 1 )) && { printf '%s\n' "$value"; return 0; }
	printf '%s\n' "$(( value / div ))"
}

# telem_gpu_sclk — the clock marked active in the DPM table.
#
# Worth knowing: this table reports nonsense once the extra CPU cores are
# unlocked. The reading is published anyway, with a flag saying so, rather
# than silently dropped.
telem_gpu_sclk() {
	local card sclk line
	card=$(hw_gpu_card) || return 1
	sclk="${SYSFS_DRM}/${card}/device/pp_dpm_sclk"
	[[ -r $sclk ]] || return 1
	while IFS= read -r line; do
		[[ $line == *'*'* ]] || continue
		line=${line#*: }
		printf '%s\n' "${line%%[!0-9]*}"
		return 0
	done <"$sclk"
	return 1
}

# _telem_field <name> <value-command...> — one JSON member, null on failure.
_telem_field() {
	local name=$1
	shift
	local value
	if value=$("$@" 2>/dev/null) && [[ -n $value ]]; then
		printf '"%s": %s' "$name" "$(json_num "$value")"
	else
		printf '"%s": null' "$name"
	fi
}

telemetry_json() {
	local amd cpu nuvoton card

	amd=$(telem_hwmon amdgpu || true)
	cpu=$(telem_hwmon k10temp || true)
	nuvoton=$(telem_hwmon nct6687 || telem_hwmon nct6683 || true)
	card=$(hw_gpu_card 2>/dev/null || true)

	printf '{\n'
	printf '  "gpu": {'
	_telem_field temp_c telem_read "${amd:-/nonexistent}/temp1_input" 1000
	printf ', '
	_telem_field power_w telem_read "${amd:-/nonexistent}/power1_average" 1000000
	printf ', '
	_telem_field busy_percent telem_read "${SYSFS_DRM}/${card:-none}/device/gpu_busy_percent"
	printf ', '
	_telem_field sclk_mhz telem_gpu_sclk
	# The DPM table stops telling the truth once 8 cores are up.
	printf ', "sclk_trustworthy": %s' "$([[ $(hw_cpu_cores) == 8 ]] && printf false || printf true)"
	printf '},\n'

	printf '  "cpu": {'
	_telem_field temp_c telem_read "${cpu:-/nonexistent}/temp1_input" 1000
	printf ', "cores_online": %s' "$(json_num "$(hw_cpu_cores)")"
	printf '},\n'

	printf '  "fan": {'
	_telem_field rpm telem_read "${nuvoton:-/nonexistent}/fan1_input"
	printf ', '
	_telem_field pwm telem_read "${nuvoton:-/nonexistent}/pwm1"
	printf ', "driver": %s' "$(json_str "$([[ -n $nuvoton ]] && cat "$nuvoton/name" || echo '')")"
	printf '},\n'

	# Stated rather than left to be guessed from a missing field: this board
	# has no VRAM sensor at all.
	printf '  "unavailable": ["vram_temp"]\n'
	printf '}\n'
}
