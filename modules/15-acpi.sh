# shellcheck shell=bash
#
# ACPI processor tables.
#
# The board's stock SSDT declares processor objects up to C00B — twelve
# threads. That is fine on a stock six-core BC-250 and wrong the moment the
# two masked cores come online: CPUs 12-15 get no cpuidle states at all and
# sit burning power at idle.
#
# The rebuilt tables extend the declarations to C00F and also carry the
# P-state table (800-3200 MHz scaling), which is worth having at six cores
# too. That is why this module is in the `safe` profile and not treated purely
# as a dependency of the core unlock.
#
# They are loaded before the firmware's own tables, from a cpio archive that
# GRUB hands to the kernel as an early initrd.

ACPI_CPIO_NAME='SSDT_ACPI.cpio'
# The path is relative to GRUB's view of /boot, not to the filesystem root.
ACPI_GRUB_VALUE='../../SSDT_ACPI.cpio'
ACPI_GRUB_KEY='GRUB_EARLY_INITRD_LINUX_CUSTOM'
CPUFREQ_SERVICE='bc250ctl-cpu-governor.service'
CPUFREQ_SYSFS='/sys/devices/system/cpu/cpufreq'

_acpi_cpio()      { printf '%s\n' "${BC250_PREFIX}/boot/${ACPI_CPIO_NAME}"; }
_acpi_grub_conf() { printf '%s\n' "${BC250_PREFIX}/etc/default/grub"; }

mod_describe()    { printf 'tables ACPI (C-states pour 16 threads, P-states)\n'; }
mod_requires()    { :; }
mod_conflicts()   { :; }
mod_invalidates() { :; }
mod_stage()       { printf 'pre-reboot\n'; }
mod_unattended()  { return 0; }
mod_risk()        { printf 'low\n'; }
mod_needs_smu()   { return 1; }
mod_upstream()    { src_get ACPI_CST REPO; }

_acpi_grub_set() {
	[[ -f $(_acpi_grub_conf) ]] &&
		grep -q "^${ACPI_GRUB_KEY}=" -- "$(_acpi_grub_conf)"
}

# Active when the tables are installed, whatever the profile asks for.
mod_active() {
	{ [[ -f $(_acpi_cpio) ]] && _acpi_grub_set; } || unit_exists "$CPUFREQ_SERVICE"
}

mod_detect() {
	if [[ ${BC250_ACPI:-1} != 1 ]]; then
		! mod_active
		return
	fi
	[[ -f $(_acpi_cpio) ]] && _acpi_grub_set || return 1
	[[ ${BC250_CPU_GOVERNOR:-schedutil} == none ]] || unit_exists "$CPUFREQ_SERVICE"
}

mod_status() {
	if [[ ${BC250_ACPI:-1} != 1 ]]; then
		printf 'tables du firmware, non modifiées\n'
		return 0
	fi
	if ! mod_active; then
		printf 'non installées\n'
		return 0
	fi
	local zero
	zero=$(cpupower -c all idle-info 2>/dev/null | grep -c 'Number of idle states: 0' || true)
	if [[ ${zero:-0} == 0 ]]; then
		printf 'installées, tous les CPU ont des états de repos\n'
	else
		printf 'installées, %s CPU encore sans état de repos (redémarrage en attente ?)\n' "$zero"
	fi
}

mod_install() {
	ostree_require_atomic

	if [[ ${BC250_ACPI:-1} != 1 ]]; then
		log_info "this profile keeps the stock firmware tables"
		mod_uninstall
		return 0
	fi

	local cst pst
	cst=$(src_file ACPI_CST)
	pst=$(src_file ACPI_PST)

	if [[ ${BC250_DRY_RUN:-0} == 1 ]]; then
		log_debug "[dry-run] would build ${ACPI_CPIO_NAME} from $cst and $pst"
	else
		command -v cpio >/dev/null 2>&1 ||
			die "cpio is needed to build the ACPI archive"

		# The kernel looks for the tables at this exact path inside the cpio.
		local build
		build=$(mktemp -d)
		mkdir -p "$build/kernel/firmware/acpi"
		install -m 0644 -- "$cst" "$pst" "$build/kernel/firmware/acpi/"

		mkdir -p -- "$(dirname -- "$(_acpi_cpio)")"
		( cd "$build" && find kernel | cpio -H newc --create --quiet ) >"$(_acpi_cpio)" ||
			die "could not build $(_acpi_cpio)"
		chmod 0644 -- "$(_acpi_cpio)"
		rm -rf -- "$build"
		log_ok "built $(_acpi_cpio)"
	fi

	mod_configure
}

mod_configure() {
	[[ ${BC250_ACPI:-1} == 1 ]] || return 0

	# The GRUB entry is written once; the governor is re-applied on every
	# configure, because that is the part the profile can change.
	if _acpi_grub_set; then
		log_debug "GRUB already loads the early ACPI archive"
		_cpu_governor_configure
		return 0
	fi

	if [[ ${BC250_DRY_RUN:-0} == 1 ]]; then
		log_debug "[dry-run] would append ${ACPI_GRUB_KEY} to $(_acpi_grub_conf)"
	else
		mkdir -p -- "$(dirname -- "$(_acpi_grub_conf)")"
		printf '\n# Added by bc250ctl: load the rebuilt BC-250 SSDT tables early.\n%s="%s"\n' \
			"$ACPI_GRUB_KEY" "$ACPI_GRUB_VALUE" >>"$(_acpi_grub_conf)"
		log_ok "told GRUB to load the ACPI archive"
	fi

	_acpi_regenerate_grub
	reboot_mark_required
	_cpu_governor_configure
}

# The P-state table is the half of this fix nothing else uses: once it is
# loaded the CPU has cpufreq for the first time, and something has to pick a
# scaling governor or the kernel default stands. The setting is here rather
# than in a module of its own because without these tables there is no
# cpufreq at all to govern.
_cpu_governor_configure() {
	local wanted=${BC250_CPU_GOVERNOR:-schedutil}

	if [[ $wanted == none ]]; then
		log_info "governor CPU laissé au système"
		unit_remove "$CPUFREQ_SERVICE"
		return 0
	fi

	write_file "$(_cpu_governor_script)" 0755 <<-'EOC'
		#!/usr/bin/env bash
		# Written by bc250ctl. Sets the CPU scaling governor given as $1.
		set -euo pipefail

		governor=${1:?usage: bc250ctl-cpu-governor <name>}

		available=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors 2>/dev/null) || {
			echo "no cpufreq on this system; are the ACPI P-state tables loaded?" >&2
			exit 1
		}
		case " $available " in
			*" $governor "*) ;;
			*) echo "governor '$governor' not available (have: $available)" >&2; exit 1 ;;
		esac

		for cpu in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do
			[[ -w $cpu ]] && echo "$governor" >"$cpu"
		done
	EOC

	unit_install "$CPUFREQ_SERVICE" <<-EOC
		[Unit]
		Description=BC-250 CPU scaling governor
		After=multi-user.target
		ConditionPathExists=${CPUFREQ_SYSFS}

		[Service]
		Type=oneshot
		RemainAfterExit=yes
		ExecStart=$(_cpu_governor_script) ${wanted}

		[Install]
		WantedBy=multi-user.target
	EOC

	unit_enable_now "$CPUFREQ_SERVICE"
}

_cpu_governor_script() { printf '%s\n' "${LOCAL_BIN}/bc250ctl-cpu-governor"; }

# Bazzite wraps grub2-mkconfig in a ujust recipe; fall back to the tool itself
# on an image that does not ship it.
_acpi_regenerate_grub() {
	if command -v ujust >/dev/null 2>&1; then
		bc_run ujust regenerate-grub && return 0
		log_warn "'ujust regenerate-grub' failed; trying grub2-mkconfig"
	fi
	if command -v grub2-mkconfig >/dev/null 2>&1; then
		bc_run grub2-mkconfig -o "${BC250_PREFIX}/boot/grub2/grub.cfg" && return 0
	fi
	die "could not regenerate the GRUB configuration; the tables will not load"
}

mod_verify() {
	if [[ ${BC250_ACPI:-1} != 1 ]]; then
		log_ok "stock firmware tables, as configured"
		return 0
	fi

	if ! mod_active; then
		log_error "the ACPI archive or its GRUB entry is missing"
		return 1
	fi
	log_ok "archive installed and referenced by GRUB"

	if ! command -v cpupower >/dev/null 2>&1; then
		log_warn "cpupower not found; cannot confirm the tables are in effect" \
		         "(layer it with: rpm-ostree install kernel-tools)"
		return 0
	fi

	local zero
	zero=$(cpupower -c all idle-info 2>/dev/null | grep -c 'Number of idle states: 0' || true)
	if [[ ${zero:-0} != 0 ]]; then
		log_error "${zero} CPU(s) report no idle states — the rebuilt tables are not loaded." \
		          "If you have just installed them, reboot first."
		return 1
	fi
	log_ok "every CPU has idle states"

	if cpupower frequency-info 2>/dev/null | grep -q 'steps\|available frequency'; then
		log_ok "P-states are exposed"
	fi

	_cpu_governor_verify
}

_cpu_governor_verify() {
	local wanted=${BC250_CPU_GOVERNOR:-schedutil}
	[[ $wanted == none ]] && { log_ok "governor CPU laissé au système"; return 0; }

	if ! unit_exists "$CPUFREQ_SERVICE"; then
		log_error "$CPUFREQ_SERVICE est absent : le governor CPU ne sera pas reposé au démarrage"
		return 1
	fi
	log_ok "$CPUFREQ_SERVICE présent ($(unit_status_line "$CPUFREQ_SERVICE"))"

	local current="${BC250_PREFIX}/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor"
	if [[ -r $current ]]; then
		if [[ $(<"$current") == "$wanted" ]]; then
			log_ok "governor CPU actif : $wanted"
		else
			log_warn "governor CPU actuellement « $(<"$current") », attendu « $wanted »" \
			         "— un redémarrage peut être nécessaire"
		fi
	fi
}

mod_uninstall() {
	unit_remove "$CPUFREQ_SERVICE"
	[[ -f $(_cpu_governor_script) ]] && bc_run rm -f -- "$(_cpu_governor_script)"
	[[ -f $(_acpi_cpio) ]] && bc_run rm -f -- "$(_acpi_cpio)"

	if _acpi_grub_set && [[ ${BC250_DRY_RUN:-0} != 1 ]]; then
		local conf tmp
		conf=$(_acpi_grub_conf)
		tmp="${conf}.bc250ctl.$$"
		grep -v "^${ACPI_GRUB_KEY}=" -- "$conf" |
			grep -v '^# Added by bc250ctl: load the rebuilt BC-250 SSDT tables early\.$' >"$tmp" || true
		mv -- "$tmp" "$conf"
		_acpi_regenerate_grub
		reboot_mark_required
	fi
	return 0
}
