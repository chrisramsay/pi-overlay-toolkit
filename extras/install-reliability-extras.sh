#!/bin/bash
# install-reliability-extras.sh
#
# Installs the optional watchdog + wifi-check self-heal setup discussed
# alongside the overlay toolkit. NOT yet verified end-to-end on real
# hardware as of this repo's creation — test carefully after installing.
#
# Run this with overlayfs OFF (see ../overlay-off), same as the main
# toolkit's installer, so the changes persist to the SD card.
#
# What this does:
#   1. Installs /usr/local/bin/wifi-check.sh and a cron job that runs it
#      every 5 minutes, to recover from WiFi-only drops.
#   2. Enables the Pi's hardware watchdog via /boot/firmware/config.txt
#      and systemd, to recover from full system hangs.
#
# Usage:
#   overlay-off
#   sudo bash install-reliability-extras.sh
#   # review the watchdog note this script prints, reboot when ready
#   overlay-on

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ROOT_FSTYPE=$(awk '$2 == "/" { print $3; exit }' /proc/mounts)
if [ "$ROOT_FSTYPE" = "overlay" ]; then
    echo "ERROR: OverlayFS is currently ON. Run 'overlay-off' first, or these"
    echo "changes will be lost on the next reboot."
    exit 1
fi

echo "Installing wifi-check.sh to /usr/local/bin ..."
sudo install -m 755 "$SCRIPT_DIR/wifi-check.sh" /usr/local/bin/wifi-check.sh

echo "Installing cron job (every 5 minutes) ..."
echo "*/5 * * * * root /usr/local/bin/wifi-check.sh" | sudo tee /etc/cron.d/wifi-check > /dev/null

echo "Enabling hardware watchdog in /boot/firmware/config.txt ..."
if ! grep -q '^dtparam=watchdog=on' /boot/firmware/config.txt 2>/dev/null; then
    echo "dtparam=watchdog=on" | sudo tee -a /boot/firmware/config.txt > /dev/null
else
    echo "  (already present)"
fi

echo ""
echo "Manual step still required: edit /etc/systemd/system.conf and set:"
echo "  RuntimeWatchdogSec=15"
echo "  RebootWatchdogSec=2min"
echo "(uncomment and/or add these lines, then save)"
echo ""

sync

echo "Done. After editing system.conf as above, reboot and verify:"
echo "  ls -l /dev/watchdog"
echo "  systemctl show -p WatchdogDevice -p RuntimeWatchdogUSec"
echo "  cat /etc/cron.d/wifi-check"
echo ""
echo "Then: overlay-on"
