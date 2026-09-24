# AGENTS.md

## Project Overview
This repository manages automation and configuration for self-hosted home servers natively using Ansible in a project-local Python virtual environment (`.venv`).

### Managed Hosts
| Host | User | OS | Backup Method | Mode | Containers / Workloads |
|---|---|---|---|---|---|
| `192.168.4.4` | `shawn` | Debian (Pi OS) | `rpi-clone` (`/dev/mmcblk0`) | Read/Write | `glances`, `immich`, `jellyfin`, `syncthing` |
| `192.168.4.5` | `shawn` | Debian (Pi OS) | `rpi-clone` (`/dev/mmcblk0`) | Read/Write | `glances`, `immich-ml` |
| `192.168.4.18` | `shawn` | Debian / Ubuntu | None | Read/Write | `glances`, persistent VLC stream (`snap` vlc) |
| `192.168.4.19` | `shawn` | Fedora (`dnf`) | None | Read/Write | `glances0`, `frigate0` |
| `192.168.4.11` | `shawn` | Debian (Pi OS) | None | **Read-Only (OverlayFS & Boot Protection)** | `pi2beink` |
| `192.168.4.66` | `root` | Arch Linux ARM | None | **Read-Only (Native ext4/vfat ro)** | PiKVM (`kvmd`) |

#### Read-Only Appliance Architectural Differences
* **OverlayFS Pi (`192.168.4.11`)**: Uses kernel OverlayFS (writes redirected to RAM tmpfs) + `/etc/fstab` boot write protection. Controlled via `raspi-config nonint do_overlayfs 0|1`. Requires disabling overlay and rebooting into RW mode to apply `apt` updates, followed by re-enabling overlay and rebooting back into RO mode.
* **Native PiKVM (`192.168.4.66`)**: Uses direct native read-only filesystem mounts (`/` ext4 and `/boot` vfat mounted `ro` via kernel cmdline and `/etc/fstab`). Uses `/usr/bin/rw` and `/usr/bin/ro` remount scripts. Upgraded via official `/usr/bin/pikvm-update --no-reboot` which tests `kvmd -m` integrity. A reboot safely returns `/` and `/boot` to read-only mode if updates were applied.

---

## Environment & Tooling
* **Python Virtual Environment**: `.venv/` at repository root.
* **Dependencies**: Defined in `requirements.txt` (contains `ansible>=9.0.0`).
* **CLI Wrapper**: `./run.sh` wraps `.venv/bin/ansible-playbook` and `ansible`, auto-creating the venv if missing.

---

## Upgrade Pipeline Stages

### Concurrent All-in-One (`upgrade_all.yml` targeting `servers`)
Uses `strategy: free` and `forks: 10` so all 6 servers run simultaneously:
1. `192.168.4.11` checks overlay and boot write protection, disables overlay, reboots into RW mode, and remounts `/boot/firmware` as RW.
2. `192.168.4.66` runs `pikvm-update --no-reboot`, and if updates are applied, reboots cleanly into verified Read-Only mode.
3. Simultaneously, standard servers run their load checks, `rpi-clone` backups, and container pulls.
4. OS and package upgrades execute across standard nodes concurrently (APT/DNF and Snap packages like `vlc` on `.18`, with pre-upgrade dpkg healing on Debian).
5. Standard nodes restart Docker stacks, then restart persistent VLC video streams (`192.168.4.18`).
6. `192.168.4.11` restores boot write protection, re-enables overlay, and reboots back into verified Read-Only mode.

### Standard Hosts Only (`upgrade.yml` targeting `standard_servers`)
1. **Load Check (`tags: [load_check]`)**: Waits for loadavg to drop below `load_threshold`.
2. **Backup (`tags: [backup]`)**: Runs `rpi-clone` on hosts with `backup_method == 'rpi-clone'`. Halts on error.
3. **OS & Package Upgrades (`tags: [os, snap]`)**: Uses `apt` for Debian/Pi OS, `dnf` for Fedora, and `snap refresh` for configured snap packages (`vlc` on `.18`).
4. **Docker Stacks (`tags: [docker]`)**: Minimal downtime update (`docker compose pull` then rolling `docker compose up -d` with system load checks between each stack restart).
5. **VLC Video Stream (`tags: [vlc, snap, os]`)**: Checks if VLC is already running (`pgrep -x vlc`); if not running (or if `force_vlc_restart=true` via `./run.sh restart-vlc`), launches the fullscreen background RTSP stream on `DISPLAY=:0` and verifies process execution.

### Read-Only Pi Maintenance Only (`readonly_upgrade.yml` targeting `readonly_servers`)
1. **Detect Protections**: Checks running and configured states of OverlayFS (`raspi-config nonint get_overlay_now`/`get_overlay_conf`) and Boot Write Protection (`get_bootro_now`/`get_bootro_conf`).
2. **Switch to RW**: Disables overlay (`raspi-config nonint do_overlayfs 1`), reboots into RW mode, remounts `/boot/firmware` (or `/boot`) as read-write (`mount -o remount,rw ...`), and verifies both rootfs and boot partition are writable.
3. **Upgrade**: Heals pending dpkg states (`dpkg --configure -a`) and runs `apt update && apt full-upgrade -y && apt autoremove`.
4. **Restore Protections**: Ensures boot write protection in `/etc/fstab` (`raspi-config nonint enable_bootro`), remounts boot read-only, and re-enables overlay (`raspi-config nonint do_overlayfs 0`).
5. **Reboot & Verify**: Reboots back into Read-Only mode and verifies both `get_overlay_now == 0` and `get_bootro_now == 0`.

### PiKVM Server Maintenance Only (`pikvm_upgrade.yml` targeting `pikvm_servers`)
1. **Detect Mount Status**: Checks initial mount status of `/` and `/boot` via `findmnt`.
2. **Upgrade Software**: Runs `/usr/bin/pikvm-update --no-reboot` which handles repository sync, package cleanup, `kvmd -m` integrity verification, and package upgrades.
3. **Restore Read-Only Mode**: If updates applied (exit code 100), reboots node to boot cleanly back into verified Read-Only mode. If already up-to-date (exit code 0), ensures read-only via `/usr/bin/ro`.
4. **Verify**: Verifies both `/` and `/boot` are mounted read-only and `kvmd -m` integrity passes.

---

## Common Commands

### Connectivity Check
```bash
./run.sh ping
```

### Full Upgrade Pipelines
```bash
# All servers simultaneously (strategy: free)
./run.sh upgrade-all -K

# Standard servers only (192.168.4.4, 4.5, 4.18, 4.19)
./run.sh upgrade -K

# Read-only server maintenance cycle only (192.168.4.11)
./run.sh upgrade-ro -K

# PiKVM server maintenance cycle only (192.168.4.66)
./run.sh upgrade-pikvm                    # No -K needed (authenticates as root)
```

### Selective Execution via Tags
```bash
./run.sh upgrade --tags docker            # Only update containers
./run.sh upgrade --tags os -K             # Only OS package upgrades
./run.sh upgrade --tags snap -K           # Only Snap package upgrades (192.168.4.18)
./run.sh upgrade --tags vlc               # Only restart VLC video stream (192.168.4.18)
./run.sh restart-vlc                      # Dedicated shortcut to restart VLC stream
./run.sh upgrade --tags backup -K         # Only backups
./run.sh upgrade --skip-tags backup -K    # Upgrade without backup
./run.sh upgrade --limit 192.168.4.4 -K   # Single host
```

### Dedicated Backup Only
```bash
./run.sh backup -K
```

### Disk Space Maintenance & Cleanup
```bash
# Reclaim disk space across all standard servers (journal vacuum, apt clean, docker prune)
./run.sh cleanup -K

# Clean disk space on a single host
./run.sh cleanup --limit 192.168.4.18 -K
```

### Ad-hoc Shell Execution
```bash
./run.sh raw 'uptime'
./run.sh raw 'df -h'
```

### Syntax Validation
```bash
.venv/bin/ansible-playbook <playbook.yml> --syntax-check
```

---

## Failure Mitigation & Troubleshooting

### High Loadavg Halting Pipeline
* If Stage 1 fails with a load threshold timeout, inspect running processes:
  ```bash
  ./run.sh raw 'ps aux --sort=-%cpu | head -n 10'
  ```
* If load is temporarily high due to indexing or background tasks, rerun with an override variable:
  ```bash
  ./run.sh upgrade -K -e "load_threshold=8.0"
  ```

### `rpi-clone` Failure
* If `rpi-clone` fails, check if the backup device was dismounted or changed device name:
  ```bash
  ./run.sh raw 'lsblk'
  ```
* Verify the target device specified in `inventory.ini` matches the current block device.

### Read-Only Overlay Pi Fails to Return to Read-Only (`192.168.4.11`)
* If `readonly_upgrade.yml` fails, check current status manually:
  ```bash
  ssh shawn@192.168.4.11 'sudo raspi-config nonint get_overlay_now'
  ```
  - Output `0` = Overlay active (Read-Only).
  - Output `1` = Overlay disabled (Read/Write).
* To manually force back into Read-Only mode:
  ```bash
  ssh shawn@192.168.4.11 'sudo raspi-config nonint do_overlayfs 0 && sudo reboot'
  ```

### PiKVM Fails to Return to Read-Only or Configuration Error (`192.168.4.66`)
* Check mount status:
  ```bash
  ssh root@192.168.4.66 'findmnt -n -o OPTIONS /; findmnt -n -o OPTIONS /boot'
  ```
* If filesystems are left in Read-Write mode:
  ```bash
  ssh root@192.168.4.66 '/usr/bin/ro'
  # Or perform a reboot (PiKVM kernel cmdline boots back into RO automatically)
  ssh root@192.168.4.66 'reboot'
  ```
* If `kvmd -m` integrity check fails:
  - Do NOT reboot until `kvmd -m` succeeds. Inspect output:
    ```bash
    ssh root@192.168.4.66 'kvmd -m'
    ```

---

## File Structure & Conventions
* `inventory.ini`: Server definitions, host variables (`backup_method`, `backup_device`, `load_threshold`, `docker_stacks`), and groups (`standard_servers`, `readonly_servers`, `pikvm_servers`).
* `ansible.cfg`: Core Ansible configuration (forks=10, inventory path, local tmp dir, YAML stdout callback, SSH pipelining).
* `upgrade_all.yml`: Master concurrent upgrade playbook for all 6 servers.
* `upgrade.yml`: Native multi-stage upgrade playbook for standard servers.
* `cleanup.yml`: Automated disk space cleanup playbook (journal capping/vacuum, package cache clean, docker prune).
* `readonly_upgrade.yml`: Automated maintenance playbook for overlayfs read-only Raspberry Pi.
* `pikvm_upgrade.yml`: Automated maintenance playbook for Arch Linux ARM read-only PiKVM server.
* `backup.yml`: Dedicated playbook for `rpi-clone` backups.
* `ping.yml`: Quick connectivity verification playbook.
* `tasks/restart_docker_stack.yml`: Modular task for restarting a docker stack with pre-restart system load verification.
* `tasks/restart_vlc_stream.yml`: Modular task to cleanly stop, launch, and verify persistent fullscreen VLC video stream.
* `run.sh`: Main entrypoint for humans and automation.
* `requirements.txt`: Python package requirements.
* `AGENTS.md` / `CLAUDE.md`: Repository instructions and conventions for AI assistants.
* `.gitignore`: Excludes `.venv/`, `.ansible/`, retry files, and system logs.

### Guidelines for AI Agents
1. **Always use `.venv` or `./run.sh`**: Never invoke global `ansible` directly.
2. **Validate Syntax Before Commits**: Run `.venv/bin/ansible-playbook <playbook> --syntax-check` when creating or modifying playbooks.
3. **Respect Safety Checks**: Verify host variables before running hardware/backup operations like `rpi-clone`.
4. **Preserve `local_tmp` in `ansible.cfg`**: Keep temporary directory pointing to `./.ansible/tmp` to avoid sandbox and permission issues with `/Users/shawn/.ansible`.
5. **PiKVM Environment Specifics (`192.168.4.66`)**:
   - Runs Arch Linux ARM as `root` (no `sudo` required).
   - Because `/root` is read-only when mounted `ro`, `ansible_remote_tmp=/tmp/.ansible` is configured in `inventory.ini` to write to the `tmpfs` at `/tmp`.
   - Never run `raspi-config` or `apt` commands on `192.168.4.66`. Always use `/usr/bin/pikvm-update` for system updates to ensure KVMD service integrity checks and hooks run properly.
