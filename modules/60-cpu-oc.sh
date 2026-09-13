# shellcheck shell=bash
#
# CPU overclock and undervolt.
#
# bc250_smu_oc raises the boost ceiling and caps Vid over SMU messages, with
# dynamic frequency scaling left intact. It is a Python package, so it goes
# into a venv under /var/lib/bc250ctl rather than the system interpreter —
# /usr is read-only on Bazzite and layering a pip install there is not an
# option anyway.
#
# The frequency and voltage in a profile are a starting point only. Silicon
# varies: `bc250-detect` stress-tests the requested pair on *this* board and
# writes back what actually held, which is why install runs it rather than
# writing a config straight out.

OC_SERVICE='bc250-smu-oc.service'

_oc_conf()   { printf '%s\n' "${BC250_ETC}/overclock.conf"; }
_oc_applied(){ printf '%s\n' "${BC250_PREFIX}/etc/bc250-smu-oc.conf"; }
_oc_bin()    { printf '%s\n' "${BC250_VENV}/bin/$1"; }

mod_describe()    { printf 'CPU overclock / undervolt (bc250_smu_oc)\n'; }
# Calibrating before the core count and GPU routing are settled produces a
# curve that is stale the moment it is written: both change the power and
# thermal budget this overclock is measured against.
mod_requires()    { printf '50-cpu-cores\n40-gpu-cu\n'; }
mod_conflicts()   { :; }
mod_invalidates() { :; }
mod_stage()       { printf 'runtime\n'; }

# Calibration loads every core for minutes and asks questions: never run it
# unattended from the post-reboot resume unit.
mod_unattended()  { return 1; }
mod_risk()        { printf 'high\n'; }
mod_needs_smu()   { return 0; }
mod_upstream()    { src_get SMU_OC REPO; }

_oc_requested() { (( ${BC250_CPU_OC_FREQ:-0} > 0 && ${BC250_CPU_OC_VID:-0} > 0 )); }

# Active when a calibrated overclock is installed.
mod_active() { unit_exists "$OC_SERVICE"; }

mod_detect() {
	if _oc_requested; then
		unit_exists "$OC_SERVICE" && [[ -f $(_oc_applied) ]]
	else
		! unit_exists "$OC_SERVICE"
	fi
}

mod_status() {
	if ! _oc_requested; then
		printf 'no overclock requested\n'
		return 0
	fi
	printf '%s MHz @ max %s mV, %s\n' \
		"${BC250_CPU_OC_FREQ}" "${BC250_CPU_OC_VID}" "$(unit_status_line "$OC_SERVICE")"
}

# _oc_venv — creates the venv and installs the pinned package into it.
_oc_venv() {
	local src
	src=$(src_git SMU_OC)

	if [[ ! -x $(_oc_bin python) && ! -x $(_oc_bin python3) ]]; then
		log_info "creating the Python environment"
		bc_run python3 -m venv "$BC250_VENV" || die "could not create a venv at $BC250_VENV"
	fi

	log_info "installing bc250_smu_oc"
	bc_run "${BC250_VENV}/bin/pip" install --quiet --upgrade "$src" ||
		die "pip install failed for bc250_smu_oc"
}

mod_install() {
	hw_require_bc250

	if ! _oc_requested; then
		log_info "this profile does not ask for a CPU overclock"
		mod_uninstall
		return 0
	fi

	# config_validate has already refused anything above the voltage ceiling;
	# this is the last point at which a human sees the numbers.
	log_warn "about to stress-test ${BC250_CPU_OC_FREQ} MHz at up to ${BC250_CPU_OC_VID} mV"
	log_warn "the hard limit is ${VID_ABSOLUTE_MAX} mV; past that the SoC is destroyed"
	confirm "Run the overclock calibration now? It will load all cores for several minutes." ||
		{ log_info "skipped"; return 0; }

	# `stress` is what bc250-detect drives the load with.
	ostree_pkg_install stress
	if ! command -v stress >/dev/null 2>&1; then
		log_warn "'stress' was layered but is not available yet; reboot and re-run this module"
		return 0
	fi

	_oc_venv
	mod_configure
}

mod_configure() {
	_oc_requested || return 0
	[[ -x $(_oc_bin bc250-detect) ]] || die "bc250_smu_oc is not installed; bc_run 'bc250ctl install cpu-oc'"

	log_step "calibrating (this loads every core; it takes a few minutes)"
	# bc250-detect writes SMU state as it probes, so the governor cannot be
	# running: they share the PCI index/data window.
	smu_critical bc_run "$(_oc_bin bc250-detect)" \
		-f "$BC250_CPU_OC_FREQ" \
		-v "$BC250_CPU_OC_VID" \
		-t "$BC250_CPU_OC_TEMP" \
		-c "$(_oc_conf)" ||
		die "calibration failed or was interrupted; nothing was made permanent"

	[[ ${BC250_DRY_RUN:-0} == 1 || -f $(_oc_conf) ]] ||
		die "calibration produced no configuration at $(_oc_conf)"

	log_step "installing the boot service"
	smu_critical bc_run "$(_oc_bin bc250-apply)" --install "$(_oc_conf)" ||
		die "could not install the overclock service"

	unit_enable_now "$OC_SERVICE"
	state_del "stale.60-cpu-oc"
}

mod_verify() {
	if ! _oc_requested; then
		log_ok "no overclock requested"
		return 0
	fi

	if ! unit_exists "$OC_SERVICE"; then
		log_error "$OC_SERVICE is missing: the overclock will not be reapplied at boot"
		return 1
	fi
	log_ok "$OC_SERVICE present ($(unit_status_line "$OC_SERVICE"))"

	if [[ -r $(_oc_applied) ]]; then
		log_info "applied configuration:"
		sed 's/^/    /' -- "$(_oc_applied)" >&2
	fi

	if [[ $(state_get "stale.60-cpu-oc" 0) == 1 ]]; then
		log_warn "this overclock was calibrated before the core count or GPU routing changed;" \
		         "re-run 'bc250ctl install cpu-oc'"
		return 1
	fi
}

mod_uninstall() {
	unit_disable_now "$OC_SERVICE"
	if [[ -x $(_oc_bin bc250-apply) ]]; then
		smu_critical bc_run "$(_oc_bin bc250-apply)" --uninstall || true
	fi
	unit_remove "$OC_SERVICE"
	state_del "stale.60-cpu-oc"
	log_info "the overclock itself clears at the next reboot"
	return 0
}
