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
	: >"$MOCK_STATE/unit-files"
	# Bazzite ships the fan akmod, so the module is normally already there.
	printf 'nct6687\n' >"$MOCK_STATE/modules-available"

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

	# Stand-ins for the two .aml tables, with their real checksums.
	local aml="$BATS_TEST_TMPDIR/aml"
	mkdir -p "$aml"
	printf 'SSDT-CST fixture\n' >"$aml/SSDT-CST.aml"
	printf 'SSDT-PST fixture\n' >"$aml/SSDT-PST.aml"
	local cst_sum pst_sum
	cst_sum=$(sha256sum -- "$aml/SSDT-CST.aml" | cut -d' ' -f1)
	pst_sum=$(sha256sum -- "$aml/SSDT-PST.aml" | cut -d' ' -f1)

	export BC250_SOURCES_FILE="$BATS_TEST_TMPDIR/sources.env"
	cat >"$BC250_SOURCES_FILE" <<-EOF
		SRC_CU_LIVE_MANAGER_REPO=file://$REPO_ROOT
		SRC_CU_LIVE_MANAGER_REF=1111111111111111111111111111111111111111
		SRC_CU_LIVE_MANAGER_URL=file://$mock
		SRC_CU_LIVE_MANAGER_SHA256=$sum
		SRC_SMU_OC_REPO=file://$REPO_ROOT
		SRC_SMU_OC_REF=2222222222222222222222222222222222222222
		SRC_SMU_OC_URL=file://$REPO_ROOT
		SRC_ACPI_CST_REPO=file://$REPO_ROOT
		SRC_ACPI_CST_REF=3333333333333333333333333333333333333333
		SRC_ACPI_CST_URL=file://$aml/SSDT-CST.aml
		SRC_ACPI_CST_SHA256=$cst_sum
		SRC_ACPI_PST_REPO=file://$REPO_ROOT
		SRC_ACPI_PST_REF=3333333333333333333333333333333333333333
		SRC_ACPI_PST_URL=file://$aml/SSDT-PST.aml
		SRC_ACPI_PST_SHA256=$pst_sum
	EOF
}

# acpi_tables_loaded — make cpupower report healthy idle states, i.e. the
# rebuilt tables are in effect.
acpi_tables_loaded() {
	local i
	: >"$MOCK_STATE/cpupower-idle"
	for i in $(seq 0 15); do
		printf 'analyzing CPU %d:\nNumber of idle states: 4\n' "$i" >>"$MOCK_STATE/cpupower-idle"
	done
	printf 'available frequency steps: 3.20 GHz, 800 MHz\n' >"$MOCK_STATE/cpupower-freq"
}

# unit_known <name> — make systemctl list-unit-files report a unit exists.
unit_known() { printf '%s enabled\n' "$1" >>"$MOCK_STATE/unit-files"; }

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

	# Read the library list out of bc250ctl itself rather than repeating it:
	# a library added there must not silently go untested here.
	local libs l
	libs=$(sed -n 's/^for _lib in \(.*\); do$/\1/p' "$REPO_ROOT/bc250ctl")
	[[ -n $libs ]] || { echo "could not read the library list from bc250ctl" >&2; return 1; }

	for l in $libs; do
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

# fake_hwmon <driver> <file> <value> — a sysfs hwmon node the telemetry reads.
fake_hwmon() {
	local driver=$1 file=$2 value=$3
	local base="$BC250_PREFIX/sys/class/hwmon"
	local dir n=0
	# Reuse the directory already claimed by this driver, if any.
	for dir in "$base"/hwmon[0-9]*; do
		[[ -r $dir/name ]] || continue
		[[ $(<"$dir/name") == "$driver" ]] && { echo "$value" >"$dir/$file"; return 0; }
		n=$(( n + 1 ))
	done
	dir="$base/hwmon$n"
	mkdir -p "$dir"
	echo "$driver" >"$dir/name"
	echo "$value" >"$dir/$file"
}

# fake_kernel <release> — what `uname -r` reports, for the version guards.
fake_kernel() { printf '%s\n' "$1" >"$MOCK_STATE/uname-r"; }

# fake_swap — make /proc/swaps show an active swap device.
fake_swap() {
	printf 'Filename\t\t\t\tType\t\tSize\tUsed\tPriority\n' >"$BC250_PREFIX/proc/swaps"
	printf '/swapfile\t\t\t\tfile\t\t16777212\t0\t-2\n' >>"$BC250_PREFIX/proc/swaps"
}

# no_swap — an empty swap table, which is what disabling zram can leave.
no_swap() {
	printf 'Filename\t\t\t\tType\t\tSize\tUsed\tPriority\n' >"$BC250_PREFIX/proc/swaps"
}
