# shellcheck shell=bash
#
# Shared test setup.
#
# Each test gets a throwaway sandbox: BC250_PREFIX redirects every system path
# the tool writes to, and tests/mocks shadows the commands it shells out to.
# The code under test is the real code — nothing is stubbed inside bc250ctl.

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

sandbox_setup() {
	export BC250_PREFIX="$BATS_TEST_TMPDIR/root"
	export MOCK_STATE="$BATS_TEST_TMPDIR/mock"

	mkdir -p \
		"$BC250_PREFIX/etc/systemd/system" \
		"$BC250_PREFIX/etc/modprobe.d" \
		"$BC250_PREFIX/etc/modules-load.d" \
		"$BC250_PREFIX/etc/yum.repos.d" \
		"$BC250_PREFIX/usr/local/bin" \
		"$BC250_PREFIX/var/lib/bc250ctl" \
		"$BC250_PREFIX/proc" \
		"$MOCK_STATE/bin"

	: >"$MOCK_STATE/calls"
	: >"$MOCK_STATE/rpm-installed"
	: >"$MOCK_STATE/lsmod"

	# umr is discovered through PATH; tests decide whether it is there.
	export PATH="$MOCK_STATE/bin:$REPO_ROOT/tests/mocks:$PATH"

	export BC250_ASSUME_YES=1
	unset BC250_DRY_RUN BC250_VERBOSE BC250_FORCE || true

	fake_sources
}

# fake_sources — point the pinned-source table at local fixtures.
#
# The fetch and checksum code under test is the real one; only the URLs are
# local, so the suite never touches the network and the mock live manager is
# what ends up installed.
fake_sources() {
	local mock="$REPO_ROOT/tests/mocks/bc250-cu-live-manager"
	local sum
	sum=$(sha256sum -- "$mock" | cut -d' ' -f1)

	export BC250_SOURCES_FILE="$BATS_TEST_TMPDIR/sources.env"
	cat >"$BC250_SOURCES_FILE" <<-EOF
		SRC_CU_LIVE_MANAGER_REPO=file://$REPO_ROOT
		SRC_CU_LIVE_MANAGER_REF=1111111111111111111111111111111111111111
		SRC_CU_LIVE_MANAGER_URL=file://$mock
		SRC_CU_LIVE_MANAGER_SHA256=$sum
		SRC_SMU_OC_REPO=file://$REPO_ROOT
		SRC_SMU_OC_REF=2222222222222222222222222222222222222222
		SRC_SMU_OC_URL=file://$REPO_ROOT
	EOF
}

# fake_bc250 — a sysfs tree that looks like a BC-250 with 6 cores.
fake_bc250() {
	local pci=${1:-0000:01:00.0} threads=${2:-12}
	local dev="$BC250_PREFIX/sys/bus/pci/devices/$pci"
	mkdir -p "$dev" "$BC250_PREFIX/sys/class/drm"
	echo '0x1002' >"$dev/vendor"
	echo '0x13fe' >"$dev/device"

	# card1, deliberately not card0: the governor's most common misdiagnosis.
	mkdir -p "$BC250_PREFIX/sys/class/drm/card1"
	ln -sfn "$dev" "$BC250_PREFIX/sys/class/drm/card1/device"
	printf 'name\n0: 500Mhz\n1: 1500Mhz *\n' >"$dev/pp_dpm_sclk"

	local i
	: >"$BC250_PREFIX/proc/cpuinfo"
	for (( i = 0; i < threads; i++ )); do
		printf 'processor\t: %d\n\n' "$i" >>"$BC250_PREFIX/proc/cpuinfo"
	done
}

have_umr()  { printf '#!/bin/sh\nexit 0\n' >"$MOCK_STATE/bin/umr"; chmod +x "$MOCK_STATE/bin/umr"; }
no_umr()    { rm -f "$MOCK_STATE/bin/umr"; }

layered_boot() { echo "$1" >>"$MOCK_STATE/rpm-installed"; }
unit_file()    { printf '[Unit]\nDescription=x\n' >"$BC250_PREFIX/etc/systemd/system/$1"; }

bc250ctl() { "$REPO_ROOT/bc250ctl" "$@"; }

# lib_source — pull the libraries into the current shell to test them directly.
lib_source() {
	export BC250_MODULES_DIR="$REPO_ROOT/modules"
	local l
	for l in log core state systemd ostree download hw livemgr; do
		# shellcheck source=/dev/null
		source "$REPO_ROOT/lib/$l.sh"
	done
	# shellcheck source=/dev/null
	source "${BC250_SOURCES_FILE:-$REPO_ROOT/sources.env}"
	config_load /dev/null
}

state_file() { cat "$BC250_PREFIX/var/lib/bc250ctl/state" 2>/dev/null || true; }
calls()      { cat "$MOCK_STATE/calls" 2>/dev/null || true; }

# use_profile <name> — put a shipped profile in place as the active config,
# the way `bc250ctl --profile <name>` would.
use_profile() {
	install -D -m 0600 "$REPO_ROOT/profiles/$1.env" \
		"$BC250_PREFIX/etc/bc250ctl/config.env"
}

# write_config — active configuration on stdin, for cases no profile covers.
write_config() {
	install -D -m 0600 /dev/stdin "$BC250_PREFIX/etc/bc250ctl/config.env"
}
