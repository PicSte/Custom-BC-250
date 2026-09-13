# shellcheck shell=bash
#
# Minimal JSON emitters.
#
# Built by hand rather than through jq: every string that goes through here is
# ours, and adding a runtime dependency for a handful of commands is not worth
# it on an image where layering costs a reboot.

json_str() {
	local v=$1
	v=${v//\\/\\\\}
	v=${v//\"/\\\"}
	v=${v//$'\r'/}
	v=${v//$'\t'/\\t}
	v=${v//$'\n'/\\n}
	printf '"%s"' "$v"
}

# json_bool <command> [args...] — true when the command succeeds.
json_bool() { if "$@" >/dev/null 2>&1; then printf 'true'; else printf 'false'; fi; }

# json_flag <0|1> — a stored flag rather than a command's exit status.
json_flag() { if [[ ${1:-0} == 1 ]]; then printf 'true'; else printf 'false'; fi; }

# json_num <value> — a number, or null when it is not one.
json_num() {
	if [[ ${1-} =~ ^-?[0-9]+$ ]]; then printf '%s' "$1"; else printf 'null'; fi
}

# json_list — newline-separated stdin to an array of strings.
json_list() {
	local first=1 line
	printf '['
	while IFS= read -r line; do
		[[ -n $line ]] || continue
		(( first )) || printf ','
		first=0
		json_str "$line"
	done
	printf ']'
}

# json_split_list <comma-separated> — to an array of strings.
json_split_list() {
	local IFS=','
	read -r -a _items <<<"${1-}"
	local first=1 item
	printf '['
	for item in "${_items[@]}"; do
		[[ -n $item ]] || continue
		(( first )) || printf ','
		first=0
		json_str "$item"
	done
	printf ']'
}
