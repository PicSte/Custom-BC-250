# shellcheck shell=bash
#
# Paths, configuration and the module registry.

# Every system path goes through BC250_PREFIX so the test suite can run the
# real code against a sandbox directory instead of the live system.
: "${BC250_PREFIX:=}"

export BC250_ETC="${BC250_PREFIX}/etc/bc250ctl"
export BC250_VAR="${BC250_PREFIX}/var/lib/bc250ctl"
export BC250_SRC="${BC250_VAR}/src"
export BC250_VENV="${BC250_VAR}/venv"
export BC250_CONFIG="${BC250_ETC}/config.env"

export SYSTEMD_DIR="${BC250_PREFIX}/etc/systemd/system"
export MODPROBE_DIR="${BC250_PREFIX}/etc/modprobe.d"
export MODULES_LOAD_DIR="${BC250_PREFIX}/etc/modules-load.d"
export YUM_REPOS_DIR="${BC250_PREFIX}/etc/yum.repos.d"
export LOCAL_BIN="${BC250_PREFIX}/usr/local/bin"

# ---------------------------------------------------------------- config ---

# config_load [path]
#
# Sources the config file if it exists, then fills in defaults for anything
# left unset. Missing config is not an error: the defaults are the `safe`
# profile, which changes nothing dangerous.
config_load() {
	local path=${1:-$BC250_CONFIG}

	if [[ -f $path ]]; then
		log_debug "loading config $path"
		# shellcheck source=/dev/null
		source "$path"
	fi

	: "${BC250_PROFILE:=safe}"
	: "${BC250_GPU_WGP_LAYOUT:=stock}"
	: "${BC250_GOV_FREQ_MIN:=1000}"
	: "${BC250_GOV_FREQ_MAX:=1500}"
	: "${BC250_GOV_VOLT_MIN:=900}"
	: "${BC250_GOV_VOLT_MAX:=900}"
	: "${BC250_CPU_CORES:=6}"
	: "${BC250_CPU_OC_FREQ:=0}"
	: "${BC250_CPU_OC_VID:=0}"
	: "${BC250_CPU_OC_TEMP:=90}"
	: "${BC250_KARGS_MITIGATIONS_OFF:=0}"
	: "${BC250_KARGS_TTM:=1}"
	: "${BC250_KARGS_DP_FORCE:=0}"
	: "${BC250_DISABLE_HHD:=0}"
	: "${BC250_DISABLE_SUSPEND:=0}"
	: "${BC250_DISABLE_ZRAM:=0}"
	: "${BC250_SENSORS:=1}"
	: "${BC250_ACPI:=1}"
	: "${BC250_FAN_CONTROL:=0}"
	: "${BC250_FAN_PWM:=auto}"
	: "${BC250_ALLOW_EXTREME_VID:=0}"
}

# config_validate
#
# Refuses to continue on any setting that could cook the board. This runs
# before every action, not just at write time, so hand-edited config files are
# caught too.
#
# Types and ranges come from lib/settings.sh; only the rules that span several
# settings are written out here, because a table cannot express them.
config_validate() {
	local key

	# 1. Is every value the right shape?
	for key in $(settings_keys); do
		[[ -v $key ]] || continue
		settings_check_type "$key" "${!key}"
	done

	# 2. The CPU voltage ceilings, before the generic range check, so they can
	#    say what they actually mean rather than "out of range".
	_validate_cpu_oc

	# 3. Is every value inside its range?
	for key in $(settings_keys); do
		[[ -v $key ]] || continue
		settings_check_range "$key" "${!key}"
	done

	# 4. Rules that involve more than one setting.
	(( BC250_GOV_FREQ_MIN <= BC250_GOV_FREQ_MAX )) ||
		die "BC250_GOV_FREQ_MIN ($BC250_GOV_FREQ_MIN) exceeds BC250_GOV_FREQ_MAX ($BC250_GOV_FREQ_MAX)"
	(( BC250_GOV_VOLT_MIN <= BC250_GOV_VOLT_MAX )) ||
		die "BC250_GOV_VOLT_MIN ($BC250_GOV_VOLT_MIN) exceeds BC250_GOV_VOLT_MAX ($BC250_GOV_VOLT_MAX)"

	# One driver owns the Nuvoton chip. nct6683 reads, nct6687 reads and
	# writes; loading both leaves neither working properly.
	if [[ $BC250_FAN_CONTROL == 1 && $BC250_SENSORS == 1 ]]; then
		die "BC250_FAN_CONTROL and BC250_SENSORS both ask for the same chip." \
		    "Fan control already provides the temperatures: set BC250_SENSORS=0."
	fi

	# The rebuilt SSDT is what gives CPUs 12-15 their idle states.
	if [[ $BC250_CPU_CORES == 8 && $BC250_ACPI != 1 ]]; then
		die "BC250_CPU_CORES=8 needs BC250_ACPI=1: without the rebuilt ACPI tables," \
		    "CPUs 12-15 get no idle states and burn power doing nothing."
	fi
}

_validate_cpu_oc() {
	# The overclock is off entirely when both knobs are zero.
	(( BC250_CPU_OC_FREQ == 0 && BC250_CPU_OC_VID == 0 )) && return 0

	# Raising the frequency without pinning a voltage lets Vid scale without a
	# ceiling, which is the documented way to destroy the hardware.
	(( BC250_CPU_OC_VID > 0 )) ||
		die "BC250_CPU_OC_FREQ is set but BC250_CPU_OC_VID is 0:" \
		    "raising the CPU frequency without a voltage cap will damage the board"
	(( BC250_CPU_OC_FREQ > 0 )) ||
		die "BC250_CPU_OC_VID is set but BC250_CPU_OC_FREQ is 0"

	(( BC250_CPU_OC_VID <= VID_ABSOLUTE_MAX )) ||
		die "BC250_CPU_OC_VID ${BC250_CPU_OC_VID} mV exceeds the hardware limit of" \
		    "${VID_ABSOLUTE_MAX} mV. This is not overridable."

	if (( BC250_CPU_OC_VID > VID_SAFE_MAX )); then
		[[ ${BC250_ALLOW_EXTREME_VID:-0} == 1 ]] ||
			die "BC250_CPU_OC_VID ${BC250_CPU_OC_VID} mV is above the ${VID_SAFE_MAX} mV" \
			    "ceiling this tool enforces. Set BC250_ALLOW_EXTREME_VID=1 to override," \
			    "and understand that ${VID_ABSOLUTE_MAX} mV destroys the SoC."
		log_warn "running above ${VID_SAFE_MAX} mV (${BC250_CPU_OC_VID} mV) — watch your temperatures"
	fi
}

# --------------------------------------------------------------- modules ---

# Module ids carry a numeric prefix that fixes the order they are applied in.
# Users may name them either way: `40-gpu-cu` or just `gpu-cu`.

module_ids() {
	local f
	for f in "$BC250_MODULES_DIR"/[0-9][0-9]-*.sh; do
		[[ -f $f ]] || continue
		basename "$f" .sh
	done
}

# module_resolve <name> — prints the full module id, or fails.
module_resolve() {
	local want=$1 id
	for id in $(module_ids); do
		[[ $id == "$want" || ${id#[0-9][0-9]-} == "$want" ]] && { printf '%s\n' "$id"; return 0; }
	done
	return 1
}

module_short() { printf '%s\n' "${1#[0-9][0-9]-}"; }

# module_call <id> <action> [args...]
#
# Modules run in a subshell so one module cannot leak variables or overridden
# functions into the next. State they need to keep lives on disk.
module_call() {
	local id=$1 action=$2
	shift 2
	local file="$BC250_MODULES_DIR/$id.sh"
	[[ -f $file ]] || die "unknown module: $id"

	(
		set -euo pipefail
		# shellcheck source=/dev/null
		source "$file"
		if ! declare -F "mod_$action" >/dev/null; then
			die "module $id does not implement '$action'"
		fi
		"mod_$action" "$@"
	)
}

# module_has <id> <action> — true when the module implements that action.
module_has() {
	local id=$1 action=$2
	(
		# shellcheck source=/dev/null
		source "$BC250_MODULES_DIR/$id.sh"
		declare -F "mod_$action" >/dev/null
	)
}

# module_check_requires <id>
#
# Fails when a module this one depends on has not been applied yet. This is
# what stops a CPU overclock from being calibrated before the core count is
# settled.
module_check_requires() {
	local id=$1 dep resolved

	# A preview applies nothing, so the state a dependency would be read from
	# is meaningless: checking it would make `--dry-run install all` fail on
	# the first module that depends on another.
	[[ ${BC250_DRY_RUN:-0} == 1 ]] && return 0

	for dep in $(module_call "$id" requires 2>/dev/null || true); do
		resolved=$(module_resolve "$dep") ||
			die "module $id declares unknown dependency '$dep'"
		if ! module_call "$resolved" detect >/dev/null 2>&1; then
			die "$id requires $resolved, which is not applied yet." \
			    "Run: bc250ctl install $(module_short "$resolved")"
		fi
	done
}

# module_check_conflicts <id>
#
# Refuses to install a module while something it is mutually exclusive with is
# still in place. The message names the way out, because the answer is almost
# always "switch", not "give up".
module_check_conflicts() {
	local id=$1 other resolved

	# A module that already matches its configuration has nothing to install,
	# so it cannot conflict with anything. Without this, `install all` on a
	# profile that leaves fan control off would still trip over the sensors
	# module it is exclusive with.
	module_call "$id" detect >/dev/null 2>&1 && return 0
	for other in $(module_call "$id" conflicts 2>/dev/null || true); do
		resolved=$(module_resolve "$other") ||
			die "module $id declares unknown conflict '$other'"
		if module_call "$resolved" active >/dev/null 2>&1; then
			die "$id cannot be installed while $resolved is active — they claim the same hardware." \
			    "Switch with: bc250ctl revert $(module_short "$resolved") &&" \
			    "bc250ctl install $(module_short "$id")"
		fi
	done
}

# module_invalidate <id>
#
# Marks every module whose calibration is voided by a change to this one. They
# stay marked until re-applied, and `status` shows them as stale.
module_invalidate() {
	local id=$1 target resolved
	for target in $(module_call "$id" invalidates 2>/dev/null || true); do
		resolved=$(module_resolve "$target") || continue
		# 'active' rather than 'detect': detect only says the module matches
		# the requested configuration, which is trivially true for a module
		# that was asked to do nothing. What matters here is whether there is
		# something applied that this change invalidates.
		if module_call "$resolved" active >/dev/null 2>&1; then
			state_set "stale.$resolved" 1
			log_warn "$resolved is now stale: $id changed the conditions it was tuned for." \
			         "Re-run: bc250ctl install $(module_short "$resolved")"
		fi
	done
}
