# shellcheck shell=bash
#
# Kernel arguments.
#
# ttm.pages_limit / ttm.page_pool_size lift the TTM allocation cap so the GPU
# can actually reach the shared memory the board has; without them large
# allocations fail well below the installed 16 GB. mitigations=off is a
# straight performance trade against CPU side-channel hardening, so it stays
# opt-in per profile.

KARG_MITIGATIONS='mitigations=off'
# DisplayPort hot-plug detect is broken on this board: the kernel can come up
# without ever noticing the monitor. Forcing the connector on is the blunt fix.
KARG_DP_FORCE='video=DP-1:e'
# Scatter-gather display is broken on this board, but only the kernels that
# still have it need telling: the option was removed upstream in 6.10.
KARG_SG_DISPLAY='amdgpu.sg_display=0'
SG_DISPLAY_LAST_KERNEL='6.10'

# Keys we manage, for status and for removal — the TTM limits carry a
# configurable value, so they cannot be matched as fixed strings.
KARG_KEYS=(
	ttm.pages_limit
	ttm.page_pool_size
	amdgpu.gttsize
	amdgpu.sg_display
	mitigations
	video
	zswap.enabled
	zswap.compressor
	zswap.zpool
)

mod_describe()    { printf 'arguments noyau (limites mémoire TTM, mitigations)\n'; }
mod_requires()    { :; }
mod_conflicts()   { :; }
mod_invalidates() { :; }
mod_stage()       { printf 'pre-reboot\n'; }
mod_unattended()  { return 0; }
mod_risk()        { printf 'low\n'; }
mod_needs_smu()   { return 1; }
mod_upstream()    { :; }

_kargs_wanted() {
	if [[ ${BC250_KARGS_TTM:-1} == 1 ]]; then
		local limit=${BC250_TTM_PAGES_LIMIT:-3959290}
		printf 'ttm.pages_limit=%s\n' "$limit"
		printf 'ttm.page_pool_size=%s\n' "$limit"
		# Lets the GPU reach ~14.5 GB of system memory, which is the point of
		# raising the TTM limits in the first place.
		printf 'amdgpu.gttsize=14750\n'
	fi

	[[ ${BC250_KARGS_MITIGATIONS_OFF:-0} == 1 ]] && printf '%s\n' "$KARG_MITIGATIONS"
	[[ ${BC250_KARGS_DP_FORCE:-0} == 1 ]] && printf '%s\n' "$KARG_DP_FORCE"

	# Only worth setting where the option still exists.
	if _sg_display_needed; then
		printf '%s\n' "$KARG_SG_DISPLAY"
	fi

	if [[ ${BC250_KARGS_ZSWAP:-0} == 1 ]]; then
		printf 'zswap.enabled=1\n'
		printf 'zswap.compressor=lz4\n'
		printf 'zswap.zpool=zsmalloc\n'
	fi
	return 0
}

# _sg_display_needed — true on a kernel old enough to still carry the option.
_sg_display_needed() {
	local release version
	release=$(uname -r)
	version=${release%%-*}
	version=${version%%+*}
	_version_lt "$version" "$SG_DISPLAY_LAST_KERNEL"
}

# Active when any kernel argument we manage is on the deployment.
mod_active() {
	local key present
	present=$(rpm-ostree kargs 2>/dev/null | tr ' ' '\n')
	for key in "${KARG_KEYS[@]}"; do
		grep -q "^${key}=" <<<"$present" && return 0
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
	local key out=() present
	present=$(rpm-ostree kargs 2>/dev/null | tr ' ' '\n')
	for key in "${KARG_KEYS[@]}"; do
		grep -q "^${key}=" <<<"$present" && out+=("$key")
	done
	if (( ${#out[@]} == 0 )); then
		printf 'aucun argument noyau posé\n'
	else
		printf 'posés : %s\n' "${out[*]}"
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
	local key
	for key in "${KARG_KEYS[@]}"; do
		ostree_karg_remove_key "$key"
	done
}
