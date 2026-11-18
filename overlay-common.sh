# shellcheck shell=bash
# /usr/local/lib/pi-overlay-toolkit/overlay-common.sh
#
# Shared helpers for overlay-on, overlay-off, overlay-status and the MOTD
# banner. Sourced, not executed. Host-agnostic: nothing in here knows or
# cares which Pi it is running on.
#
# POT_FAKEROOT is a test hook only: when set, /proc/mounts and /boot/... are
# read from under that directory instead of the real ones. Leave it unset on
# a real Pi.

POT_FAKEROOT="${POT_FAKEROOT:-}"

# Live state: is / mounted as an overlay RIGHT NOW?
#
# Ground truth from /proc/mounts rather than raspi-config's get_overlay_now,
# whose answer is printed as text (0/1) while its exit code is always 0, so
# `get_overlay_now && ...` is wrong. Match the filesystem TYPE (3rd field),
# not the mount source: the overlayroot package used by current Raspberry Pi
# OS names its source "overlayroot", but the type is always "overlay".
#
# Returns 0 if overlay is on, 1 if off. (Exit codes that mean what they say.)
pot_overlay_live() {
    local fstype
    fstype=$(awk '$2 == "/" { print $3; exit }' "${POT_FAKEROOT}/proc/mounts")
    [ "$fstype" = "overlay" ]
}

# Where this image keeps cmdline.txt. Bookworm and later use /boot/firmware;
# older images (bullseye and before) use /boot. Prints the path, or nothing
# if neither exists.
pot_cmdline_file() {
    local f
    for f in "${POT_FAKEROOT}/boot/firmware/cmdline.txt" "${POT_FAKEROOT}/boot/cmdline.txt"; do
        if [ -f "$f" ]; then
            echo "$f"
            return 0
        fi
    done
    return 1
}

# Same idea for config.txt (used by the watchdog extra).
pot_config_txt() {
    local f
    for f in "${POT_FAKEROOT}/boot/firmware/config.txt" "${POT_FAKEROOT}/boot/config.txt"; do
        if [ -f "$f" ]; then
            echo "$f"
            return 0
        fi
    done
    return 1
}

# Configured state: will the overlay be on AFTER THE NEXT BOOT?
# raspi-config's enable_overlayfs works by adding "overlayroot=tmpfs" to
# cmdline.txt, so that is what we look for.
#
# Returns 0 if configured on, 1 if configured off, 2 if cmdline.txt can't be
# found (unknown).
pot_overlay_configured() {
    local f
    f=$(pot_cmdline_file) || return 2
    grep -qw 'overlayroot=tmpfs' "$f"
}

# One-word summaries, handy for banners, scripts and Ansible.
pot_live_word() {
    if pot_overlay_live; then echo on; else echo off; fi
}

pot_configured_word() {
    local rc=0
    pot_overlay_configured || rc=$?   # safe under set -e
    case $rc in
        0) echo on ;;
        1) echo off ;;
        *) echo unknown ;;
    esac
}

# Re-run the calling script under sudo if we aren't root already, so users
# can type "overlay-off" without remembering the sudo.
pot_require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        exec sudo -- "$0" "$@"
    fi
}

pot_require_raspi_config() {
    if ! command -v raspi-config >/dev/null 2>&1; then
        echo "ERROR: raspi-config not found. This toolkit drives Raspberry Pi OS's" >&2
        echo "own overlay support (raspi-config + overlayroot); install raspi-config" >&2
        echo "or use a Raspberry Pi OS image." >&2
        exit 1
    fi
}

# Flush, pause (Ctrl-C to abort), reboot.
#
# sync first: a reboot that hangs and needs an unclean power-off can lose
# whatever was still in the page cache, including the cmdline.txt edit that
# the toggle just made.
pot_sync_and_reboot() {
    local delay="${1:-5}"
    sync
    echo "Rebooting $(hostname) in ${delay}s (Ctrl-C to abort; the change still applies at next boot)..."
    sleep "$delay"
    systemctl reboot
}
