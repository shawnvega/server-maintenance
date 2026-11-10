# Upgrade Pipelines & Execution Lifecycles

This document describes the Ansible maintenance and upgrade pipelines across the homelab cluster, their execution stages, safety checkpoints, and tag-based selective execution.

---

## Pipeline Overview

| Pipeline Playbook | Target Group | Strategy | Command |
|---|---|---|---|
| `upgrade_all.yml` | `servers` (All 6 nodes) | `strategy: free` (concurrent) | `./run.sh upgrade-all -K` |
| `upgrade.yml` | `standard_servers` (`.4`, `.5`, `.18`, `.19`) | `strategy: linear` (staged) | `./run.sh upgrade -K` |
| `readonly_upgrade.yml` | `readonly_servers` (`.11`) | Staged reboot cycle | `./run.sh upgrade-ro -K` |
| `pikvm_upgrade.yml` | `pikvm_servers` (`.66`) | Root update & verify | `./run.sh upgrade-pikvm` |
| `upgrade_mac.sh` | Local Mac workstation | Native bash script | `./run.sh upgrade-mac` |

---

## 1. Concurrent Master Upgrade (`upgrade_all.yml`)

The master playbook executes across all 6 cluster nodes concurrently using Ansible's `strategy: free` and `forks: 10`. Nodes do not block each other:

1. **`192.168.4.11` (Read-Only Pi)**: Checks current overlay and boot protection, disables overlay, reboots into RW mode, and remounts `/boot/firmware` as RW.
2. **`192.168.4.66` (PiKVM)**: Evaluates system load, runs `/usr/bin/pikvm-update --no-reboot`, verifies KVMD integrity, and reboots cleanly into verified Read-Only mode if packages were updated.
3. **Standard Nodes (`.4`, `.5`, `.18`, `.19`)**:
   * Run pre-flight Btrfs scrub safety checks (`tags: [scrub_check]`). If an active scrub is detected, the affected node displays progress/ETA and is safely skipped (`meta: end_host`) without interrupting other nodes.
   * Nodes with active backups (`.4`, `.5`) run `rpi-clone` to SD card storage.
   * Pull Docker images in the background while running services remain online.
4. **OS Updates**: APT / DNF and Snap package upgrades run across all nodes concurrently with dpkg healing.
5. **Workload Restarts**: Standard nodes execute rolling Docker restarts, followed by persistent VLC RTSP video stream verification on `.18`.
6. **Protection Restoration**: `192.168.4.11` restores boot write protection in `/etc/fstab`, re-enables OverlayFS, and reboots back into verified Read-Only mode.

---

## 2. Standard Servers Pipeline (`upgrade.yml`)

Designed for regular maintenance of standard read/write servers (`192.168.4.4`, `192.168.4.5`, `192.168.4.18`, `192.168.4.19`). When run inside Semaphore, it safely skips `192.168.4.5` (see [workflows.md](workflows.md)).

### Pipeline Stages

#### Stage 0: Btrfs Scrub Safety Check (`tags: [scrub_check]`)
* Checks for running Btrfs scrubs via `btrfs scrub status`.
* If a scrub is active, prints scrub speed, bytes scrubbed, and estimated completion time, then safely terminates execution for that host (`meta: end_host`).
* Can be overridden with `-e "ignore_btrfs_scrub=true"` or `--skip-tags scrub_check`.

#### Stage 1: Load Check (`tags: [load_check]`)
* Evaluates 1-minute load average against `load_threshold` (`2.0` on `.18`, `4.0` on others).
* Retries every 15 seconds up to 300 seconds to allow transient spikes to settle.

#### Stage 2: Backup (`tags: [backup]`)
* On hosts configured with `backup_method == 'rpi-clone'`, validates target device in `inventory.ini` and runs `rpi-clone`.
* Halts execution if backup fails.

#### Stage 3: OS & Package Upgrades (`tags: [os, snap]`)
* **Debian / Ubuntu / Pi OS**: Pre-upgrade dpkg healing (`dpkg --configure -a`), `apt-get update`, `apt-get full-upgrade`, and `apt-get autoremove`.
* **Fedora**: `dnf upgrade --refresh -y`.
* **Snap Packages**: Refreshes configured snap packages (e.g. `vlc` on `.18`).

#### Stage 4: Docker Stacks (`tags: [docker]`)
* Performs a two-pass rolling update:
  1. `docker compose pull` on all stacks while containers stay online.
  2. Sequential rolling `docker compose up -d` with pre-restart system load verification between stacks.

#### Stage 5: VLC Video Stream (`tags: [vlc, snap, os]`)
* On `192.168.4.18`, checks if VLC is running (`pgrep -x vlc`).
* If not running (or if forced via `force_vlc_restart=true`), launches the fullscreen background RTSP stream on `DISPLAY=:0`.

#### Stage 6: Safe Automated Reboot (`tags: [reboot]`)
* Checks if a reboot is pending (`/var/run/reboot-required` on Debian or `needs-restarting -r` on Fedora).
* If a reboot is required, it evaluates **4 safety guardrails**:
  1. No active Btrfs operations (scrub, balance, device replace).
  2. No active backup processes (`rpi-clone`, `rsync`, `restic`).
  3. No interactive SSH user sessions (`who | grep pts/`).
  4. 1-minute system load < `4.0`.
* If all pass, reboots host and verifies post-reboot health; if any check fails, logs a blocker report and cleanly defers the reboot. Skip with `--skip-tags reboot` or `-e "auto_reboot=false"`.

---

## 3. Read-Only Pi Maintenance Cycle (`readonly_upgrade.yml`)

Dedicated isolated maintenance for `192.168.4.11`:
1. **Detect Protections**: Reads running and configured states of OverlayFS and Boot Write Protection via `raspi-config nonint`.
2. **Disable Protections & Reboot**: Disables overlay (`raspi-config nonint do_overlayfs 1`), reboots into RW mode, and remounts `/boot/firmware` (or `/boot`) as read-write.
3. **Upgrade**: Heals dpkg state and applies full system updates (`apt update && apt full-upgrade -y && apt autoremove`).
4. **Restore Protections & Reboot**: Re-enables boot write protection (`raspi-config nonint enable_bootro`), remounts boot read-only, enables overlay (`raspi-config nonint do_overlayfs 0`), and reboots back into verified Read-Only mode.
5. **Verify**: Asserts that `get_overlay_now == 0` and `get_bootro_now == 0`.

---

## 4. PiKVM Server Maintenance (`pikvm_upgrade.yml`)

Dedicated isolated maintenance for `192.168.4.66` (Arch Linux ARM):
1. **Check Mount Status**: Verifies `/` and `/boot` mount options via `findmnt`.
2. **Execute pikvm-update**: Runs official `/usr/bin/pikvm-update --no-reboot`.
3. **Handle Exit Codes**:
   * Exit Code `100` (Updates applied): Reboots the host. The PiKVM kernel command line automatically mounts filesystems back into read-only mode upon reboot.
   * Exit Code `0` (Already up-to-date): Ensures read-only lock via `/usr/bin/ro`.
4. **Verify**: Asserts `/` and `/boot` are mounted `ro` and `kvmd -m` integrity passes.

---

## 5. Local Mac Workstation (`upgrade_mac.sh`)

Manages maintenance of the host macOS development environment:
* Updates Homebrew formulae, casks, global npm packages, GitHub CLI extensions, and Mac App Store apps.
* Checks for Apple macOS system updates.
* **Credentials Note**: Runs unprivileged as local user; elevation (Touch ID/sudo) is requested directly in the local terminal only if system updates or privileged casks require it.
* Supports dry-run preview (`./run.sh upgrade-mac -n`) and unattended system updates (`./run.sh upgrade-mac --all`).

---

## Tag-Based Execution Reference

Ansible tags allow targeted execution of specific pipeline stages without running the full suite:

```bash
# Update containers only (pull and rolling restart)
./run.sh upgrade --tags docker

# Update OS packages only (requires sudo -K)
./run.sh upgrade --tags os -K

# Update Snap packages only
./run.sh upgrade --tags snap -K

# Restart VLC stream only
./run.sh restart-vlc
# or: ./run.sh upgrade --tags vlc

# Run backups only
./run.sh backup -K
# or: ./run.sh upgrade --tags backup -K

# Skip backups during upgrade
./run.sh upgrade --skip-tags backup -K

# Skip reboot checks
./run.sh upgrade --skip-tags reboot -K

# Run dry run (simulate changes without installing)
./run.sh upgrade-all --check -K

# Target a single server
./run.sh upgrade --limit 192.168.4.4 -K
```

---

## Pipeline Troubleshooting & Overrides

### 1. High System Load Halts Upgrade Pipeline
* **Symptoms**: Stage 1 (`load_check`) in `upgrade.yml` or `upgrade_all.yml` times out waiting for load average to drop below threshold (`load_threshold`).
* **Investigation**: Inspect top CPU-consuming processes on the blocked node:
  ```bash
  ./run.sh raw 'ps aux --sort=-%cpu | head -n 10'
  ```
  * On `192.168.4.19`: Check Frigate camera ingestion or Hermes model inference.
  * On `192.168.4.4` / `.5`: Check Immich machine learning transcode or indexing jobs.
* **Mitigation & Overrides**: If high load is expected batch background processing:
  ```bash
  # Override load threshold for this run
  ./run.sh upgrade -K -e "load_threshold=8.0"

  # Or skip load check entirely
  ./run.sh upgrade -K --skip-tags load_check
  ```

### 2. `rpi-clone` Backup Failures
* **Symptoms**: Stage 2 (`backup`) halts with an error executing `rpi-clone`.
* **Investigation**: Check whether target block device disconnected or shifted names:
  ```bash
  ./run.sh raw 'lsblk'
  ssh shawn@192.168.4.4 'sudo dmesg -T | grep -E "(mmc|sd|error)" | tail -n 20'
  ```
* **Mitigation**:
  1. Compare device name with `backup_device` in `inventory.ini` and update if shifted (e.g. `/dev/sda` -> `/dev/sdb`).
  2. If destination SD/USB card corrupted, format or replace the media.
  3. To proceed with package updates without backing up:
     ```bash
     ./run.sh upgrade -K --skip-tags backup
     ```

### 3. VLC RTSP Video Stream Recovery (`192.168.4.18`)
* **Symptoms**: Fullscreen camera monitor stream on Chromebook display is frozen or closed.
* **Investigation & Restart**:
  ```bash
  # Restart stream via dedicated runner shortcut
  ./run.sh restart-vlc

  # If display errors occur, ensure X11 display session :0 is active
  ssh shawn@192.168.4.18 'DISPLAY=:0 xrandr'
  ```

