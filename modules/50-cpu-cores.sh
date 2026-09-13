# shellcheck shell=bash
#
# CPU cores: 6 -> 8.
#
# Two of the eight Zen 2 cores are masked off, not fused off. The mask lives
# in an SMU register (0x77 -> 0xFF) that is writable from the host, so no BIOS
# flash is involved.
#
# Two things follow from the mask being volatile, and both are load-bearing:
#
#   * A cold power cycle resets it. That is the escape hatch — if eight cores
#     turn out to be unstable on your board, pull the power and you are back
#     to six, whatever state the software is in.
#   * The write only takes effect at the *next* reboot. The boot unit we
#     install re-arms the mask on every boot, so a warm reboot always comes up
#     with eight cores; the first boot after a cold start still has six.

CORES_SERVICE='bc250ctl-cpu-cores.service'

mod_describe()    { printf 'CPU core unlock (6c/12t -> 8c/16t, SMU core mask)\n'; }
# Without the rebuilt SSDT tables, CPUs 12-15 come up with no idle states at
# all and burn power doing nothing. The unlock is not worth having without it.
mod_requires()    { printf '15-acpi\n'; }
mod_conflicts()   { :; }
# An OC curve tuned on 6 cores is not valid on 8. And pp_dpm_sclk starts
# reporting nonsense once the extra cores are up, so the governor's own
# verification has to be re-read with that in mind.
mod_invalidates() { printf '60-cpu-oc\n30-governor\n'; }
mod_stage()       { printf 'runtime\n'; }
mod_unattended()  { return 0; }
mod_risk()        { printf 'high\n'; }
mod_needs_smu()   { return 0; }
mod_upstream()    { src_get CU_LIVE_MANAGER REPO; }

# Active when the core mask is re-armed at boot.
mod_active() { unit_exists "$CORES_SERVICE"; }

mod_detect() {
	if [[ ${BC250_CPU_CORES:-6} == 8 ]]; then
		unit_exists "$CORES_SERVICE"
	else
		! unit_exists "$CORES_SERVICE"
	fi
}

mod_status() {
	local now
	now=$(hw_cpu_cores)
	if [[ ${BC250_CPU_CORES:-6} != 8 ]]; then
		printf 'stock (%s cores online)\n' "$now"
		return 0
	fi
	printf 'boot unit %s, %s cores online\n' "$(unit_status_line "$CORES_SERVICE")" "$now"
}

mod_install() {
	hw_require_bc250

	if [[ ${BC250_CPU_CORES:-6} != 8 ]]; then
		log_info "profile asks for stock 6 cores"
		mod_uninstall
		return 0
	fi

	# Already armed and the cores are up: re-arming would mark another reboot
	# as needed and the bootstrap would never converge.
	if mod_detect && [[ $(hw_cpu_cores) == 8 ]]; then
		log_ok "8 cores are already online and the boot unit is in place"
		return 0
	fi

	lm_install_script

	confirm "Unlock the 2 factory-disabled CPU cores? A cold power cycle undoes this." ||
		{ log_info "skipped"; return 0; }

	mod_configure
}

mod_configure() {
	[[ ${BC250_CPU_CORES:-6} == 8 ]] || return 0
	lm_installed || die "bc250-cu-live-manager is not installed; bc_run 'bc250ctl install cpu-cores' first"

	log_step "arming the SMU core mask"
	# The governor drives the same PCI index/data window as this write.
	smu_critical lm_run cpu-unlock

	# Re-arm on every boot: the mask does not survive a cold power cycle.
	unit_install "$CORES_SERVICE" <<-EOC
		[Unit]
		Description=BC-250 CPU core unlock (arm the SMU core mask)
		Documentation=https://github.com/WinnieLV/bc250-cu-live-manager
		After=multi-user.target

		[Service]
		Type=oneshot
		RemainAfterExit=yes
		ExecStart=$(lm_bin) cpu-unlock --yes

		[Install]
		WantedBy=multi-user.target
	EOC

	unit_enable_now "$CORES_SERVICE"
	reboot_mark_required
	log_warn "the extra cores come up at the next reboot, not immediately"
}

mod_verify() {
	local cores
	cores=$(hw_cpu_cores)

	if [[ ${BC250_CPU_CORES:-6} != 8 ]]; then
		log_ok "stock core count requested; ${cores} cores online"
		return 0
	fi

	if ! unit_exists "$CORES_SERVICE"; then
		log_error "$CORES_SERVICE is missing: the unlock will not be re-armed at boot"
		return 1
	fi
	log_ok "$CORES_SERVICE present ($(unit_status_line "$CORES_SERVICE"))"

	if [[ $cores == 8 ]]; then
		log_ok "8 cores online"
	else
		log_warn "${cores} cores online — reboot to bring up the other two"
	fi
}

mod_uninstall() {
	unit_remove "$CORES_SERVICE"
	log_info "the mask itself clears on the next cold power cycle"
	return 0
}
