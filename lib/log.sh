# shellcheck shell=bash
#
# Logging, colours, and the dry-run aware command runner.
#
# Everything here writes to stderr so that stdout stays clean for the commands
# whose output is meant to be parsed (`status`, `modules`, ...).

if [[ -t 2 && -z ${NO_COLOR:-} ]]; then
	_c_reset=$'\033[0m'
	_c_dim=$'\033[2m'
	_c_bold=$'\033[1m'
	_c_red=$'\033[31m'
	_c_green=$'\033[32m'
	_c_yellow=$'\033[33m'
	_c_blue=$'\033[34m'
else
	_c_reset='' _c_dim='' _c_bold='' _c_red='' _c_green='' _c_yellow='' _c_blue=''
fi

log_info()  { printf '%s\n' "$*" >&2; }
log_ok()    { printf '%s✔%s %s\n' "$_c_green" "$_c_reset" "$*" >&2; }
log_warn()  { printf '%s!%s %s\n' "$_c_yellow" "$_c_reset" "$*" >&2; }
log_error() { printf '%s✘%s %s\n' "$_c_red" "$_c_reset" "$*" >&2; event error '' "$*"; }
log_step()  { printf '\n%s%s==>%s %s%s\n' "$_c_bold" "$_c_blue" "$_c_reset" "$*" "$_c_reset" >&2; }
log_debug() { [[ ${BC250_VERBOSE:-0} == 1 ]] && printf '%s  %s%s\n' "$_c_dim" "$*" "$_c_reset" >&2; return 0; }

die() { log_error "$*"; exit 1; }

# bc_run <cmd> [args...]
#
# The single choke point for every command with a side effect. Under
# --dry-run it prints the command instead of running it, which is what makes
# the whole tool testable without a BC-250 attached.
bc_run() {
	if [[ ${BC250_DRY_RUN:-0} == 1 ]]; then
		printf '%s[dry-run]%s %s\n' "$_c_dim" "$_c_reset" "$*" >&2
		return 0
	fi
	log_debug "+ $*"
	"$@"
}

# write_file <path> [mode]  — content on stdin
#
# Same contract as bc_run(): under --dry-run it shows the target and the content
# rather than touching the filesystem.
write_file() {
	local path=$1 mode=${2:-0644} content
	content=$(cat)

	if [[ ${BC250_DRY_RUN:-0} == 1 ]]; then
		printf '%s[dry-run]%s write %s (mode %s):\n' "$_c_dim" "$_c_reset" "$path" "$mode" >&2
		printf '%s%s%s\n' "$_c_dim" "${content//$'\n'/$'\n'}" "$_c_reset" >&2
		return 0
	fi

	mkdir -p -- "$(dirname -- "$path")"
	printf '%s\n' "$content" >"$path"
	chmod "$mode" -- "$path"
	log_debug "wrote $path"
}

# confirm <question>
#
# Returns 0 on yes. Always yes under --yes, always no when there is no tty to
# ask on (so an unattended run never blocks forever on a prompt).
confirm() {
	local reply
	if [[ ${BC250_ASSUME_YES:-0} == 1 ]]; then
		log_debug "auto-confirm: $1"
		return 0
	fi
	if [[ ! -t 0 ]]; then
		log_warn "no tty to confirm on, assuming no: $1"
		return 1
	fi
	printf '%s%s%s [y/N] ' "$_c_bold" "$1" "$_c_reset" >&2
	read -r reply
	[[ $reply == [yY]* ]]
}

# ui_title <text> — a heading for the interactive menu.
ui_title() { printf '\n%s%s%s\n\n' "$_c_bold" "$*" "$_c_reset" >&2; }

# event <type> [module] [text]
#
# Machine-readable progress, for the GUI. Silent unless --events was given, so
# terminal output is byte-for-byte what it was before.
#
# These go to stdout while the human-readable log goes to stderr, and they use
# a prefix a caller can filter on. A separate file descriptor would be
# cleaner, but pkexec does not pass them through.
event() {
	[[ ${BC250_EVENTS:-0} == 1 ]] || return 0
	printf '@@BC250 {"event": %s, "module": %s, "text": %s}\n' \
		"$(json_str "$1")" "$(json_str "${2-}")" "$(json_str "${3-}")"
}
