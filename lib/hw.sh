# shellcheck shell=bash
#
# Hardware detection.
#
# The BC-250 GPU is AMD Cyan Skillfish, PCI 1002:13fe. Everything below reads
# sysfs rather than shelling out to lspci, so it works on a minimal image and
# can be pointed at a fixture directory in the tests.

readonly BC250_PCI_VENDOR='0x1002'
readonly BC250_PCI_DEVICE='0x13fe'

SYSFS_PCI="${BC250_PREFIX}/sys/bus/pci/devices"
SYSFS_DRM="${BC250_PREFIX}/sys/class/drm"

# hw_gpu_pci_addr — prints the PCI address of the BC-250 GPU, e.g. 0000:01:00.0
hw_gpu_pci_addr() {
	local dev vendor device
	for dev in "$SYSFS_PCI"/*; do
		[[ -r $dev/device && -r $dev/vendor ]] || continue
		read -r vendor <"$dev/vendor"
		read -r device <"$dev/device"
		if [[ $vendor == "$BC250_PCI_VENDOR" && $device == "$BC250_PCI_DEVICE" ]]; then
			basename "$dev"
			return 0
		fi
	done
	return 1
}

hw_is_bc250() { hw_gpu_pci_addr >/dev/null 2>&1; }

hw_require_bc250() {
	if hw_is_bc250; then
		return 0
	fi
	[[ ${BC250_FORCE:-0} == 1 ]] || {
		die "no BC-250 GPU found (PCI ${BC250_PCI_VENDOR#0x}:${BC250_PCI_DEVICE#0x})." \
		    "Refusing to write hardware registers. Use --force if you know better."
	}
	log_warn "BC-250 not detected but --force was given"
}

# hw_gpu_card — the DRM card node backing the BC-250, e.g. card1.
#
# Worth resolving rather than assuming card0: the governor silently does
# nothing when it is pointed at the wrong node, which is the single most
# common "the frequency never scales" report.
hw_gpu_card() {
	local addr card target
	addr=$(hw_gpu_pci_addr) || return 1

	for card in "$SYSFS_DRM"/card[0-9]*; do
		[[ -e $card/device ]] || continue
		target=$(readlink -f -- "$card/device" 2>/dev/null) || continue
		if [[ $(basename "$target") == "$addr" ]]; then
			basename "$card"
			return 0
		fi
	done
	return 1
}

# hw_cpu_cores — physical core count, from /proc/cpuinfo core ids.
hw_cpu_cores() {
	local cpuinfo="${BC250_PREFIX}/proc/cpuinfo"
	if [[ -r $cpuinfo ]]; then
		local n
		n=$(grep -c '^processor' -- "$cpuinfo" 2>/dev/null || echo 0)
		# The BC-250 is SMT-enabled: threads are twice the cores.
		printf '%s\n' $(( n / 2 ))
		return 0
	fi
	printf '0\n'
}

hw_has_umr() { command -v umr >/dev/null 2>&1; }
