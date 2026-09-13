# shellcheck shell=bash
#
# systemd helpers.
#
# Units we generate ourselves go to /etc/systemd/system, which stays writable
# on an ostree system. Units installed by an upstream tool are only enabled or
# queried here, never rewritten.

_systemctl() { bc_run systemctl "$@"; }

unit_is_active()  { systemctl is-active --quiet "$1" 2>/dev/null; }
unit_is_enabled() { systemctl is-enabled --quiet "$1" 2>/dev/null; }
unit_exists()     { systemctl cat "$1" >/dev/null 2>&1 || [[ -f "$SYSTEMD_DIR/$1" ]]; }

# unit_install <name> — unit content on stdin.
unit_install() {
	local name=$1
	write_file "$SYSTEMD_DIR/$name" 0644
	_systemctl daemon-reload
}

unit_enable_now() {
	local name=$1
	_systemctl enable --now "$name"
}

unit_disable_now() {
	local name=$1
	unit_exists "$name" || return 0
	_systemctl disable --now "$name" || true
}

unit_remove() {
	local name=$1
	unit_disable_now "$name"
	[[ -f "$SYSTEMD_DIR/$name" ]] && bc_run rm -f -- "$SYSTEMD_DIR/$name"
	_systemctl daemon-reload
	return 0
}

# unit_status_line <name> — one word describing the unit, for `status`.
unit_status_line() {
	local name=$1
	if ! unit_exists "$name"; then
		printf 'absente\n'
	elif unit_is_active "$name"; then
		unit_is_enabled "$name" && printf 'active (activée)\n' || printf 'active (non activée)\n'
	else
		unit_is_enabled "$name" && printf 'inactive (activée)\n' || printf 'inactive\n'
	fi
}
