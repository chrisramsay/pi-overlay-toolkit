#!/bin/bash
# install-overlay-tools.sh
#
# Installs the overlay toolkit on any Raspberry Pi OS host:
#   /usr/local/lib/pi-overlay-toolkit/overlay-common.sh   shared helpers
#   /usr/local/bin/overlay-switch, overlay-on, overlay-off, overlay-status
#   /etc/update-motd.d/99-overlayfs-status                 login banner
#
# Run it with the overlay OFF, or the files vanish at the next reboot.
# To install on several Pis from your workstation, use deploy.sh instead.
#
#   sudo bash install-overlay-tools.sh               install / upgrade
#   sudo bash install-overlay-tools.sh --uninstall   remove everything

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=overlay-common.sh
. "$SCRIPT_DIR/overlay-common.sh"

if [ "$(id -u)" -ne 0 ]; then
    exec sudo -- bash "$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")" "$@"
fi

LIBDIR=/usr/local/lib/pi-overlay-toolkit
BINDIR=/usr/local/bin
MOTD=/etc/update-motd.d/99-overlayfs-status
HOST=$(hostname)

if pot_overlay_live; then
    echo "ERROR: $HOST: OverlayFS is currently ON, so anything installed now"
    echo "would vanish at the next reboot. Run 'overlay-off' (or"
    echo "'sudo raspi-config nonint disable_overlayfs && sudo reboot') first."
    exit 1
fi

# v1 of this toolkit installed into /usr/local/sbin, which isn't on a
# normal user's PATH on Bookworm. Clear those copies so there's one of each.
remove_legacy() {
    rm -f /usr/local/sbin/overlay-on /usr/local/sbin/overlay-off
}

if [ "${1:-}" = "--uninstall" ]; then
    echo "$HOST: removing overlay toolkit ..."
    rm -f "$BINDIR"/overlay-switch "$BINDIR"/overlay-on "$BINDIR"/overlay-off \
          "$BINDIR"/overlay-status "$MOTD"
    rm -rf "$LIBDIR"
    remove_legacy
    sync
    echo "$HOST: removed. The overlay's current setting is unchanged:"
    echo "  live=$(pot_live_word) configured=$(pot_configured_word)"
    exit 0
fi

echo "$HOST: installing overlay toolkit ..."
install -d -m 755 "$LIBDIR"
install -m 644 "$SCRIPT_DIR/overlay-common.sh" "$LIBDIR/overlay-common.sh"
for f in overlay-switch overlay-on overlay-off overlay-status; do
    install -m 755 "$SCRIPT_DIR/$f" "$BINDIR/$f"
done
install -m 755 "$SCRIPT_DIR/99-overlayfs-status" "$MOTD"
remove_legacy

# Flush now, rather than trusting the next command (usually overlay-on,
# which reboots) to do it in time.
sync

# Verify every file landed byte-for-byte before claiming success.
FAILED=0
check() {
    if ! cmp -s "$1" "$2"; then
        echo "ERROR: $2 doesn't match $1"
        FAILED=1
    fi
}
check "$SCRIPT_DIR/overlay-common.sh" "$LIBDIR/overlay-common.sh"
for f in overlay-switch overlay-on overlay-off overlay-status; do
    check "$SCRIPT_DIR/$f" "$BINDIR/$f"
done
check "$SCRIPT_DIR/99-overlayfs-status" "$MOTD"
if [ "$FAILED" -ne 0 ]; then
    echo "$HOST: install did NOT take. Do not run overlay-on yet."
    exit 1
fi

echo ""
echo "$HOST: done."
"$BINDIR/overlay-status"
echo ""
echo "  overlay-status   show state now and after next boot"
echo "  overlay-off      root becomes writable, reboots"
echo "  overlay-on       protection back on, reboots"
echo ""
echo "When you've finished making changes: overlay-on"
