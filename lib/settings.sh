# shellcheck shell=bash
#
# The settings schema.
#
# One row per BC250_* key, in the order a person would want to see them. This
# is the single description of what a setting is: config_validate reads the
# types and ranges from here instead of repeating them, `bc250ctl config
# --json` publishes it, and the GUI generates its form from that. A key added
# here shows up in the interface with the right widget and no UI change.
#
# Fields, separated by '|' (which therefore may not appear in any of them):
#
#   key | type | constraint | default | module | label | unit | help
#
# Types:
#   bool     0 or 1
#   int      a whole number inside constraint "min-max"
#   int0     zero (meaning "off"), or a whole number inside "min-max"
#   intauto  the word "auto", or a whole number inside "min-max"
#   choice   one of the comma-separated values in constraint
#   text     free text; the module validates what it means
#
# Cross-field rules — a frequency without a voltage cap, two drivers claiming
# the same chip, eight cores without the ACPI tables — are not expressible as
# a table and stay written out in config_validate.

# Hard safety ceilings, in millivolts. The rows below build their ranges from
# these, so there is one place to change them.
#
# CPU core voltage: 1325 mV is the absolute limit documented by bc250_smu_oc
# (bc250_limits.py); above it you damage the SoC. 1275 mV is the ceiling this
# tool applies on its own, leaving the last 50 mV behind an explicit opt-in.
readonly VID_ABSOLUTE_MAX=1325
readonly VID_SAFE_MAX=1275
readonly VID_MIN=950
readonly FREQ_MIN=3500
readonly FREQ_MAX=4500

# GPU voltage is a different budget with much lower limits: the BC-250
# documentation puts general use at 1100 mV and calls 1150 mV the absolute
# maximum. Same two-tier treatment as the CPU, because the consequence of
# getting it wrong is the same.
readonly GPU_VOLT_ABSOLUTE_MAX=1150
readonly GPU_VOLT_SAFE_MAX=1100
readonly GPU_VOLT_MIN=600

BC250_SETTINGS=(
	"BC250_PROFILE|choice|safe,balanced,max|safe|core|Profil|:|Jeu de réglages de départ"

	"BC250_ACPI|bool||1|15-acpi|Tables ACPI reconstruites|:|C-states pour 16 threads et P-states. Obligatoire à 8 cœurs"
	"BC250_CPU_GOVERNOR|choice|none,schedutil,performance,powersave,ondemand,conservative|schedutil|15-acpi|Governor CPU|:|Sans les tables ACPI il n'y a pas de cpufreq du tout. none laisse le réglage du système"
	"BC250_KARGS_TTM|bool||1|10-kargs|Limites mémoire TTM|:|Sans elles les grosses allocations GPU échouent"
	"BC250_TTM_PAGES_LIMIT|int|1000000-8000000|3959290|10-kargs|Plafond de pages TTM|pages|3959290 par défaut ; 3014656 convient mieux à un split VRAM de 512 Mo"
	"BC250_KARGS_ZSWAP|bool||0|10-kargs|Activer zswap|:|Compression en RAM adossée au swap disque, à la place de ZRAM"
	"BC250_KARGS_MITIGATIONS_OFF|bool||0|10-kargs|Désactiver les mitigations CPU|:|Gain de performance contre les protections canaux auxiliaires"
	"BC250_KARGS_DP_FORCE|bool||0|10-kargs|Forcer la sortie DisplayPort|:|Pour un démarrage où l'écran n'est pas détecté"

	"BC250_SENSORS|bool||1|20-sensors|Capteurs de température|:|Pilote nct6683, lecture seule. Exclusif avec le pilotage des ventilateurs"
	"BC250_FAN_CONTROL|bool||0|25-fan-control|Pilotage des ventilateurs|:|Pilote nct6687 avec PWM. Remplace les capteurs en lecture seule"
	"BC250_FAN_PWM|intauto|0-255|auto|25-fan-control|Consigne de ventilation|/255|auto laisse la courbe à CoolerControl"

	"BC250_GOV_FREQ_MIN|int|200-2000|1000|30-governor|Fréquence GPU minimale|MHz|"
	"BC250_GOV_FREQ_MAX|int|200-2000|1500|30-governor|Fréquence GPU maximale|MHz|1500 MHz tient 83 °C et 125 W"
	"BC250_GOV_VOLT_MIN|int|${GPU_VOLT_MIN}-${GPU_VOLT_ABSOLUTE_MAX}|900|30-governor|Tension GPU minimale|mV|"
	"BC250_GOV_VOLT_MAX|int|${GPU_VOLT_MIN}-${GPU_VOLT_ABSOLUTE_MAX}|900|30-governor|Tension GPU maximale|mV|Au-delà de ${GPU_VOLT_SAFE_MAX} mV il faut lever le verrou. ${GPU_VOLT_ABSOLUTE_MAX} mV est le maximum absolu"
	"BC250_ALLOW_EXTREME_GPU_VOLT|bool||0|30-governor|Lever le plafond de ${GPU_VOLT_SAFE_MAX} mV (GPU)|:|Au-dessus, la carte plante sous charge plutôt que de tenir"

	"BC250_GPU_WGP_LAYOUT|text||stock|40-gpu-cu|Routage des WGP|:|all pour 40 CU, stock pour le routage usine, ou une liste SE.SH.WGP à laisser désactivée"
	"BC250_RADV_UNIFIED_HEAP|bool||1|35-radv|Tas mémoire unifié RADV|:|Adapte RADV à la mémoire partagée CPU/GPU de cette carte"

	"BC250_CPU_CORES|choice|6,8|6|50-cpu-cores|Cœurs CPU|:|8 exige les tables ACPI. Une coupure d'alimentation remet 6"

	"BC250_CPU_OC_FREQ|int0|${FREQ_MIN}-${FREQ_MAX}|0|60-cpu-oc|Fréquence CPU cible|MHz|0 désactive l'overclock"
	"BC250_CPU_OC_VID|int0|${VID_MIN}-${VID_ABSOLUTE_MAX}|0|60-cpu-oc|Plafond de tension CPU|mV|Au-delà de 1275 mV il faut lever le verrou. 1325 mV détruit le SoC"
	"BC250_CPU_OC_TEMP|int|60-100|90|60-cpu-oc|Température maximale pendant la calibration|°C|"
	"BC250_ALLOW_EXTREME_VID|bool||0|60-cpu-oc|Lever le plafond de 1275 mV|:|À n'activer qu'en sachant ce que ça coûte"

	"BC250_DISABLE_HHD|bool||0|70-fixes|Masquer hhd|:|Micro-saccades de l'interface Deck"
	"BC250_DISABLE_SUSPEND|bool||0|70-fixes|Désactiver la mise en veille|:|s2idle est cassé : la carte ne se réveille pas"
	"BC250_DISABLE_ZRAM|bool||0|70-fixes|Désactiver le swap ZRAM|:|Mis en cause dans des plantages de jeux"
	"BC250_SWAPPINESS|intauto|0-200|auto|70-fixes|Agressivité du swap|:|180 avec zswap, d'après la documentation amont. auto ne touche à rien"
)

# settings_limits_json — the ceilings the interface has to know about, so it
# can stop a slider where the engine would refuse rather than showing a range
# it will reject.
settings_limits_json() {
	printf '{"vid_safe_max": %s, "vid_absolute_max": %s, "vid_min": %s' \
		"$VID_SAFE_MAX" "$VID_ABSOLUTE_MAX" "$VID_MIN"
	printf ', "freq_min": %s, "freq_max": %s' "$FREQ_MIN" "$FREQ_MAX"
	printf ', "gpu_volt_safe_max": %s, "gpu_volt_absolute_max": %s}' \
		"$GPU_VOLT_SAFE_MAX" "$GPU_VOLT_ABSOLUTE_MAX"
}

settings_keys() {
	local row
	for row in "${BC250_SETTINGS[@]}"; do
		printf '%s\n' "${row%%|*}"
	done
}

# settings_row <key> — the raw record, or failure.
settings_row() {
	local row
	for row in "${BC250_SETTINGS[@]}"; do
		[[ ${row%%|*} == "$1" ]] && { printf '%s\n' "$row"; return 0; }
	done
	return 1
}

# settings_field <key> <n> — field n of the record, 1-indexed.
settings_field() {
	local row
	row=$(settings_row "$1") || return 1
	printf '%s\n' "$row" | cut -d'|' -f"$2"
}

settings_type()       { settings_field "$1" 2; }
settings_constraint() { settings_field "$1" 3; }
settings_default()    { settings_field "$1" 4; }
settings_module()     { settings_field "$1" 5; }
settings_label()      { settings_field "$1" 6; }
# A unit of ':' means "no unit"; the field cannot be left empty in a cut-based
# record without becoming ambiguous.
settings_unit()       { local u; u=$(settings_field "$1" 7); [[ $u == ':' ]] || printf '%s\n' "$u"; }
settings_help()       { settings_field "$1" 8; }

# settings_check_type <key> <value>
#
# Type only: is this the right shape? Range comes separately so that the
# settings with their own message — the CPU voltage caps — can be checked in
# between, and still say what they need to say.
settings_check_type() {
	local key=$1 value=$2 type
	type=$(settings_type "$key") || return 0

	case $type in
		bool)
			[[ $value == 0 || $value == 1 ]] ||
				die "$key must be 0 or 1, got '$value'" ;;
		int)
			[[ $value =~ ^[0-9]+$ ]] ||
				die "$key must be a whole number, got '$value'" ;;
		int0)
			[[ $value =~ ^[0-9]+$ ]] ||
				die "$key must be a whole number, got '$value'" ;;
		intauto)
			[[ $value == auto || $value =~ ^[0-9]+$ ]] ||
				die "$key must be 'auto' or a whole number, got '$value'" ;;
		choice)
			local choice found=0 IFS=','
			for choice in $(settings_constraint "$key"); do
				[[ $value == "$choice" ]] && { found=1; break; }
			done
			(( found )) ||
				die "$key must be one of $(settings_constraint "$key" | tr ',' ' '), got '$value'" ;;
		text) : ;;
	esac
}

# settings_check_range <key> <value>
settings_check_range() {
	local key=$1 value=$2 type constraint lo hi
	type=$(settings_type "$key") || return 0
	constraint=$(settings_constraint "$key")
	[[ -n $constraint ]] || return 0

	case $type in
		int|int0|intauto) ;;
		*) return 0 ;;
	esac

	# The values these types use to mean "off" sit outside the range on purpose.
	[[ $type == int0 && $value == 0 ]] && return 0
	[[ $type == intauto && $value == auto ]] && return 0

	lo=${constraint%%-*}
	hi=${constraint##*-}
	(( value >= lo && value <= hi )) ||
		die "$key must be between $lo and $hi, got $value"
}

# settings_json — the schema as a JSON array, for `bc250ctl config --json`.
settings_json() {
	local key first=1 type constraint
	printf '['
	for key in $(settings_keys); do
		(( first )) || printf ','
		first=0
		type=$(settings_type "$key")
		constraint=$(settings_constraint "$key")

		printf '{"key": %s, "type": %s, "default": %s, "module": %s, "label": %s, "unit": %s, "help": %s' \
			"$(json_str "$key")" \
			"$(json_str "$type")" \
			"$(json_str "$(settings_default "$key")")" \
			"$(json_str "$(settings_module "$key")")" \
			"$(json_str "$(settings_label "$key")")" \
			"$(json_str "$(settings_unit "$key")")" \
			"$(json_str "$(settings_help "$key")")"

		case $type in
			choice)
				printf ', "choices": %s' "$(json_split_list "$constraint")" ;;
			int|int0|intauto)
				printf ', "min": %s, "max": %s' \
					"$(json_num "${constraint%%-*}")" "$(json_num "${constraint##*-}")" ;;
		esac
		printf '}'
	done
	printf ']'
}
