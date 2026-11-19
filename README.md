# Pi OverlayFS Toolkit

Safe-toggle tooling for Raspberry Pi OS's read-only root (the
`raspi-config` overlay, implemented with the `overlayroot` package), for
any number of unattended Pis.

With the overlay on, the root filesystem is a RAM overlay and the SD card
is never written. That's great for an unattended device, but it means
**any change you make (config edits, packages, scripts) silently vanishes
at the next reboot** unless you turn the overlay off first. This toolkit
makes that hard to forget and hard to get wrong, the same way on every Pi.

Nothing in it is specific to one host: hostnames, boot paths, and WiFi
interfaces are all detected at run time.

## Hosts

| Host | Hardware | OS | Status |
|---|---|---|---|
| `weatherhat` | Pi Zero 2 W + BC Robotics Weather HAT Pro | Raspberry Pi OS trixie (Debian 13) | v2 verified 2026-11-18 (extras not installed) |
| `enviro` | Pi Zero 2 W | Raspberry Pi OS trixie (Debian 13) | v2 verified 2026-11-19 (extras installed |
| `weatherboard` | Pi Zero 2 W + Pimoroni Inky Impression | Raspberry Pi OS trixie (Debian 13) | v2 verified 2026-11-19 (extras installed) |

Update this table as each host is verified.

## What's included

| File | Installed to | Purpose |
|---|---|---|
| `overlay-common.sh` | `/usr/local/lib/pi-overlay-toolkit/` | Shared helpers (state detection, boot paths) |
| `overlay-switch` | `/usr/local/bin/` | Does the work: `overlay-switch on\|off [--no-reboot]` |
| `overlay-on`, `overlay-off` | `/usr/local/bin/` | Wrappers for the above, the commands you type |
| `overlay-status` | `/usr/local/bin/` | State now and after the next boot; `--short` for scripts |
| `99-overlayfs-status` | `/etc/update-motd.d/` | Login banner showing live state and any pending change |
| `install-overlay-tools.sh` | | Installs/upgrades/uninstalls the above on the Pi it runs on |
| `deploy.sh` | | Runs the installer on several Pis over SSH from your workstation |
| `extras/` | | Optional WiFi self-heal + hardware watchdog (see below) |

## Install

### On several Pis from your workstation

```bash
git clone https://github.com/chrisramsay/pi-overlay-toolkit
cd pi-overlay-toolkit

# Pis whose overlay is currently off (e.g. a new Pi mid-setup):
./deploy.sh enviro.searby.space

# Pis that are already overlaid: --cycle turns the overlay off, waits for the
# reboot, installs, turns it back on and waits again.
./deploy.sh --cycle weatherhat.searby.space enviro.searby.space

# Add the reliability extras at the same time:
./deploy.sh --cycle --extras weatherhat.searby.space
```

`deploy.sh` needs SSH access and sudo on each Pi (passwordless sudo is
easiest, but it uses `ssh -t`, so a password prompt also works). Put extra
SSH options in `SSH_OPTS`, e.g. `SSH_OPTS="-o User=pi" ./deploy.sh ...`.
A host found with the overlay off is always left off.

### On one Pi by hand

```bash
overlay-status 2>/dev/null || awk '$2 == "/" {print $3}' /proc/mounts
# "ext4" / "OFF now": go ahead. "overlay" / "ON now": turn it off first:
#   sudo raspi-config nonint disable_overlayfs && sudo reboot

sudo bash install-overlay-tools.sh      # verifies every file landed
overlay-on                              # when you're finished
```

Uninstall with `sudo bash install-overlay-tools.sh --uninstall`. This
leaves the overlay setting as it is.

**Upgrading from v1:** v1 installed `overlay-on`/`overlay-off` into
`/usr/local/sbin`. The installer removes those and puts everything in
`/usr/local/bin`, which is on a normal user's `PATH` on Bookworm as well as
Trixie. (Bookworm's default user `PATH` has no `sbin`.)

## Day-to-day usage

```bash
overlay-status   # e.g. "enviro: overlay is ON now, ON after next boot."
overlay-off      # reboots; root is now writable
# ...make and test your changes...
overlay-on       # reboots; changes locked in, SD card protected again
```

The commands re-run themselves under `sudo`, so you don't need to type it.
You don't need any of this for changes that don't have to survive a reboot,
such as checking logs or trying something out.

### Live vs configured state

The overlay has two states that can disagree:

- **live**: what `/` is mounted as right now (from `/proc/mounts`)
- **configured**: what it will be after the next boot (`overlayroot=tmpfs`
  in `cmdline.txt`)

They disagree after `overlay-on --no-reboot`, or after a toggle whose
reboot was interrupted. `overlay-switch` handles every combination:

| live | configured | you ask for | result |
|---|---|---|---|
| X | X | X | nothing to do |
| X | Y | X | pending change cancelled, **no reboot** |
| Y | X | X | already configured, just reboots |
| Y | Y | X | changes config, reboots |

The login banner and `overlay-status` show any pending change.

`--no-reboot` is there for scripts and Ansible: make the config change now
and reboot on your own schedule.

## Why this isn't just `raspi-config nonint enable_overlayfs`

1. **`raspi-config nonint get_overlay_now` prints its answer and doesn't
   return it.** It prints `0` (on) or `1` (off), but the process exit code
   is `0` either way, so `get_overlay_now && echo on || echo off` almost
   always says "on". The toolkit reads `/proc/mounts` instead.

2. **Match the filesystem type, not the mount source.** Current Raspberry
   Pi OS implements the overlay with Debian's `overlayroot`, whose mount
   source is literally `overlayroot`:
   ```
   overlayroot / overlay rw,relatime,lowerdir=/media/root-ro,...
   ```
   `grep '^overlay / ' /proc/mounts` misses that. The third field (type) is
   `overlay` for both `overlayroot` and the older implementation:
   ```bash
   awk '$2 == "/" { print $3; exit }' /proc/mounts
   ```

3. **Don't trust exit codes alone.** After calling `raspi-config`, the
   toolkit re-reads `cmdline.txt` to confirm the change landed before it
   reboots. The installer compares every installed file byte-for-byte with
   its source before reporting success.

4. **`sync` before every reboot.** If a reboot hangs and needs an unclean
   power-off, anything still in the page cache is lost. That can include the
   `cmdline.txt` edit or the files just installed.

5. **Boot paths differ by release.** Bookworm and later use
   `/boot/firmware/`, while older images use `/boot/`. Both are checked.

Note that `raspi-config` refuses to enable the overlay on boards with
256 MB of RAM or less. A Pi Zero 2 W (512 MB) is fine. The first
`overlay-on` on a fresh image may also `apt-get install overlayroot`, so
the Pi needs network access at that point.

## extras/: reliability add-ons (not yet verified on hardware)

These address a different problem from the overlay: a Pi that hangs or
drops off WiFi after a few days and needs a manual power cycle.

- **WiFi self-heal.** `wifi-check.sh` is run every 5 minutes by
  `wifi-check.timer` (first run 10 minutes after boot). It pings the
  default gateway. If that fails, it cycles the WiFi interface, using
  `nmcli` when NetworkManager manages it and `ip link` otherwise. If the
  link still doesn't come back, it reboots, but only once the Pi has been
  up for at least `MIN_UPTIME_MIN` (default 30). That way an AP or router
  outage can't send every Pi into a reboot loop. Settings live in
  `/etc/default/wifi-check`, and the installer never overwrites that file:
  ```bash
  #WIFI_IFACE=wlan0          # default: first wireless interface
  #PING_TARGET=192.168.20.1  # default: default gateway
  #MIN_UPTIME_MIN=30
  #REBOOT=yes                # "no" = only cycle the interface
  ```
  It logs only when it does something: `journalctl -t wifi-check`.
- **Hardware watchdog.** Adds `dtparam=watchdog=on` to `config.txt` and
  installs the systemd drop-in
  `/etc/systemd/system.conf.d/10-pi-watchdog.conf`
  (`RuntimeWatchdogSec=15`, `RebootWatchdogSec=2min`). No hand-editing of
  `system.conf` is needed.

```bash
overlay-off
sudo bash extras/install-reliability-extras.sh   # --uninstall to remove
overlay-on                                        # its reboot activates the watchdog

# after the reboot, verify:
systemctl show -p RuntimeWatchdogUSec     # 15s
ls -l /dev/watchdog*
systemctl list-timers wifi-check.timer
```

(`./deploy.sh --cycle --extras host` does all of this.) The installer also
removes the cron job and `/usr/local/bin/wifi-check.sh` left by v1 of the
extras.

## Background

The two gotchas at the top of "Why this isn't just..." were found by
testing against the real `overlayroot`-based implementation on the Weather
Pi (now `weatherhat`), rather than assuming the classic one. v2 generalised
the toolkit for the other Pi Zero 2 Ws (`enviro` and the forthcoming
weather-board Pi). It added state handling, the deploy script, and
self-configuring extras.
