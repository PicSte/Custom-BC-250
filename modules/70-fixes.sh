# shellcheck shell=bash
#
# Assorted BC-250 fixes.
#
# Currently just one: Bazzite's handheld daemon. hhd polls for handheld
# controller hardware that a BC-250 does not have, and on this board that poll
# shows up as micro-stutter in the Deck UI. Masking it is the documented fix.
#
# The other well-known annoyance — MangoHud and radeontop reporting GPU usage
# in the hundreds of percent — is not handled here: it is fixed by
# `fix-metrics = true` in the governor configuration, which modules/30-governor.sh
# already writes.

HHD_UNIT='hhd'

mod_describe()    { printf 'assorted fixes (handheld daemon micro-stutter)\n'; }
mod_requires()    { :; }
mod_invalidates() { :; }
mod_stage()       { printf 'runtime\n'; }
mod_unattended()  { return 0; }

_hhd_present() { systemctl list-unit-files 2>/dev/null | grep -q "^${HHD_UNIT}"; }

# Active when we have masked hhd.
mod_active() { _hhd_present && systemctl is-enabled "$HHD_UNIT" 2>/dev/null | grep -q masked; }

mod_detect() {
	[[ ${BC250_DISABLE_HHD:-0} == 1 ]] || return 0
	_hhd_present || return 0
	systemctl is-enabled "$HHD_UNIT" 2>/dev/null | grep -q 'masked'
}

mod_status() {
	if [[ ${BC250_DISABLE_HHD:-0} != 1 ]]; then
		printf 'hhd left alone\n'
		return 0
	fi
	if ! _hhd_present; then
		printf 'hhd is not installed on this system\n'
	elif mod_detect; then
		printf 'hhd masked\n'
	else
		printf 'hhd still enabled\n'
	fi
}

mod_install() {
	if [[ ${BC250_DISABLE_HHD:-0} != 1 ]]; then
		log_info "this profile leaves hhd alone"
		return 0
	fi
	if ! _hhd_present; then
		log_info "hhd is not installed; nothing to do"
		return 0
	fi

	log_info "masking hhd (handheld daemon micro-stutter)"
	bc_run systemctl disable --now "$HHD_UNIT" || true
	bc_run systemctl mask "$HHD_UNIT" || die "could not mask $HHD_UNIT"
}

mod_configure() { mod_install; }

mod_verify() {
	if [[ ${BC250_DISABLE_HHD:-0} != 1 ]]; then
		log_ok "hhd left alone, as configured"
		return 0
	fi
	if ! _hhd_present; then
		log_ok "hhd is not installed"
		return 0
	fi
	if mod_detect; then
		log_ok "hhd is masked"
	else
		log_error "hhd is still active"
		return 1
	fi
}

mod_uninstall() {
	_hhd_present || return 0
	bc_run systemctl unmask "$HHD_UNIT" || true
	return 0
}
