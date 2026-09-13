# shellcheck shell=bash
#
# Fan control.
#
# Two drivers claim the board's Nuvoton chip and only one can own it:
#
#   nct6683  in-kernel, read-only. Temperatures, nothing else. (20-sensors)
#   nct6687  out-of-tree, read/write. The only way to drive the PWM.
#
# So this module conflicts with 20-sensors rather than extending it. Bazzite
# ships nct6687d as an akmod, so in the usual case there is nothing to install
# and the work is picking the right driver and making the fan speed stick.
#
# The driver does not persist PWM values across a reboot. Either CoolerControl
# owns the curve, or we install a small unit that writes a fixed duty cycle at
# boot — BC250_FAN_PWM decides which.

FAN_MODULE='nct6687'
FAN_SERVICE='bc250ctl-fan.service'
FAN_MODULES_LOAD='99-bc250-fan.conf'
FAN_MODPROBE='99-bc250-fan.conf'

_fan_modules_load_file() { printf '%s\n' "$MODULES_LOAD_DIR/$FAN_MODULES_LOAD"; }
_fan_modprobe_file()     { printf '%s\n' "$MODPROBE_DIR/$FAN_MODPROBE"; }

mod_describe()    { printf 'pilotage des ventilateurs (PWM nct6687, remplace les capteurs)\n'; }
mod_requires()    { :; }
mod_conflicts()   { printf '20-sensors\n'; }
mod_invalidates() { :; }
mod_stage()       { printf 'pre-reboot\n'; }
mod_unattended()  { return 0; }
mod_risk()        { printf 'medium\n'; }
mod_needs_smu()   { return 1; }
mod_upstream()    { printf 'https://github.com/Fred78290/nct6687d\n'; }

mod_active() { [[ -f $(_fan_modules_load_file) || -f $(_fan_modprobe_file) ]]; }

mod_detect() {
	if [[ ${BC250_FAN_CONTROL:-0} == 1 ]]; then
		mod_active
	else
		! mod_active
	fi
}

mod_status() {
	if [[ ${BC250_FAN_CONTROL:-0} != 1 ]]; then
		printf 'désactivé (températures seules, voir sensors)\n'
		return 0
	fi
	if ! mod_active; then
		printf 'non configuré\n'
		return 0
	fi
	local hwmon
	if hwmon=$(_fan_hwmon); then
		printf 'actif sur %s, consigne %s\n' "$(basename "$hwmon")" "${BC250_FAN_PWM:-auto}"
	else
		printf 'configuré, pilote pas encore attaché (redémarrage en attente ?)\n'
	fi
}

# _fan_hwmon — the hwmon directory owned by nct6687, if the driver is bound.
_fan_hwmon() {
	local dir name
	for dir in "${BC250_PREFIX}/sys/class/hwmon"/hwmon[0-9]*; do
		[[ -r $dir/name ]] || continue
		read -r name <"$dir/name"
		if [[ $name == "$FAN_MODULE" ]]; then
			printf '%s\n' "$dir"
			return 0
		fi
	done
	return 1
}

mod_install() {
	if [[ ${BC250_FAN_CONTROL:-0} != 1 ]]; then
		log_info "fan control not requested by this profile"
		mod_uninstall
		return 0
	fi

	# Bazzite ships the akmod; only layer it if the module is genuinely absent.
	if ! modinfo "$FAN_MODULE" >/dev/null 2>&1; then
		log_info "$FAN_MODULE is not available; layering the akmod"
		ostree_pkg_install "akmod-nct6687d"
		if reboot_is_required; then
			log_warn "reboot, then re-run 'bc250ctl install fan-control'"
			return 0
		fi
	fi

	mod_configure
}

mod_configure() {
	[[ ${BC250_FAN_CONTROL:-0} == 1 ]] || return 0

	# Hand the chip over: the read-only driver has to go first.
	if [[ -f "$MODULES_LOAD_DIR/99-bc250-sensors.conf" || -f "$MODPROBE_DIR/99-bc250-sensors.conf" ]]; then
		log_info "removing the read-only nct6683 configuration; the chip cannot have two drivers"
		bc_run rm -f -- "$MODULES_LOAD_DIR/99-bc250-sensors.conf" "$MODPROBE_DIR/99-bc250-sensors.conf"
		bc_run modprobe -r nct6683 2>/dev/null || true
	fi

	write_file "$(_fan_modules_load_file)" 0644 <<-EOC
		# Managed by bc250ctl. Read/write Nuvoton driver, for PWM fan control.
		${FAN_MODULE}
	EOC

	write_file "$(_fan_modprobe_file)" 0644 <<-EOC
		# Managed by bc250ctl. The BC-250's chip is not on the driver's
		# allow-list, so binding has to be forced.
		options ${FAN_MODULE} force=true

		# One driver per chip. Removing the read-only drop-in is not enough:
		# nct6683 is in-tree and would otherwise be free to bind first.
		blacklist nct6683
	EOC

	if ! lsmod 2>/dev/null | grep -q "^${FAN_MODULE}\b"; then
		bc_run modprobe "$FAN_MODULE" force=true ||
			log_warn "could not load $FAN_MODULE now; it will load at the next boot"
	fi

	_fan_install_duty_unit
}

# The driver forgets its PWM settings on every boot, so something has to write
# them back. A fixed duty cycle gets a unit of our own; anything else is left
# to CoolerControl, which manages its own service.
_fan_install_duty_unit() {
	local pwm=${BC250_FAN_PWM:-auto}

	if [[ $pwm == auto ]]; then
		log_info "leaving the fan curve to CoolerControl (set BC250_FAN_PWM for a fixed duty)"
		unit_remove "$FAN_SERVICE"
		return 0
	fi

	unit_install "$FAN_SERVICE" <<-EOC
		[Unit]
		Description=BC-250 fan duty cycle (nct6687 forgets it on every boot)
		After=multi-user.target

		[Service]
		Type=oneshot
		RemainAfterExit=yes
		ExecStart=$(_fan_duty_script_path) ${pwm}

		[Install]
		WantedBy=multi-user.target
	EOC

	_fan_write_duty_script
	unit_enable_now "$FAN_SERVICE"
}

_fan_duty_script_path() { printf '%s\n' "${LOCAL_BIN}/bc250ctl-fan-duty"; }

_fan_write_duty_script() {
	write_file "$(_fan_duty_script_path)" 0755 <<'EOC'
#!/usr/bin/env bash
# Written by bc250ctl. Sets every nct6687 PWM channel to the duty cycle given
# as $1 (0-255), after switching the channel to manual mode.
set -euo pipefail

duty=${1:?usage: bc250ctl-fan-duty <0-255>}
[[ $duty =~ ^[0-9]+$ ]] && (( duty <= 255 )) || { echo "duty must be 0-255" >&2; exit 1; }

found=0
for dir in /sys/class/hwmon/hwmon[0-9]*; do
	[[ -r $dir/name ]] || continue
	read -r name <"$dir/name"
	[[ $name == nct6687 ]] || continue
	found=1
	for pwm in "$dir"/pwm[0-9]*; do
		[[ -w $pwm ]] || continue
		[[ -w ${pwm}_enable ]] && echo 1 >"${pwm}_enable" || true
		echo "$duty" >"$pwm"
	done
done

(( found == 1 )) || { echo "no nct6687 hwmon found" >&2; exit 1; }
EOC
}

mod_verify() {
	if [[ ${BC250_FAN_CONTROL:-0} != 1 ]]; then
		log_ok "fan control not requested"
		return 0
	fi

	if ! lsmod 2>/dev/null | grep -q "^${FAN_MODULE}\b"; then
		log_error "$FAN_MODULE is not loaded"
		return 1
	fi
	log_ok "$FAN_MODULE loaded"

	local hwmon
	if ! hwmon=$(_fan_hwmon); then
		log_error "$FAN_MODULE is loaded but did not bind to the chip"
		return 1
	fi
	log_ok "bound to $(basename "$hwmon")"

	if [[ ${BC250_FAN_PWM:-auto} != auto ]]; then
		unit_exists "$FAN_SERVICE" || {
			log_error "$FAN_SERVICE is missing: the duty cycle will not survive a reboot"
			return 1
		}
		log_ok "duty cycle ${BC250_FAN_PWM} reapplied at boot"
	fi
}

mod_uninstall() {
	unit_remove "$FAN_SERVICE"
	[[ -f $(_fan_duty_script_path) ]] && bc_run rm -f -- "$(_fan_duty_script_path)"
	local f
	for f in "$(_fan_modules_load_file)" "$(_fan_modprobe_file)"; do
		[[ -f $f ]] && bc_run rm -f -- "$f"
	done
	bc_run modprobe -r "$FAN_MODULE" 2>/dev/null || true
	log_info "re-run 'bc250ctl install sensors' to get temperatures back"
	return 0
}
