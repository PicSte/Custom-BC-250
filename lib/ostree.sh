# shellcheck shell=bash
#
# rpm-ostree helpers for Bazzite / Fedora Atomic.
#
# Two things shape everything here: /usr is read-only, and package layering
# plus kernel arguments only take effect after a reboot. Rather than parse
# `rpm-ostree status` to guess whether a reboot is owed, we record it in our
# own state whenever we queue something that needs one.

ostree_is_atomic() { [[ -x ${BC250_PREFIX}/usr/bin/rpm-ostree ]] || command -v rpm-ostree >/dev/null 2>&1; }

ostree_require_atomic() {
	ostree_is_atomic ||
		die "this tool targets Bazzite / Fedora Atomic and needs rpm-ostree." \
		    "See docs/troubleshooting.md if you are on a different distribution."
}

reboot_mark_required() { state_set reboot.required 1; }
reboot_is_required()   { [[ $(state_get reboot.required 0) == 1 ]]; }
reboot_clear()         { state_del reboot.required; }

# ------------------------------------------------------------- packages ---

ostree_pkg_installed() { rpm -q "$1" >/dev/null 2>&1; }

# ostree_pkg_layered <pkg> — already layered, possibly only in the pending
# deployment (so installed-but-not-yet-booted counts).
ostree_pkg_layered() {
	ostree_pkg_installed "$1" && return 0
	rpm-ostree status 2>/dev/null | grep -q "\b$1\b"
}

# ostree_pkg_install <pkg>... — layers anything not already there.
#
# Returns 0 and marks a reboot as required when it actually layered something;
# returns 0 without marking when everything was already present.
ostree_pkg_install() {
	local pkg missing=()
	for pkg in "$@"; do
		ostree_pkg_layered "$pkg" || missing+=("$pkg")
	done

	if (( ${#missing[@]} == 0 )); then
		log_debug "already layered: $*"
		return 0
	fi

	log_info "layering: ${missing[*]}"
	bc_run rpm-ostree install --idempotent --allow-inactive "${missing[@]}" ||
		die "rpm-ostree install failed for: ${missing[*]}"
	reboot_mark_required
}

ostree_pkg_remove() {
	local pkg present=()
	for pkg in "$@"; do
		ostree_pkg_layered "$pkg" && present+=("$pkg")
	done
	(( ${#present[@]} == 0 )) && return 0

	bc_run rpm-ostree uninstall "${present[@]}" || return 1
	reboot_mark_required
}

# --------------------------------------------------------- kernel args ---

ostree_karg_present() {
	rpm-ostree kargs 2>/dev/null | tr ' ' '\n' | grep -qx -- "$1"
}

ostree_karg_add() {
	local karg
	for karg in "$@"; do
		if ostree_karg_present "$karg"; then
			log_debug "karg already set: $karg"
			continue
		fi
		log_info "adding kernel argument: $karg"
		bc_run rpm-ostree kargs --append-if-missing="$karg" ||
			die "failed to add kernel argument: $karg"
		reboot_mark_required
	done
}

ostree_karg_remove() {
	local karg
	for karg in "$@"; do
		ostree_karg_present "$karg" || continue
		log_info "removing kernel argument: $karg"
		bc_run rpm-ostree kargs --delete-if-present="$karg" || continue
		reboot_mark_required
	done
}

# ostree_karg_remove_key <key>
#
# Removes whatever value a key currently holds. ostree_karg_remove needs the
# exact string, which is no use for an argument whose value is configurable.
ostree_karg_remove_key() {
	local key=$1 karg
	while IFS= read -r karg; do
		[[ $karg == "$key="* ]] || continue
		log_info "removing kernel argument: $karg"
		bc_run rpm-ostree kargs --delete-if-present="$karg" || continue
		reboot_mark_required
	done < <(rpm-ostree kargs 2>/dev/null | tr ' ' '\n')
}

# ------------------------------------------------------------------ copr ---

# copr_enable <owner> <project>
#
# Writes the .repo file directly instead of shelling out to `dnf copr enable`,
# which is not reliably present on an atomic image. /etc is writable, so the
# repo survives updates. GPG checking stays on, against the project's own key.
copr_enable() {
	local owner=$1 project=$2
	local file="$YUM_REPOS_DIR/_copr:copr.fedorainfracloud.org:${owner}:${project}.repo"

	if [[ -f $file ]]; then
		log_debug "copr ${owner}/${project} already enabled"
		return 0
	fi

	log_info "enabling COPR ${owner}/${project}"
	write_file "$file" 0644 <<-EOR
		[copr:copr.fedorainfracloud.org:${owner}:${project}]
		name=Copr repo for ${project} owned by ${owner}
		baseurl=https://download.copr.fedorainfracloud.org/results/${owner}/${project}/fedora-\$releasever-\$basearch/
		type=rpm-md
		skip_if_unavailable=True
		gpgcheck=1
		gpgkey=https://download.copr.fedorainfracloud.org/results/${owner}/${project}/pubkey.gpg
		repo_gpgcheck=0
		enabled=1
		enabled_metadata=1
	EOR
}

copr_disable() {
	local owner=$1 project=$2
	local file="$YUM_REPOS_DIR/_copr:copr.fedorainfracloud.org:${owner}:${project}.repo"
	[[ -f $file ]] && bc_run rm -f -- "$file"
	return 0
}
