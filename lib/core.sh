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

# Hard safety ceilings for CPU core voltage, in millivolts.
#
# 1325 mV is the absolute limit documented by bc250_smu_oc (bc250_limits.py);
# above it you damage the SoC. 1275 mV is the ceiling this tool applies on its
# own, leaving the last 50 mV behind an explicit opt-in.
readonly VID_ABSOLUTE_MAX=1325
readonly VID_SAFE_MAX=1275
readonly VID_MIN=950
readonly FREQ_MIN=3500
readonly FREQ_MAX=4500

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
	: "${BC250_DISABLE_HHD:=0}"
	: "${BC250_SENSORS:=1}"
}

_is_uint() { [[ $1 =~ ^[0-9]+$ ]]; }

_require_uint() {
	local name=$1 value=$2
	_is_uint "$value" || die "$name must be a whole number, got '$value'"
}

_require_range() {
	local name=$1 value=$2 lo=$3 hi=$4
	_require_uint "$name" "$value"
	(( value >= lo && value <= hi )) ||
		die "$name must be between $lo and $hi, got $value"
}

# config_validate
#
# Refuses to continue on any setting that could cook the board. This runs
# before every action, not just at write time, so hand-edited config files are
# caught too.
config_validate() {
	_require_uint BC250_CPU_OC_FREQ "$BC250_CPU_OC_FREQ"
	_require_uint BC250_CPU_OC_VID "$BC250_CPU_OC_VID"

	[[ $BC250_CPU_CORES == 6 || $BC250_CPU_CORES == 8 ]] ||
		die "BC250_CPU_CORES must be 6 or 8, got '$BC250_CPU_CORES'"

	_require_range BC250_GOV_FREQ_MIN "$BC250_GOV_FREQ_MIN" 200 2000
	_require_range BC250_GOV_FREQ_MAX "$BC250_GOV_FREQ_MAX" 200 2000
	(( BC250_GOV_FREQ_MIN <= BC250_GOV_FREQ_MAX )) ||
		die "BC250_GOV_FREQ_MIN ($BC250_GOV_FREQ_MIN) exceeds BC250_GOV_FREQ_MAX ($BC250_GOV_FREQ_MAX)"

	_require_range BC250_GOV_VOLT_MIN "$BC250_GOV_VOLT_MIN" 600 1200
	_require_range BC250_GOV_VOLT_MAX "$BC250_GOV_VOLT_MAX" 600 1200
	(( BC250_GOV_VOLT_MIN <= BC250_GOV_VOLT_MAX )) ||
		die "BC250_GOV_VOLT_MIN ($BC250_GOV_VOLT_MIN) exceeds BC250_GOV_VOLT_MAX ($BC250_GOV_VOLT_MAX)"

	# CPU overclock is off entirely when either knob is zero.
	if (( BC250_CPU_OC_FREQ == 0 && BC250_CPU_OC_VID == 0 )); then
		return 0
	fi

	# Raising the frequency without pinning a voltage lets Vid scale without a
	# ceiling, which is the documented way to destroy the hardware.
	(( BC250_CPU_OC_VID > 0 )) ||
		die "BC250_CPU_OC_FREQ is set but BC250_CPU_OC_VID is 0:" \
		    "raising the CPU frequency without a voltage cap will damage the board"
	(( BC250_CPU_OC_FREQ > 0 )) ||
		die "BC250_CPU_OC_VID is set but BC250_CPU_OC_FREQ is 0"

	_require_range BC250_CPU_OC_FREQ "$BC250_CPU_OC_FREQ" "$FREQ_MIN" "$FREQ_MAX"
	_require_range BC250_CPU_OC_TEMP "$BC250_CPU_OC_TEMP" 60 100

	(( BC250_CPU_OC_VID >= VID_MIN )) ||
		die "BC250_CPU_OC_VID must be at least ${VID_MIN} mV, got ${BC250_CPU_OC_VID}"

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
