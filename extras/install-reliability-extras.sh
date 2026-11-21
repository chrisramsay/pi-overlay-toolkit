#!/bin/bash
# install-reliability-extras.sh
#
# Optional add-ons for an unattended Pi that sometimes hangs or drops off
# WiFi and needs a manual power cycle:
#
#   1. wifi-check: /usr/local/sbin/wifi-check.sh run every 5 minutes by a
#      systemd timer. Cycles WiFi if the gateway is unreachable, and reboots
#      if that doesn't fix it (with a minimum-uptime guard against loops).
#      Settings in /etc/default/wifi-check (never overwritten).
#   2. Hardware watchdog: dtparam=watchdog=on in config.txt, plus a systemd
#      drop-in (/etc/systemd/system.conf.d/10-pi-watchdog.conf), so a full
#      hang resets the board. No manual editing of system.conf needed.
#      Skipped on Raspberry Pi OS images that already ship
#      40-rpi-enable-watchdog.conf (Trixie onwards), which enables it.
#
# Host-agnostic. Run with the overlay OFF so the changes persist:
#   overlay-off
#   sudo bash extras/install-reliability-extras.sh            install
#   sudo bash extras/install-reliability-extras.sh --uninstall
#   sudo reboot      # watchdog settings take effect at boot
#   overlay-on

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=overlay-common.sh
. "$SCRIPT_DIR/../overlay-common.sh"

if [ "$(id -u)" -ne 0 ]; then
    exec sudo -- bash "$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")" "$@"
fi

HOST=$(hostname)
DROPIN_DIR=/etc/systemd/system.conf.d
DROPIN=$DROPIN_DIR/10-pi-watchdog.conf
# Shipped by Raspberry Pi OS (Trixie onwards); when present, the OS already
# runs the watchdog and our drop-in is not needed.
RPI_WATCHDOG=/usr/lib/systemd/system.conf.d/40-rpi-enable-watchdog.conf

if pot_overlay_live; then
    echo "ERROR: $HOST: OverlayFS is ON, so these changes would be lost at"
    echo "the next reboot. Run 'overlay-off' first."
    exit 1
fi

CONFIG_TXT=$(pot_config_txt) || {
    echo "ERROR: $HOST: can't find config.txt under /boot/firmware or /boot."
    exit 1
}

# The first version of the extras used cron and /usr/local/bin.
remove_legacy() {
    rm -f /etc/cron.d/wifi-check /usr/local/bin/wifi-check.sh
}

if [ "${1:-}" = "--uninstall" ]; then
    echo "$HOST: removing reliability extras ..."
    systemctl disable --now wifi-check.timer 2>/dev/null || true
    rm -f /etc/systemd/system/wifi-check.service /etc/systemd/system/wifi-check.timer \
          /usr/local/sbin/wifi-check.sh "$DROPIN"
    remove_legacy
    systemctl daemon-reload
    echo "  Left in place: /etc/default/wifi-check (your settings) and"
    echo "  'dtparam=watchdog=on' in $CONFIG_TXT (harmless without the drop-in)."
    sync
    echo "$HOST: removed. Reboot to stop systemd using the watchdog."
    exit 0
fi

echo "$HOST: installing wifi-check ..."
install -m 755 "$SCRIPT_DIR/wifi-check.sh" /usr/local/sbin/wifi-check.sh
install -m 644 "$SCRIPT_DIR/wifi-check.service" /etc/systemd/system/wifi-check.service
install -m 644 "$SCRIPT_DIR/wifi-check.timer"   /etc/systemd/system/wifi-check.timer
if [ ! -e /etc/default/wifi-check ]; then
    install -m 644 "$SCRIPT_DIR/wifi-check.default" /etc/default/wifi-check
else
    echo "  /etc/default/wifi-check exists, leaving your settings alone"
fi
remove_legacy
systemctl daemon-reload
systemctl enable --now wifi-check.timer

echo "$HOST: hardware watchdog ..."
if [ -e "${POT_FAKEROOT:-}$RPI_WATCHDOG" ]; then
    # Raspberry Pi OS (Trixie onwards) enables the watchdog itself. Its
    # 40-rpi-enable-watchdog.conf sorts after our 10-pi-watchdog.conf, so ours
    # would be silently overridden anyway. Leave the OS setting in charge.
    echo "  already enabled by Raspberry Pi OS ($RPI_WATCHDOG), leaving it alone"
    if [ -e "$DROPIN" ]; then
        rm -f "$DROPIN"
        echo "  removed redundant $DROPIN from an earlier install"
    fi
    EXPECT="the OS value (1min on Trixie)"
else
    if grep -q '^dtparam=watchdog=on' "$CONFIG_TXT"; then
        echo "  dtparam=watchdog=on already in $CONFIG_TXT"
    else
        echo "dtparam=watchdog=on" >> "$CONFIG_TXT"
        echo "  added dtparam=watchdog=on to $CONFIG_TXT"
    fi
    install -d -m 755 "$DROPIN_DIR"
    install -m 644 "$SCRIPT_DIR/watchdog.conf" "$DROPIN"
    echo "  installed $DROPIN"
    EXPECT="15s"
fi

sync

echo ""
echo "$HOST: done. Reboot for the watchdog to take effect, then check:"
echo "  systemctl show -p RuntimeWatchdogUSec   # expect $EXPECT"
echo "  ls -l /dev/watchdog*"
echo "  systemctl list-timers wifi-check.timer"
echo "  journalctl -t wifi-check                # only logs when it acts"
echo ""
echo "Then: overlay-on"
