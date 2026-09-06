# shellcheck shell=bash
#
# GPU compute units: the 40 CU unlock and WGP routing.
#
# The board ships with 24 of its 40 CUs routed. Three registers decide that —
# CC_GC_SHADER_ARRAY_CONFIG, SPI_PG_ENABLE_STATIC_WGP_MASK and
# RLC_PG_ALWAYS_ON_WGP_MASK — and bc250-cu-live-manager writes them from
# userspace through umr, after the driver is up. Nothing here patches or
# rebuilds a kernel module, so a Bazzite kernel update cannot break it; the
# writes are replayed at each boot by the upstream systemd unit.
#
# Granularity is the WGP, which is a pair of CUs: a single CU cannot be routed
# on its own. BC250_GPU_WGP_LAYOUT takes 'all', 'stock', or a comma-separated
# list of SE.SH.WGP triples to leave disabled (for a board with a bad WGP).

mod_describe()    { printf '40 CU unlock and WGP routing (runtime, via umr)\n'; }
mod_requires()    { :; }
mod_invalidates() { printf '60-cpu-oc\n'; }   # changes the shared power/thermal budget
mod_stage()       { printf 'runtime\n'; }
mod_unattended()  { return 0; }

# Active when a routing table is replayed at boot.
mod_active() { unit_exists "$LM_SERVICE"; }

mod_detect() {
	if [[ ${BC250_GPU_WGP_LAYOUT:-stock} == stock ]]; then
		# Stock means we have nothing installed to replay at boot.
		! unit_exists "$LM_SERVICE"
	else
		lm_installed && unit_exists "$LM_SERVICE" && [[ -f $(lm_conf) ]]
	fi
}

mod_status() {
	if [[ ${BC250_GPU_WGP_LAYOUT:-stock} == stock ]]; then
		printf 'stock routing (24 CU)\n'
		return 0
	fi
	printf 'layout "%s", boot service %s\n' \
		"${BC250_GPU_WGP_LAYOUT}" "$(unit_status_line "$LM_SERVICE")"
}

mod_install() {
	hw_require_bc250
	lm_install_script

	if [[ ${BC250_GPU_WGP_LAYOUT:-stock} == stock ]]; then
		log_info "profile asks for stock routing; nothing to unlock"
		mod_uninstall
		return 0
	fi

	lm_ensure_umr || {
		log_warn "deferring the CU unlock until umr is available after the reboot"
		return 0
	}

	mod_configure
}

mod_configure() {
	local layout=${BC250_GPU_WGP_LAYOUT:-stock}
	[[ $layout == stock ]] && return 0

	lm_installed || die "bc250-cu-live-manager is not installed; bc_run 'bc250ctl install gpu-cu' first"
	hw_has_umr   || die "umr is not available; reboot and re-run 'bc250ctl install gpu-cu'"

	log_step "routing WGPs"
	lm_run enable all

	if [[ $layout != all ]]; then
		# Anything that is not 'all' or 'stock' is a disable list, e.g.
		# "1.0.3,0.1.4" to keep a known-bad WGP pair out of the routing.
		local -a to_disable
		IFS=',' read -r -a to_disable <<<"$layout"
		log_info "leaving these WGPs disabled: ${to_disable[*]}"
		lm_run disable-wgp "${to_disable[@]}"
	fi

	# Snapshot the live table, then have it replayed at boot.
	lm_run write-service-table
	lm_run install-service
}

mod_verify() {
	local layout=${BC250_GPU_WGP_LAYOUT:-stock}

	if [[ $layout == stock ]]; then
		unit_exists "$LM_SERVICE" && {
			log_error "profile is stock but the boot service is still installed"
			return 1
		}
		log_ok "stock routing, no boot service"
		return 0
	fi

	if ! unit_exists "$LM_SERVICE"; then
		log_error "the boot service is missing: the unlock will not survive a reboot"
		return 1
	fi
	log_ok "boot service present ($(unit_status_line "$LM_SERVICE"))"

	# The authoritative check: what the Vulkan driver actually enumerates.
	if command -v vulkaninfo >/dev/null 2>&1; then
		local info
		info=$(RADV_DEBUG=info vulkaninfo --summary 2>&1 | grep -m1 'num_cu' || true)
		if [[ -n $info ]]; then
			log_info "driver reports: ${info#"${info%%[![:space:]]*}"}"
			[[ $layout == all && $info != *"= 40"* ]] &&
				log_warn "expected 40 CUs for layout 'all'"
		fi
	else
		log_warn "vulkaninfo not found; cannot confirm the CU count from the driver"
	fi

	log_info "live routing table:"
	lm_run status || true
}

mod_uninstall() {
	lm_installed || return 0
	lm_run uninstall-service || true
	lm_run stock-dispatch || log_warn "could not restore stock dispatch; a cold boot also resets it"
	return 0
}
