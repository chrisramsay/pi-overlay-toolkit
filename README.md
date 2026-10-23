# Pi Zero OverlayFS Toolkit

Safe-toggle tooling for Raspberry Pi OS's root-filesystem OverlayFS, built
and verified on a Pi Zero 2 W ("Weather Pi") running Raspberry Pi OS
trixie (Debian 13, kernel 6.18).

With overlayfs on, the root filesystem is RAM-backed and read-only on
disk — great for protecting an SD card on an unattended device, but it
means **any change you make (config edits, installed packages, scripts)
silently vanishes on the next reboot** unless you remember to disable the
overlay first. This toolkit makes that hard to forget and hard to get
wrong.

## What's included

| File | Purpose |
|---|---|
| `overlay-off` | Disables overlayfs (root becomes writable) and reboots |
| `overlay-on` | Re-enables overlayfs (root becomes RAM-only) and reboots |
| `99-overlayfs-status` | Dynamic MOTD banner — shows live overlay state on every SSH login |
| `install-overlay-tools.sh` | Installs the three files above |
| `extras/` | Optional reliability add-ons (watchdog + WiFi self-heal) — see below, **not yet verified on hardware** |

## Why this isn't just `raspi-config nonint enable_overlayfs`

Two gotchas this toolkit works around:

1. **`raspi-config nonint get_overlay_now` is not safe to use with `&&`/`||`.**
   It prints its answer as text (`0` = enabled, `1` = disabled), but the
   *process exit code* is always `0` on a successful run, regardless of
   which answer it printed. Testing the exit code (`get_overlay_now &&
   echo on || echo off`) will almost always say "on" no matter the real
   state. This toolkit instead reads `/proc/mounts` directly — ground
   truth, no ambiguity.

2. **Match on filesystem *type*, not mount *source name*.** Some
   Raspberry Pi OS builds (including trixie, where this was built)
   implement the overlay via the Debian `overlayroot` package. Its mount
   source is literally named `overlayroot`, not `overlay`:
   ```
   overlayroot / overlay rw,relatime,lowerdir=/media/root-ro,...
   ```
   A check like `grep '^overlay / ' /proc/mounts` misses this entirely,
   because it matches on the first field (the source name). Checking the
   **third** field (filesystem type, which is `overlay` regardless of
   which package provides it) works on both the classic and the
   `overlayroot`-based implementations:
   ```bash
   ROOT_FSTYPE=$(awk '$2 == "/" { print $3; exit }' /proc/mounts)
   [ "$ROOT_FSTYPE" = "overlay" ]
   ```

3. **`sync` before every reboot these scripts trigger.** A write to disk
   isn't necessarily flushed from the page cache immediately. If a
   reboot hangs and needs an unclean power-off, anything not yet flushed
   can be lost — including, ironically, files this very toolkit just
   installed. Every script here calls `sync` right before it reboots, to
   close that window. `install-overlay-tools.sh` also **verifies its own
   install succeeded** (checks the banner file actually contains the
   expected content) before reporting success, rather than assuming a
   zero exit code means the files landed.

## Installation on a new Pi

```bash
# 1. Make sure overlayfs is off (root must be writable to install anything
#    persistent). If you're not sure, check:
awk '$2 == "/" {print $3}' /proc/mounts
#    "ext4" = writable, good to proceed. "overlay" = disable it first:
sudo raspi-config nonint disable_overlayfs && sudo systemctl reboot

# 2. Copy this repo onto the Pi (scp, git clone, or paste file contents
#    manually), then from inside it:
sudo bash install-overlay-tools.sh

# 3. The installer verifies itself and will refuse to report success if
#    the write didn't actually land. Once it says "Done":
overlay-on
```

Log out and back in — the MOTD banner should now show OverlayFS as ON,
matching `awk '$2 == "/" {print $3}' /proc/mounts` (which should print
`overlay`).

## Day-to-day usage

Any change you want to **persist across a reboot** — editing a config,
installing a package, adding a cron job, touching anything under `/`
including `/home` — needs:

```bash
overlay-off      # wait for reboot, root is now writable
# ...make your changes...
overlay-on        # wait for reboot, changes are now locked in under RAM overlay
```

You do **not** need to do this for changes you don't need to survive a
reboot (checking logs, running something to test it in the current
session, etc).

`sync` is already built into `overlay-off`/`overlay-on` — you don't need
to run it yourself unless you reboot some other way (e.g. a bare
`sudo systemctl reboot`) without going through these scripts, in which
case running `sync` first first is cheap insurance.

## extras/ — reliability add-ons (not yet verified)

These address a separate problem from the overlay toggling above: a Pi
that hangs or drops off WiFi after a few days and needs a manual power
cycle to recover. They were written and discussed in the same session as
the toolkit above, but **the watchdog + wifi-check setup itself was not
confirmed working end-to-end on real hardware** before this repo was
packaged — treat `extras/` as a starting point to test, not a verified
component like the rest of this repo.

- **`wifi-check.sh`** — runs every 5 minutes via cron; pings the default
  gateway, cycles `wlan0` if unreachable, and reboots if that doesn't
  recover it. Uses `ip link` directly rather than `nmcli`/`wpa_cli`, so
  it should work regardless of network stack.
- **`install-reliability-extras.sh`** — installs `wifi-check.sh` + its
  cron job, and enables the Pi's hardware watchdog in
  `/boot/firmware/config.txt`. **One manual step remains after running
  it**: edit `/etc/systemd/system.conf` and set
  ```ini
  RuntimeWatchdogSec=15
  RebootWatchdogSec=2min
  ```
  (uncomment and/or add these lines) before rebooting.

Usage follows the same overlay-off → install → overlay-on pattern:

```bash
overlay-off
sudo bash extras/install-reliability-extras.sh
sudo nano /etc/systemd/system.conf   # set the two watchdog lines above
sudo systemctl reboot

# after reboot, verify:
ls -l /dev/watchdog
systemctl show -p WatchdogDevice -p RuntimeWatchdogUSec
cat /etc/cron.d/wifi-check

overlay-on
```

## Background / history

This toolkit went through several iterations before reaching the state
above — notably the two gotchas in the "Why this isn't just..." section,
both discovered by testing against the real `overlayroot`-based
implementation rather than assuming the classic one. If you're adapting
this for a Pi that *doesn't* use the `overlayroot` package, the
`ROOT_FSTYPE` check still works fine (plain `overlay` sources also
report filesystem type `overlay`).
