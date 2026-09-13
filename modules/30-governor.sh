# shellcheck shell=bash
#
# GPU governor.
#
# The BC-250's SMU does no useful power management on its own: without a
# governor the GPU sits at a fixed clock. cyan-skillfish-governor-smu drives
# frequency and voltage from load and temperature.
#
# The governor finds the GPU itself — there is no device setting in its config
# — so the card we detect here is only used to read frequencies back when
# verifying.

GOV_PKG='cyan-skillfish-governor-smu'
GOV_SERVICE='cyan-skillfish-governor-smu.service'
COPR_OWNER='filippor'
COPR_PROJECT='bazzite'

_gov_config_file() { printf '%s\n' "${BC250_PREFIX}/etc/${GOV_PKG}/config.toml"; }

# The frequency/voltage curve shipped as the upstream default. We never invent
# points: the profile only decides how far up this curve to go.
GOV_CURVE=(
	500:700
	1000:800
	1175:850
	1500:900
	1600:910
	1700:920
	1850:930
	2000:960
)

mod_describe()    { printf 'GPU governor (%s)\n' "$GOV_PKG"; }
mod_requires()    { :; }
mod_conflicts()   { :; }
mod_invalidates() { :; }
mod_stage()       { printf 'pre-reboot\n'; }
mod_unattended()  { return 0; }
mod_risk()        { printf 'low\n'; }
mod_needs_smu()   { return 1; }
mod_upstream()    { printf 'https://github.com/filippor/cyan-skillfish-governor\n'; }

# Active when the governor package is layered.
mod_active() { ostree_pkg_layered "$GOV_PKG"; }

mod_detect() { ostree_pkg_layered "$GOV_PKG"; }

mod_status() {
	if ! mod_detect; then
		printf 'not installed\n'
		return 0
	fi
	printf '%s, %s-%s MHz / max %s mV\n' \
		"$(unit_status_line "$GOV_SERVICE")" \
		"${BC250_GOV_FREQ_MIN}" "${BC250_GOV_FREQ_MAX}" "${BC250_GOV_VOLT_MAX}"
}

# _gov_safe_points — the curve, cut at the profile's frequency and voltage caps.
_gov_safe_points() {
	local point freq volt kept=0
	for point in "${GOV_CURVE[@]}"; do
		freq=${point%%:*}
		volt=${point##*:}
		(( freq <= BC250_GOV_FREQ_MAX )) || continue
		(( volt <= BC250_GOV_VOLT_MAX )) || continue
		printf '[[safe-points]]\nfrequency = %s\nvoltage = %s\n\n' "$freq" "$volt"
		kept=$(( kept + 1 ))
	done
	(( kept > 0 )) || die "no point on the governor curve fits BC250_GOV_FREQ_MAX=${BC250_GOV_FREQ_MAX}" \
	                      "with BC250_GOV_VOLT_MAX=${BC250_GOV_VOLT_MAX}; raise one of them"
}

mod_install() {
	ostree_require_atomic
	copr_enable "$COPR_OWNER" "$COPR_PROJECT"
	ostree_pkg_install "$GOV_PKG"

	if reboot_is_required; then
		log_info "$GOV_PKG is layered; it will be configured and started after the reboot"
		return 0
	fi
	mod_configure
}

mod_configure() {
	mod_detect || { log_warn "$GOV_PKG is not installed yet, skipping configuration"; return 0; }

	{
		cat <<-EOC
			# Managed by bc250ctl — edits here are overwritten by
			# 'bc250ctl configure governor'. Change profiles/ or
			# /etc/bc250ctl/config.env instead.

			[timing.intervals]
			sample = 250
			adjust = 100_000

			[gpu-usage]
			fix-metrics = true
			fix-freq = false
			method = "busy-flag"
			flush-every = 10

			[gpu]
			set-method = "smu"

			[dbus]
			enabled = true

			[frequency-range]
			min = ${BC250_GOV_FREQ_MIN}
			max = ${BC250_GOV_FREQ_MAX}

			[timing.ramp-rates]
			normal = 1
			burst = 50

			[timing]
			burst-samples = 60
			down-events = 5

			[frequency-thresholds]
			adjust = 10

			[load-target]
			upper = 0.65
			lower = 0.50

			[temperature]
			throttling = 85
			throttling_recovery = 75

		EOC
		_gov_safe_points
	} | write_file "$(_gov_config_file)" 0644

	unit_enable_now "$GOV_SERVICE"
}

mod_verify() {
	if ! mod_detect; then
		log_error "$GOV_PKG is not installed"
		return 1
	fi

	if ! unit_is_active "$GOV_SERVICE"; then
		log_error "$GOV_SERVICE is not running (journalctl -u $GOV_SERVICE)"
		return 1
	fi
	log_ok "$GOV_SERVICE is running"

	local card sclk
	if card=$(hw_gpu_card); then
		log_ok "BC-250 GPU is $card"
		sclk="${SYSFS_DRM}/${card}/device/pp_dpm_sclk"
		if [[ -r $sclk ]]; then
			log_info "current clocks:"
			sed 's/^/    /' -- "$sclk" >&2
			# Known defect: the unlocked core count corrupts what this table
			# reports. The governor is still doing its job; only the readout
			# is wrong, so it must not be read as a failure.
			if [[ $(hw_cpu_cores) == 8 ]]; then
				log_warn "with 8 cores unlocked, pp_dpm_sclk misreports frequencies —" \
				         "read the clocks with amdgpu_top or nvtop instead"
			fi
		fi
	else
		log_warn "could not resolve which DRM card is the BC-250"
	fi
}

mod_uninstall() {
	unit_disable_now "$GOV_SERVICE"
	ostree_pkg_remove "$GOV_PKG" || log_warn "could not remove $GOV_PKG"
	copr_disable "$COPR_OWNER" "$COPR_PROJECT"
	[[ -f $(_gov_config_file) ]] && bc_run rm -f -- "$(_gov_config_file)"
	return 0
}
