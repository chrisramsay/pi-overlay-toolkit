#!/bin/bash
# /usr/local/sbin/wifi-check.sh
#
# WiFi self-heal, run every few minutes by wifi-check.timer. Pings a target
# (the default gateway unless configured otherwise). If that fails it cycles
# the WiFi interface, and if that doesn't bring the link back it reboots.
#
# Works alongside the hardware watchdog (installed by the same extras):
# the watchdog catches full hangs, this catches a WiFi-only drop.
#
# Settings come from /etc/default/wifi-check (all optional):
#   WIFI_IFACE=wlan0     interface to cycle (default: first wireless one)
#   PING_TARGET=1.2.3.4  host to ping (default: the default gateway)
#   MIN_UPTIME_MIN=30    don't reboot unless up at least this long, so a
#                        router outage can't put every Pi in a reboot loop
#   REBOOT=yes           set to "no" to only cycle the interface
#
# If NetworkManager manages the interface (Bookworm/Trixie default) it is
# cycled through nmcli, so NM reconnects cleanly; otherwise (dhcpcd etc.)
# plain `ip link` is used.

set -u

WIFI_IFACE=""
PING_TARGET=""
MIN_UPTIME_MIN=30
REBOOT=yes
# shellcheck source=/dev/null
[ -r /etc/default/wifi-check ] && . /etc/default/wifi-check

log() { logger -t wifi-check "$*"; }

if [ -z "$WIFI_IFACE" ]; then
    for d in /sys/class/net/*/wireless; do
        [ -d "$d" ] || continue
        WIFI_IFACE=$(basename "$(dirname "$d")")
        break
    done
fi
if [ -z "$WIFI_IFACE" ]; then
    log "no wireless interface found, nothing to do"
    exit 0
fi

# Pick the target BEFORE cycling: once the interface is down its default
# route disappears, so the gateway can't be looked up again until DHCP is back.
target() {
    if [ -n "$PING_TARGET" ]; then
        echo "$PING_TARGET"
    else
        ip route show default dev "$WIFI_IFACE" 2>/dev/null | awk '{ print $3; exit }'
    fi
}

reachable() {
    [ -n "$1" ] && ping -c 3 -W 5 -I "$WIFI_IFACE" "$1" >/dev/null 2>&1
}

TARGET=$(target)
reachable "$TARGET" && exit 0

log "${TARGET:-default gateway (no route)} unreachable via $WIFI_IFACE, cycling interface"
nm_managed() {
    command -v nmcli >/dev/null 2>&1 \
        && systemctl -q is-active NetworkManager 2>/dev/null \
        && ! nmcli -g GENERAL.STATE device show "$WIFI_IFACE" 2>/dev/null | grep -q unmanaged
}

if nm_managed; then
    nmcli device disconnect "$WIFI_IFACE" >/dev/null 2>&1
    sleep 3
    nmcli device connect "$WIFI_IFACE" >/dev/null 2>&1 || log "nmcli connect $WIFI_IFACE failed"
else
    ip link set "$WIFI_IFACE" down
    sleep 3
    ip link set "$WIFI_IFACE" up
fi
sleep 30

# If there was no route before, try to find one now.
[ -n "$TARGET" ] || TARGET=$(target)
if reachable "$TARGET"; then
    log "recovered after cycling $WIFI_IFACE"
    exit 0
fi

UPTIME_MIN=$(awk '{ print int($1 / 60) }' /proc/uptime)
if [ "$REBOOT" != yes ]; then
    log "still down after cycling $WIFI_IFACE; REBOOT=$REBOOT so not rebooting"
elif [ "$UPTIME_MIN" -lt "$MIN_UPTIME_MIN" ]; then
    log "still down, but only up ${UPTIME_MIN} min (< ${MIN_UPTIME_MIN}); not rebooting yet"
else
    log "still down after cycling $WIFI_IFACE, rebooting"
    sync
    systemctl reboot
fi
