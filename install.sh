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

# --- the graphical front-end ------------------------------------------------
#
# Installed whether or not the toolkit is present: the launcher checks for
# itself and explains what to layer, which is friendlier than leaving the
# desktop entry out and having nothing to click.
echo "installing bc250-gui"
rm -rf -- "${LIBDIR:?}/gui"
cp -r -- "$SRC/gui" "$LIBDIR/gui"
chmod 0755 -- "$LIBDIR/gui/bc250-gui"
ln -sf -- "$LIBDIR/gui/bc250-gui" "$BINDIR/bc250-gui"

install -d -m 0755 "$PREFIX/share/applications"
install -m 0644 -- "$SRC/gui/data/fr.picste.bc250ctl.desktop" \
	"$PREFIX/share/applications/fr.picste.bc250ctl.desktop"

if command -v update-desktop-database >/dev/null 2>&1; then
	update-desktop-database "$PREFIX/share/applications" 2>/dev/null || true
fi

echo
if "$LIBDIR/gui/bc250-gui" --check-only >/dev/null 2>&1; then
	echo "GTK4, libadwaita et PyGObject sont presents : l'interface est prete."
else
	echo "L'interface a besoin de paquets qui manquent sur ce systeme :"
	echo
	echo "    rpm-ostree install python3-gobject gtk4 libadwaita"
	echo "    systemctl reboot"
fi

echo
echo "installed. Next:"
echo "  sudo bc250ctl doctor"
echo "  sudo bc250ctl bootstrap --profile safe"
echo "  bc250-gui                      (ou BC-250 dans le menu)"
