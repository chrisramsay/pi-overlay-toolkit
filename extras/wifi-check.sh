#!/bin/bash
# /usr/local/bin/wifi-check.sh
#
# Pings the default gateway; if unreachable, cycles wlan0, and if that
# doesn't recover it, reboots. Intended to run every few minutes via cron
# so a WiFi-only drop (as opposed to a full system hang, which the
# systemd hardware watchdog handles) doesn't require a manual power cycle.
#
# Uses `ip link` rather than nmcli/wpa_cli so it works regardless of which
# network stack (NetworkManager, dhcpcd, etc.) a given Pi is running.

GATEWAY=$(ip route | awk '/default/ {print $3; exit}')
if ! ping -c 3 -W 5 "$GATEWAY" >/dev/null 2>&1; then
    logger "wifi-check: gateway unreachable, cycling wlan0"
    ip link set wlan0 down
    sleep 3
    ip link set wlan0 up
    sleep 30
    if ! ping -c 3 -W 5 "$GATEWAY" >/dev/null 2>&1; then
        logger "wifi-check: still down after wlan0 cycle, rebooting"
        systemctl reboot
    fi
fi
