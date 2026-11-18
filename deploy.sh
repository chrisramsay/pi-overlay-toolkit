#!/bin/bash
# deploy.sh: install or upgrade the toolkit on one or more Pis over SSH.
# Run it from your workstation, inside a checkout of this repo.
#
#   ./deploy.sh [--extras] [--cycle] host [host ...]
#
#   --extras   also install extras/ (wifi-check + hardware watchdog)
#   --cycle    handle the overlay for you: if a host's overlay is ON, turn it
#              off and wait for the reboot, install, then turn it back on and
#              wait again. Without --cycle, hosts with the overlay on are
#              skipped. Either way, a host found with the overlay OFF is
#              left OFF (it's probably mid-setup).
#
# Hosts are anything ssh accepts (weatherhat, raz@enviro.searby.space, ...).
# Extra ssh options can go in $SSH_OPTS, e.g. SSH_OPTS="-o User=pi".
# Needs sudo on the Pi; passwordless sudo is easiest, but -t lets a password
# prompt through if needed.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXTRAS=0
CYCLE=0
HOSTS=()
BOOT_TIMEOUT=${BOOT_TIMEOUT:-300}
# shellcheck disable=SC2206
SSH=(ssh ${SSH_OPTS:-} -o ConnectTimeout=5)
REMOTE_DIR=/tmp/pi-overlay-toolkit

usage() { sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

for arg in "$@"; do
    case "$arg" in
        --extras) EXTRAS=1 ;;
        --cycle)  CYCLE=1 ;;
        -h|--help) usage ;;
        -*) echo "Unknown option: $arg" >&2; usage ;;
        *) HOSTS+=("$arg") ;;
    esac
done
[ "${#HOSTS[@]}" -gt 0 ] || usage

FILES=(overlay-common.sh overlay-switch overlay-on overlay-off overlay-status
       99-overlayfs-status install-overlay-tools.sh)
[ "$EXTRAS" -eq 1 ] && FILES+=(extras)

say() { printf '\n==> %s: %s\n' "$1" "$2"; }

remote()   { local h=$1; shift; "${SSH[@]}" -o BatchMode=yes "$h" "$@"; }
remote_t() { local h=$1; shift; "${SSH[@]}" -t "$h" "$@"; }

live_state() {
    remote "$1" "awk '\$2 == \"/\" { print \$3; exit }' /proc/mounts"
}

boot_id() { remote "$1" cat /proc/sys/kernel/random/boot_id; }

# Reboots are triggered with the toolkit's own scripts when present, else
# raspi-config directly (first install on a host that's already overlaid).
set_overlay_and_wait() {
    local h=$1 want=$2 before after waited=0
    before=$(boot_id "$h")
    if remote "$h" test -x /usr/local/bin/overlay-switch; then
        remote_t "$h" "sudo /usr/local/bin/overlay-switch $want" || true
    else
        local fn=disable_overlayfs
        [ "$want" = on ] && fn=enable_overlayfs
        remote_t "$h" "sudo raspi-config nonint $fn && sync && sudo systemctl reboot" || true
    fi
    say "$h" "waiting for reboot (up to ${BOOT_TIMEOUT}s) ..."
    sleep 15
    while :; do
        after=$(boot_id "$h" 2>/dev/null || true)
        if [ -n "$after" ] && [ "$after" != "$before" ]; then
            break
        fi
        waited=$((waited + 10))
        if [ "$waited" -ge "$BOOT_TIMEOUT" ]; then
            echo "    $h didn't come back within ${BOOT_TIMEOUT}s" >&2
            return 1
        fi
        sleep 10
    done
    say "$h" "back up, root is now: $(live_state "$h")"
}

deploy_one() {
    local h=$1 fstype was_on=0
    say "$h" "checking overlay state"
    if ! fstype=$(live_state "$h"); then
        echo "    can't reach $h over ssh, skipping" >&2
        return 1
    fi

    if [ "$fstype" = overlay ]; then
        if [ "$CYCLE" -eq 0 ]; then
            echo "    overlay is ON, skipping (rerun with --cycle, or overlay-off first)"
            return 1
        fi
        was_on=1
        say "$h" "overlay is ON, turning it off"
        set_overlay_and_wait "$h" off || return 1
        [ "$(live_state "$h")" != overlay ] || { echo "    still overlaid, giving up" >&2; return 1; }
    fi

    say "$h" "copying files"
    tar -C "$REPO" -cf - "${FILES[@]}" | \
        remote "$h" "rm -rf $REMOTE_DIR && mkdir -p $REMOTE_DIR && tar -C $REMOTE_DIR -xf -" || return 1

    say "$h" "installing toolkit"
    remote_t "$h" "sudo bash $REMOTE_DIR/install-overlay-tools.sh" || return 1
    if [ "$EXTRAS" -eq 1 ]; then
        say "$h" "installing extras"
        remote_t "$h" "sudo bash $REMOTE_DIR/extras/install-reliability-extras.sh" || return 1
    fi
    remote "$h" "rm -rf $REMOTE_DIR"

    # Put the overlay back the way we found it. (The reboot this causes also
    # activates the watchdog if extras went in.)
    if [ "$was_on" -eq 1 ]; then
        say "$h" "turning overlay back ON"
        set_overlay_and_wait "$h" on || return 1
    else
        say "$h" "installed. Overlay left OFF; run 'overlay-on' on $h when ready."
        [ "$EXTRAS" -eq 1 ] && echo "    (overlay-on's reboot also activates the watchdog)"
    fi
    remote "$h" /usr/local/bin/overlay-status
}

FAILED=()
for h in "${HOSTS[@]}"; do
    deploy_one "$h" || FAILED+=("$h")
done

echo
if [ "${#FAILED[@]}" -gt 0 ]; then
    echo "Done, with problems on: ${FAILED[*]}"
    exit 1
fi
echo "Done: ${HOSTS[*]}"
