# shellcheck shell=bash
#
# Shared plumbing for bc250-cu-live-manager.
#
# One upstream script covers both the GPU CU/WGP routing and the SMU CPU core
# unlock, so the two modules that use it share the fetch and install logic
# here rather than each carrying its own copy.

export LM_SERVICE='bc250-cu-live-manager.service'

lm_bin()     { printf '%s\n' "${LOCAL_BIN}/bc250-cu-live-manager"; }
lm_conf()    { printf '%s\n' "${BC250_PREFIX}/etc/bc250-cu-live-manager.conf"; }

# lm_installed — true when the upstream script is on the system.
lm_installed() { [[ -x $(lm_bin) ]] || command -v bc250-cu-live-manager >/dev/null 2>&1; }

# lm_cmd — the command to invoke, preferring our verified copy.
lm_cmd() {
	if [[ -x $(lm_bin) ]]; then
		printf '%s\n' "$(lm_bin)"
	else
		printf 'bc250-cu-live-manager\n'
	fi
}

# lm_run <args...> — runs the manager non-interactively.
#
# --yes is always passed: every call site here has already asked the user for
# the confirmation that matters, and the upstream prompt would otherwise block
# an unattended bootstrap.
lm_run() {
	local cmd
	cmd=$(lm_cmd)
	if [[ ${BC250_DRY_RUN:-0} == 1 ]]; then
		bc_run "$cmd" "$@" --yes --dry-run
	else
		bc_run "$cmd" "$@" --yes
	fi
}

# lm_install_script — fetches the pinned script and puts it in place.
lm_install_script() {
	local src
	src=$(src_file CU_LIVE_MANAGER)

	if [[ ${BC250_DRY_RUN:-0} == 1 ]]; then
		log_debug "[dry-run] would install $src to $(lm_bin)"
		return 0
	fi

	mkdir -p -- "$LOCAL_BIN"
	install -m 0755 -- "$src" "$(lm_bin)"
	log_ok "installed bc250-cu-live-manager ($(src_get CU_LIVE_MANAGER REF | cut -c1-12))"
}

# lm_ensure_umr — makes sure umr is available, delegating the package name to
# upstream. Returns 1 when umr will only appear after a reboot.
lm_ensure_umr() {
	if hw_has_umr; then
		log_debug "umr is present"
		return 0
	fi

	log_info "umr is missing; asking bc250-cu-live-manager to install it"
	lm_run install-umr || log_warn "install-umr did not succeed"

	if hw_has_umr; then
		return 0
	fi

	# On an atomic system umr was layered and only lands after a reboot.
	log_warn "umr is not available yet — it was most likely layered and needs a reboot"
	reboot_mark_required
	return 1
}
