# shellcheck shell=bash
#
# Board quirks that are not really "features".
#
# Three independent fixes, each behind its own flag because none of them is
# universally wanted:
#
#   hhd      Bazzite's handheld daemon polls for controller hardware the
#            BC-250 does not have; on this board that shows up as micro-
#            stutter in the Deck UI.
#   suspend  s2idle is broken: the board goes to sleep and does not come
#            back. Leaving suspend enabled is a trap, not a feature.
#   zram     Compressed swap has been implicated in game crashes (RDR2,
#            Company of Heroes 3).
#
# The other well-known annoyance — MangoHud and radeontop reporting GPU usage
# in the hundreds of percent — is not handled here: `fix-metrics = true` in the
# governor configuration covers it, and modules/30-governor.sh writes that.

HHD_UNIT='hhd'
SLEEP_TARGETS=(sleep.target suspend.target hibernate.target hybrid-sleep.target)
# The unit name depends on which zram generator the image ships.
ZRAM_UNITS=(swap-create@zram0.service systemd-zram-setup@zram0.service zram-swap.service)

mod_describe()    { printf 'board quirks (hhd stutter, broken suspend, zram crashes)\n'; }
mod_requires()    { :; }
mod_conflicts()   { :; }
mod_invalidates() { :; }
mod_stage()       { printf 'runtime\n'; }
mod_unattended()  { return 0; }
mod_risk()        { printf 'low\n'; }
mod_needs_smu()   { return 1; }
mod_upstream()    { :; }

_unit_known() { systemctl list-unit-files 2>/dev/null | grep -q "^${1}"; }
_is_masked()  { systemctl is-enabled "$1" 2>/dev/null | grep -q masked; }

# _zram_unit — the zram unit this image actually has, if any.
_zram_unit() {
	local u
	for u in "${ZRAM_UNITS[@]}"; do
		_unit_known "$u" && { printf '%s\n' "$u"; return 0; }
	done
	return 1
}

# Each fix is "done" when either it was applied or the thing it targets is not
# present at all — there is nothing to mask on an image without hhd.
_hhd_done() { [[ ${BC250_DISABLE_HHD:-0} != 1 ]] || ! _unit_known "$HHD_UNIT" || _is_masked "$HHD_UNIT"; }

_suspend_done() {
	[[ ${BC250_DISABLE_SUSPEND:-0} == 1 ]] || return 0
	local t
	for t in "${SLEEP_TARGETS[@]}"; do
		_is_masked "$t" || return 1
	done
}

_zram_done() {
	[[ ${BC250_DISABLE_ZRAM:-0} == 1 ]] || return 0
	local u
	u=$(_zram_unit) || return 0
	! systemctl is-enabled "$u" >/dev/null 2>&1
}

mod_active() {
	_is_masked "$HHD_UNIT" && return 0
	_is_masked sleep.target && return 0
	return 1
}

mod_detect() { _hhd_done && _suspend_done && _zram_done; }

mod_status() {
	local out=()

	if [[ ${BC250_DISABLE_HHD:-0} == 1 ]]; then
		if ! _unit_known "$HHD_UNIT"; then out+=('hhd absent')
		elif _hhd_done;                then out+=('hhd masked')
		else                                out+=('hhd pending')
		fi
	fi
	if [[ ${BC250_DISABLE_SUSPEND:-0} == 1 ]]; then
		_suspend_done && out+=('suspend off') || out+=('suspend pending')
	fi
	if [[ ${BC250_DISABLE_ZRAM:-0} == 1 ]]; then
		if ! _zram_unit >/dev/null; then out+=('no zram on this image')
		elif _zram_done;             then out+=('zram off')
		else                              out+=('zram pending')
		fi
	fi

	if (( ${#out[@]} == 0 )); then
		printf 'no quirk fixes requested\n'
		return 0
	fi

	local joined=${out[0]} i
	for (( i = 1; i < ${#out[@]}; i++ )); do joined+=", ${out[$i]}"; done
	printf '%s\n' "$joined"
}

mod_install() {
	_fix_hhd
	_fix_suspend
	_fix_zram
}

mod_configure() { mod_install; }

_fix_hhd() {
	[[ ${BC250_DISABLE_HHD:-0} == 1 ]] || { log_debug "hhd left alone"; return 0; }
	if ! _unit_known "$HHD_UNIT"; then
		log_info "hhd is not installed; nothing to do"
		return 0
	fi
	_is_masked "$HHD_UNIT" && { log_debug "hhd already masked"; return 0; }

	log_info "masking hhd (handheld daemon micro-stutter)"
	bc_run systemctl disable --now "$HHD_UNIT" || true
	bc_run systemctl mask "$HHD_UNIT" || die "could not mask $HHD_UNIT"
}

_fix_suspend() {
	[[ ${BC250_DISABLE_SUSPEND:-0} == 1 ]] || { log_debug "sleep targets left alone"; return 0; }
	_suspend_done && { log_debug "sleep already disabled"; return 0; }

	log_info "masking the sleep targets: s2idle is broken on this board and it does not wake"
	bc_run systemctl mask "${SLEEP_TARGETS[@]}" || die "could not mask the sleep targets"
}

_fix_zram() {
	[[ ${BC250_DISABLE_ZRAM:-0} == 1 ]] || { log_debug "zram left alone"; return 0; }

	local u
	if ! u=$(_zram_unit); then
		log_info "no zram unit on this image; nothing to do"
		return 0
	fi
	_zram_done && { log_debug "zram already disabled"; return 0; }

	log_info "disabling $u (implicated in game crashes on this board)"
	bc_run systemctl disable --now "$u" || log_warn "could not disable $u"
}

mod_verify() {
	local rc=0

	if [[ ${BC250_DISABLE_HHD:-0} == 1 ]]; then
		if ! _unit_known "$HHD_UNIT"; then log_ok "hhd is not installed"
		elif _hhd_done;                then log_ok "hhd is masked"
		else log_error "hhd is still active"; rc=1
		fi
	fi

	if [[ ${BC250_DISABLE_SUSPEND:-0} == 1 ]]; then
		if _suspend_done; then log_ok "sleep targets are masked"
		else log_error "the board can still be told to suspend, and it will not wake"; rc=1
		fi
	fi

	if [[ ${BC250_DISABLE_ZRAM:-0} == 1 ]]; then
		if _zram_done; then log_ok "zram swap is off"
		else log_error "zram swap is still enabled"; rc=1
		fi
	fi

	(( rc == 0 )) && [[ ${BC250_DISABLE_HHD:-0}${BC250_DISABLE_SUSPEND:-0}${BC250_DISABLE_ZRAM:-0} == 000 ]] &&
		log_ok "no quirk fixes requested"
	return "$rc"
}

mod_uninstall() {
	if _unit_known "$HHD_UNIT"; then
		bc_run systemctl unmask "$HHD_UNIT" || true
	fi
	if _is_masked sleep.target; then
		bc_run systemctl unmask "${SLEEP_TARGETS[@]}" || true
	fi
	local u
	if u=$(_zram_unit); then
		bc_run systemctl enable "$u" || true
	fi
	return 0
}
