#!/usr/bin/env bash
#
# Installs bc250ctl into /usr/local, which is a symlink to /var/usrlocal on
# Fedora Atomic and therefore writable — unlike /usr itself.

set -euo pipefail

PREFIX=${PREFIX:-/usr/local}
LIBDIR="$PREFIX/lib/bc250ctl"
BINDIR="$PREFIX/bin"

SRC=$(cd -- "$(dirname -- "$(readlink -f -- "$0")")" && pwd)

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
	echo "run as root: sudo ./install.sh" >&2
	exit 1
fi

echo "installing bc250ctl to $LIBDIR"
install -d -m 0755 "$LIBDIR" "$BINDIR"

rm -rf -- "${LIBDIR:?}/lib" "${LIBDIR:?}/modules" "${LIBDIR:?}/profiles"
cp -r -- "$SRC/lib" "$SRC/modules" "$SRC/profiles" "$LIBDIR/"
install -m 0755 -- "$SRC/bc250ctl" "$LIBDIR/bc250ctl"
install -m 0644 -- "$SRC/sources.env" "$LIBDIR/sources.env"

ln -sf -- "$LIBDIR/bc250ctl" "$BINDIR/bc250ctl"

echo
echo "installed. Next:"
echo "  sudo bc250ctl doctor"
echo "  sudo bc250ctl bootstrap --profile safe"
