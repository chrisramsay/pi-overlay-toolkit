#!/bin/bash
# install-overlay-tools.sh
#
# Installs, on the Weather Pi:
#   - /usr/local/sbin/overlay-off  and  overlay-on   (toggle helper scripts)
#   - /etc/update-motd.d/99-overlayfs-status          (login warning banner)
#
# Run this ONCE with overlayfs disabled (see step 1 below), so the files
# actually persist to the SD card.
#
# Usage:
#   1. sudo raspi-config nonint disable_overlayfs && sudo systemctl reboot
#   2. scp this script and the three files it installs onto the Pi, or copy
#      their contents in manually
#   3. sudo bash install-overlay-tools.sh
#   4. sudo raspi-config nonint enable_overlayfs && sudo systemctl reboot

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Ground-truth check via /proc/mounts — raspi-config's own get_overlay_now
# getter reports its answer as printed text, not via exit code, so testing
# its exit status directly is unreliable. Match on root's filesystem TYPE
# (3rd field), not the mount source name: some builds (e.g. trixie) use
# the Debian "overlayroot" package, whose source device is named
# "overlayroot" rather than "overlay".
ROOT_FSTYPE=$(awk '$2 == "/" { print $3; exit }' /proc/mounts)
if [ "$ROOT_FSTYPE" = "overlay" ]; then
    echo "ERROR: OverlayFS is currently ON. Disable it first, or these files"
    echo "will vanish on the next reboot:"
    echo "  overlay-off"
    exit 1
fi

echo "Installing overlay-off / overlay-on to /usr/local/sbin ..."
sudo install -m 755 "$SCRIPT_DIR/overlay-off" /usr/local/sbin/overlay-off
sudo install -m 755 "$SCRIPT_DIR/overlay-on"  /usr/local/sbin/overlay-on

echo "Installing MOTD banner to /etc/update-motd.d ..."
sudo install -m 755 "$SCRIPT_DIR/99-overlayfs-status" /etc/update-motd.d/99-overlayfs-status

# Flush installed files to the SD card now, rather than trusting the next
# command (often 'overlay-on', which reboots) to do it in time. A hang
# during that reboot followed by an unclean power-off can otherwise lose
# writes from the last few seconds — including these files.
sync

# Verify the install actually landed before claiming success.
if ! grep -q ROOT_FSTYPE /etc/update-motd.d/99-overlayfs-status; then
    echo "ERROR: install did not take — /etc/update-motd.d/99-overlayfs-status"
    echo "does not contain the expected content. Do not proceed to overlay-on."
    exit 1
fi

echo ""
echo "Done. From any SSH session you can now run:"
echo "  overlay-off   # disable overlay, root becomes writable, reboots"
echo "  overlay-on    # re-enable overlay, reboots"
echo ""
echo "The banner will show on every SSH login from now on."
echo "Remember to re-enable the overlay when you're finished:"
echo "  overlay-on"
