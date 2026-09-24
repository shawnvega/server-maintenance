# Selfhosted Infrastructure & Automation

Ansible automation for managing home servers natively (load monitoring, rpi-clone backups, OS updates, Docker compose services, read-only overlay Pi maintenance, and Arch Linux ARM PiKVM maintenance).

## Servers Managed

| Host | User | OS | Backup Method | Containers / Workloads | Mode |
|---|---|---|---|---|---|
| `192.168.4.4` | `shawn` | Debian (Pi OS) | `rpi-clone` (`/dev/mmcblk0`) | `glances`, `immich`, `jellyfin`, `syncthing` | Read/Write |
| `192.168.4.5` | `shawn` | Debian (Pi OS) | `rpi-clone` (`/dev/mmcblk0`) | `glances`, `immich-ml` | Read/Write |
| `192.168.4.18` | `shawn` | Debian / Ubuntu | None | `glances`, persistent VLC stream (`snap` vlc) | Read/Write |
| `192.168.4.19` | `shawn` | Fedora (`dnf`) | None | `glances0`, `frigate0` | Read/Write |
| `192.168.4.11` | `shawn` | Debian (Pi OS) | None | `pi2beink` | **Read-Only (OverlayFS & Boot Protection)** |
| `192.168.4.66` | `root` | Arch Linux ARM | None | PiKVM (`kvmd`) | **Read-Only (Native ext4/vfat ro)** |

---

## Read-Only Architecture Comparison

This cluster features two distinct read-only appliance implementations:

| Attribute | OverlayFS Pi (`192.168.4.11`) | PiKVM (`192.168.4.66`) |
|---|---|---|
| **OS** | Debian / Raspberry Pi OS | Arch Linux ARM |
| **User** | `shawn` (uses `sudo -K`) | `root` (direct SSH key) |
| **Read-Only Mechanism** | Kernel OverlayFS (writes in RAM tmpfs) + `/boot` ro | Native ext4 root `/` and `/boot` mounted `ro` |
| **Control Commands** | `raspi-config nonint do_overlayfs 0\|1` | `/usr/bin/rw`, `/usr/bin/ro` |
| **Upgrade Method** | Disable overlay -> Reboot -> `apt full-upgrade` -> Enable overlay -> Reboot | `/usr/bin/pikvm-update --no-reboot` -> Reboot if updated |
| **Verification** | `raspi-config nonint get_overlay_now` (expect `0`) | `findmnt -n -o OPTIONS /` (expect `ro`) & `kvmd -m` |

---

## Upgrade Pipelines

### 1. Concurrent Master Upgrade (`upgrade_all.yml`)
Upgrades **all 6 servers simultaneously** using Ansible's `strategy: free`:
* `192.168.4.11` checks overlay and boot write protection, disables overlay, reboots into RW mode, and remounts `/boot/firmware` as RW.
* `192.168.4.66` checks load, runs `pikvm-update --no-reboot`, and reboots cleanly back into verified Read-Only mode if updates applied.
* Concurrently, standard servers run their backups, OS updates, and Docker pulls without waiting for `.11`'s reboot.
* OS and package upgrades run across all machines in parallel (APT/DNF and Snap packages like `vlc` on `.18`, with pre-upgrade dpkg healing on Debian).
* Standard servers restart Docker stacks and restart persistent VLC video streams (`192.168.4.18`).
* Prompt for sudo password once (`-K`) for standard hosts and `.11` (`root@192.168.4.66` connects directly without sudo).

### 2. Standard Servers Only (`upgrade.yml`)
Executes natively across standard servers (`.4`, `.5`, `.18`, `.19`) without touching `.11` or `.66`:
1. **Load Check (`tags: [load_check]`)**: Waits for CPU load average to drop below threshold (`2.0` on `.18`, `4.0` on others).
2. **Backup (`tags: [backup]`)**: Runs `rpi-clone` on `.4` and `.5`.
3. **OS & Package Upgrades (`tags: [os, snap]`)**: Uses `apt full-upgrade` on Debian hosts, `dnf upgrade` on Fedora, and `snap refresh` for configured snap packages (`vlc` on `.18`).
4. **Docker Stacks (`tags: [docker]`)**: Minimal downtime rolling update (`docker compose pull` while services stay online, then rolling `docker compose up -d` with load checks between each stack).
5. **VLC Video Streams (`tags: [vlc, snap, os]`)**: Stops prior instance, starts background fullscreen stream (`DISPLAY=:0`), and verifies process execution.

### 3. Read-Only Pi Maintenance Only (`readonly_upgrade.yml`)
Automates the full maintenance cycle for `192.168.4.11` in isolation:
1. Checks running and configured state of OverlayFS and Boot Write Protection.
2. Switches overlay to Read/Write (`raspi-config nonint do_overlayfs 1`) and reboots into RW mode.
3. Remounts `/boot/firmware` (or `/boot`) as Read/Write and verifies writable access.
4. Runs OS updates (`apt update && apt full-upgrade -y && apt autoremove`).
5. Re-enables boot write protection in `/etc/fstab` and remounts boot partition as Read-Only.
6. Switches overlay back to Read-Only (`raspi-config nonint do_overlayfs 0`).
7. Reboots back into Read-Only mode and verifies both overlay and boot protection are active.

### 4. PiKVM Maintenance Only (`pikvm_upgrade.yml`)
Automates the maintenance cycle for `192.168.4.66` (Arch Linux ARM):
1. Detects initial mount status of `/` and `/boot` via `findmnt`.
2. Checks system load average against `load_threshold`.
3. Runs official `/usr/bin/pikvm-update --no-reboot` (updates packages, cleans pacman cache, checks `kvmd -m` integrity).
4. If updates applied (exit code 100), reboots node to restore clean Read-Only mode. If already up-to-date (exit code 0), ensures read-only lock via `/usr/bin/ro`.
5. Verifies `/` and `/boot` are mounted `ro` and `kvmd -m` configuration remains valid.

---

## Quick Start

A wrapper script `./run.sh` is provided so you do not need to activate the virtual environment manually.

### 1. Test Connectivity
```bash
./run.sh ping
```

### 2. Upgrade ALL 6 Servers Concurrently (Recommended)
```bash
./run.sh upgrade-all -K
```

### 3. Standard Servers Upgrade Only
```bash
./run.sh upgrade -K
```

### 4. Read-Only Pi Upgrade Only
```bash
./run.sh upgrade-ro -K
```

### 5. PiKVM Upgrade Only
```bash
./run.sh upgrade-pikvm  # Note: -K (sudo) is not needed; connects directly as root
```

### 6. Dry Run (Simulate Changes Without Installing)
```bash
./run.sh upgrade-all --check -K
```

### 7. Update Docker Containers Only (Zero Downtime Pull)
```bash
./run.sh upgrade --tags docker
```

### 8. OS Package Updates Only
```bash
./run.sh upgrade --tags os -K
```

### 9. Snap Package Updates Only
```bash
./run.sh upgrade --tags snap -K
```

### 10. Restart VLC Stream Only
```bash
./run.sh restart-vlc
# Or via tags:
./run.sh upgrade --tags vlc
```

### 11. Backup Only
```bash
./run.sh backup -K
```

### 12. Disk Space Maintenance & Cleanup
```bash
./run.sh cleanup -K                      # Clean disk space across all standard servers
./run.sh cleanup --limit 192.168.4.18 -K # Clean disk space on a specific host
```

### 13. Target a Single Server
```bash
./run.sh upgrade --limit 192.168.4.4 -K
```

### 14. Run Arbitrary Ad-hoc Commands
```bash
./run.sh raw 'uptime'
./run.sh raw 'df -h'
```

---

## Structure

```
.
├── .gitignore
├── ansible.cfg            # Ansible defaults (forks=10, inventory, yaml output, SSH pipelining)
├── inventory.ini          # Server definitions, backup devices, and docker stack lists
├── ping.yml               # Connectivity check playbook
├── backup.yml             # Dedicated backup playbook
├── cleanup.yml            # Disk space cleanup & maintenance playbook
├── upgrade.yml            # Multi-stage upgrade playbook for standard servers
├── readonly_upgrade.yml   # Read-Only Pi automated maintenance cycle
├── pikvm_upgrade.yml      # PiKVM automated maintenance & reboot cycle
├── upgrade_all.yml        # Concurrent master upgrade playbook (strategy: free)
├── tasks/
│   ├── restart_docker_stack.yml # Modular stack restart with load check
│   └── restart_vlc_stream.yml   # Modular persistent VLC fullscreen stream restart
├── requirements.txt       # Python dependencies
├── run.sh                 # Convenience CLI wrapper
└── .venv/                 # Local Python virtual environment (gitignored)
```
