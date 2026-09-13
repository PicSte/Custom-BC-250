# shellcheck shell=bash
#
# Serialising access to the SMU.
#
# The GPU governor and the CPU core/overclock tools all reach the SMU through
# the same PCI config index/data window — registers 0xB8/0xBC on device
# 00:00.0. There is no arbitration: if the governor writes an index while
# another tool is mid-transaction, both end up reading and writing the wrong
# SMN addresses.
#
# So any SMU write has to happen with the governor stopped. smu_critical does
# that and puts it back, including when the command fails.

SMU_GOVERNOR_SERVICE='cyan-skillfish-governor-smu.service'

# smu_critical <command> [args...]
smu_critical() {
	local restore=0 rc=0

	if unit_is_active "$SMU_GOVERNOR_SERVICE"; then
		log_info "pausing the GPU governor: it shares the SMU mailbox with this write"
		restore=1
		bc_run systemctl stop "$SMU_GOVERNOR_SERVICE" ||
			die "could not stop $SMU_GOVERNOR_SERVICE; refusing to write to the SMU with it running"
	else
		log_debug "governor is not running; no need to pause it"
	fi

	# The governor has to come back whatever happens next, including a
	# failure or an interrupt part-way through the command.
	_smu_restore() {
		(( restore == 1 )) || return 0
		restore=0
		log_info "resuming the GPU governor"
		bc_run systemctl start "$SMU_GOVERNOR_SERVICE" ||
			log_warn "could not restart $SMU_GOVERNOR_SERVICE — start it by hand"
	}
	trap '_smu_restore' RETURN INT TERM

	"$@" || rc=$?

	_smu_restore
	trap - RETURN INT TERM

	return "$rc"
}
