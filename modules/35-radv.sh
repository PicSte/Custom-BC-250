# shellcheck shell=bash
#
# RADV configuration.
#
# The BC-250 has no dedicated VRAM: CPU and GPU share one pool. RADV assumes
# a discrete card by default, and `radv_enable_unified_heap_on_apu` tells it
# otherwise, which is what stops large allocations being accounted against a
# heap that does not really exist.
#
# Mesa reads /usr/share/drirc.d/*.conf first, then /etc/drirc. The former is
# read-only on an ostree image, so /etc/drirc is the only system-wide place
# for this. That file may already belong to someone else, so this module
# writes it only when it is absent or carries our marker, and says so
# otherwise rather than overwriting a configuration it did not create.

DRIRC_MARKER='Managed by bc250ctl'

_drirc() { printf '%s\n' "${BC250_PREFIX}/etc/drirc"; }

mod_describe()    { printf 'configuration RADV (tas mémoire unifié)\n'; }
mod_requires()    { :; }
mod_conflicts()   { :; }
mod_invalidates() { :; }
mod_stage()       { printf 'runtime\n'; }
mod_unattended()  { return 0; }
mod_risk()        { printf 'none\n'; }
mod_needs_smu()   { return 1; }
mod_upstream()    { :; }

_drirc_is_ours() { [[ -f $(_drirc) ]] && grep -q "$DRIRC_MARKER" -- "$(_drirc)"; }

mod_active() { _drirc_is_ours; }

mod_detect() {
	if [[ ${BC250_RADV_UNIFIED_HEAP:-1} == 1 ]]; then
		mod_active
	else
		! mod_active
	fi
}

mod_status() {
	if [[ ${BC250_RADV_UNIFIED_HEAP:-1} != 1 ]]; then
		printf 'réglage RADV non demandé\n'
		return 0
	fi
	if _drirc_is_ours; then
		printf 'tas unifié activé dans %s\n' "$(_drirc)"
	elif [[ -f $(_drirc) ]]; then
		printf '%s existe et ne vient pas de nous\n' "$(_drirc)"
	else
		printf 'non configuré\n'
	fi
}

mod_install() { mod_configure; }

mod_configure() {
	if [[ ${BC250_RADV_UNIFIED_HEAP:-1} != 1 ]]; then
		log_info "ce profil ne demande pas le réglage RADV"
		mod_uninstall
		return 0
	fi

	if [[ -f $(_drirc) ]] && ! _drirc_is_ours; then
		log_warn "$(_drirc) existe déjà et n'a pas été écrit par bc250ctl." \
		         "Ajoutez-y vous-même l'option radv_enable_unified_heap_on_apu ;" \
		         "il ne sera pas écrasé."
		return 0
	fi

	write_file "$(_drirc)" 0644 <<-EOC
		<!-- ${DRIRC_MARKER}. Supprimez ce fichier pour revenir au comportement
		     par défaut de Mesa. -->
		<driconf>
		    <device>
		        <application name="Default">
		            <option name="radv_enable_unified_heap_on_apu" value="true" />
		        </application>
		    </device>
		</driconf>
	EOC
	log_info "les applications déjà lancées gardent l'ancien réglage jusqu'à leur redémarrage"
}

mod_verify() {
	if [[ ${BC250_RADV_UNIFIED_HEAP:-1} != 1 ]]; then
		log_ok "réglage RADV non demandé"
		return 0
	fi

	if [[ -f $(_drirc) ]] && ! _drirc_is_ours; then
		log_warn "$(_drirc) ne vient pas de bc250ctl ; contenu laissé tel quel"
		grep -q 'radv_enable_unified_heap_on_apu' -- "$(_drirc)" && {
			log_ok "l'option y est quand même présente"
			return 0
		}
		log_error "l'option radv_enable_unified_heap_on_apu est absente"
		return 1
	fi

	if ! _drirc_is_ours; then
		log_error "$(_drirc) est absent"
		return 1
	fi
	log_ok "$(_drirc) en place"

	if command -v vulkaninfo >/dev/null 2>&1; then
		vulkaninfo --summary 2>/dev/null | grep -q 'GFX1013' &&
			log_ok "RADV expose bien le GPU (GFX1013)"
	fi
}

mod_uninstall() {
	# Only ever remove a file we wrote.
	if _drirc_is_ours; then
		bc_run rm -f -- "$(_drirc)"
	elif [[ -f $(_drirc) ]]; then
		log_info "$(_drirc) ne vient pas de nous, il est laissé en place"
	fi
	return 0
}
