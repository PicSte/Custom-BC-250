# shellcheck shell=bash
#
# Kernel arguments.
#
# ttm.pages_limit / ttm.page_pool_size lift the TTM allocation cap so the GPU
# can actually reach the shared memory the board has; without them large
# allocations fail well below the installed 16 GB. mitigations=off is a
# straight performance trade against CPU side-channel hardening, so it stays
# opt-in per profile.

KARG_TTM_PAGES='ttm.pages_limit=3959290'
KARG_TTM_POOL='ttm.page_pool_size=3959290'
KARG_MITIGATIONS='mitigations=off'

mod_describe()    { printf 'kernel arguments (TTM memory limits, mitigations)\n'; }
mod_requires()    { :; }
mod_invalidates() { :; }
mod_stage()       { printf 'pre-reboot\n'; }
mod_unattended()  { return 0; }

_kargs_wanted() {
	[[ ${BC250_KARGS_TTM:-1} == 1 ]] && printf '%s\n%s\n' "$KARG_TTM_PAGES" "$KARG_TTM_POOL"
	[[ ${BC250_KARGS_MITIGATIONS_OFF:-0} == 1 ]] && printf '%s\n' "$KARG_MITIGATIONS"
	return 0
}

# Active when any kernel argument we manage is on the deployment.
mod_active() {
	local karg
	for karg in "$KARG_TTM_PAGES" "$KARG_TTM_POOL" "$KARG_MITIGATIONS"; do
		ostree_karg_present "$karg" && return 0
	done
	return 1
}

mod_detect() {
	local karg wanted
	wanted=$(_kargs_wanted)
	[[ -n $wanted ]] || return 0
	while IFS= read -r karg; do
		[[ -n $karg ]] || continue
		ostree_karg_present "$karg" || return 1
	done <<<"$wanted"
	return 0
}

mod_status() {
	local karg out=()
	for karg in "$KARG_TTM_PAGES" "$KARG_TTM_POOL" "$KARG_MITIGATIONS"; do
		ostree_karg_present "$karg" && out+=("${karg%%=*}")
	done
	if (( ${#out[@]} == 0 )); then
		printf 'none of our kernel arguments are set\n'
	else
		printf 'set: %s\n' "${out[*]}"
	fi
}

mod_install() {
	ostree_require_atomic
	local karg wanted
	wanted=$(_kargs_wanted)
	if [[ -z $wanted ]]; then
		log_info "no kernel arguments requested by this profile"
		return 0
	fi
	while IFS= read -r karg; do
		[[ -n $karg ]] || continue
		ostree_karg_add "$karg"
	done <<<"$wanted"
}

mod_configure() { mod_install; }

mod_verify() {
	local cmdline="${BC250_PREFIX}/proc/cmdline" karg wanted missing=0
	wanted=$(_kargs_wanted)
	[[ -n $wanted ]] || { log_ok "no kernel arguments requested"; return 0; }

	if [[ ! -r $cmdline ]]; then
		log_warn "cannot read $cmdline; falling back to the staged deployment"
		mod_detect && { log_ok "kernel arguments staged"; return 0; }
		return 1
	fi

	local booted
	booted=$(<"$cmdline")
	while IFS= read -r karg; do
		[[ -n $karg ]] || continue
		if [[ " $booted " == *" $karg "* ]]; then
			log_ok "booted with $karg"
		else
			log_warn "not in the running kernel command line: $karg (reboot pending?)"
			missing=1
		fi
	done <<<"$wanted"
	return "$missing"
}

mod_uninstall() {
	ostree_karg_remove "$KARG_TTM_PAGES" "$KARG_TTM_POOL" "$KARG_MITIGATIONS"
}
