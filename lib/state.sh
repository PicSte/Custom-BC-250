# shellcheck shell=bash
#
# A flat key=value store under /var/lib/bc250ctl/state.
#
# It holds what survives a reboot: which bootstrap phase is pending, which
# modules went stale, and what the previous value of a setting was so `revert`
# has something to go back to.

_state_file() { printf '%s\n' "${BC250_VAR}/state"; }

state_get() {
	local key=$1 default=${2:-} file
	file=$(_state_file)
	[[ -f $file ]] || { printf '%s\n' "$default"; return 0; }

	local line
	while IFS= read -r line; do
		if [[ $line == "$key="* ]]; then
			printf '%s\n' "${line#*=}"
			return 0
		fi
	done <"$file"

	printf '%s\n' "$default"
}

state_set() {
	local key=$1 value=$2 file tmp
	file=$(_state_file)

	if [[ ${BC250_DRY_RUN:-0} == 1 ]]; then
		log_debug "[dry-run] state $key=$value"
		return 0
	fi

	mkdir -p -- "$(dirname -- "$file")"
	tmp="${file}.tmp.$$"
	if [[ -f $file ]]; then
		grep -v "^${key}=" -- "$file" >"$tmp" || true
	else
		: >"$tmp"
	fi
	printf '%s=%s\n' "$key" "$value" >>"$tmp"
	mv -- "$tmp" "$file"
}

state_del() {
	local key=$1 file tmp
	file=$(_state_file)
	[[ -f $file ]] || return 0
	[[ ${BC250_DRY_RUN:-0} == 1 ]] && return 0

	tmp="${file}.tmp.$$"
	grep -v "^${key}=" -- "$file" >"$tmp" || true
	mv -- "$tmp" "$file"
}

# state_keys <prefix> — every key starting with prefix, one per line.
state_keys() {
	local prefix=$1 file
	file=$(_state_file)
	[[ -f $file ]] || return 0
	sed -n "s/^\(${prefix}[^=]*\)=.*/\1/p" -- "$file"
}
