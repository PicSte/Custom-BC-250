# shellcheck shell=bash
#
# Temperature sensors.
#
# The BC-250 carries a Nuvoton chip that the nct6683 driver refuses to bind to
# unless forced, because the board reports an ID the driver does not have on
# its allow-list. force=true is read-only monitoring: it does not let anything
# write fan or voltage registers.

SENSORS_MODULE='nct6683'
MODULES_LOAD_FILE_NAME='99-bc250-sensors.conf'
MODPROBE_FILE_NAME='99-bc250-sensors.conf'

_sensors_modules_load_file() { printf '%s\n' "$MODULES_LOAD_DIR/$MODULES_LOAD_FILE_NAME"; }
_sensors_modprobe_file()     { printf '%s\n' "$MODPROBE_DIR/$MODPROBE_FILE_NAME"; }

mod_describe()    { printf 'temperature sensors (nct6683 force=true)\n'; }
mod_requires()    { :; }
# The chip takes one driver or the other, never both.
mod_conflicts()   { printf '25-fan-control\n'; }
mod_invalidates() { :; }
mod_stage()       { printf 'pre-reboot\n'; }
mod_unattended()  { return 0; }
mod_risk()        { printf 'none\n'; }
mod_needs_smu()   { return 1; }
mod_upstream()    { :; }

# Active when our modprobe drop-ins are on disk.
mod_active() { [[ -f $(_sensors_modules_load_file) || -f $(_sensors_modprobe_file) ]]; }

mod_detect() {
	[[ ${BC250_SENSORS:-1} == 1 ]] || return 0
	[[ -f $(_sensors_modules_load_file) && -f $(_sensors_modprobe_file) ]]
}

mod_status() {
	if ! mod_detect; then
		printf 'not configured\n'
		return 0
	fi
	if lsmod 2>/dev/null | grep -q "^${SENSORS_MODULE}\b"; then
		printf 'configured, %s loaded\n' "$SENSORS_MODULE"
	else
		printf 'configured, %s not loaded (reboot pending?)\n' "$SENSORS_MODULE"
	fi
}

mod_install() {
	if [[ ${BC250_SENSORS:-1} != 1 ]]; then
		log_info "sensors disabled in this profile"
		return 0
	fi

	write_file "$(_sensors_modules_load_file)" 0644 <<-EOC
		# Managed by bc250ctl. Load the Nuvoton sensor driver at boot.
		${SENSORS_MODULE}
	EOC

	write_file "$(_sensors_modprobe_file)" 0644 <<-EOC
		# Managed by bc250ctl. The BC-250's Nuvoton chip is not on the driver's
		# allow-list, so binding has to be forced. Monitoring only.
		options ${SENSORS_MODULE} force=true
	EOC

	# No reboot needed if it loads now.
	if lsmod 2>/dev/null | grep -q "^${SENSORS_MODULE}\b"; then
		log_debug "$SENSORS_MODULE already loaded"
	else
		bc_run modprobe "$SENSORS_MODULE" force=true ||
			log_warn "could not load $SENSORS_MODULE now; it will be loaded at the next boot"
	fi
}

mod_configure() { mod_install; }

mod_verify() {
	[[ ${BC250_SENSORS:-1} == 1 ]] || { log_ok "sensors not requested"; return 0; }

	if ! lsmod 2>/dev/null | grep -q "^${SENSORS_MODULE}\b"; then
		log_error "$SENSORS_MODULE is not loaded"
		return 1
	fi

	if command -v sensors >/dev/null 2>&1 && sensors 2>/dev/null | grep -qi "nct6\|Core"; then
		log_ok "sensors are reporting"
	else
		log_ok "$SENSORS_MODULE loaded (install lm_sensors and run 'sensors' to read it)"
	fi
}

mod_uninstall() {
	local f
	for f in "$(_sensors_modules_load_file)" "$(_sensors_modprobe_file)"; do
		[[ -f $f ]] && bc_run rm -f -- "$f"
	done
	bc_run modprobe -r "$SENSORS_MODULE" 2>/dev/null || true
	return 0
}
