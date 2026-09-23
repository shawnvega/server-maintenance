# Selfhosted Infrastructure & Automation

Ansible automation for managing home servers natively (load monitoring, rpi-clone backups, OS updates, Docker compose services, and read-only overlay Pi maintenance).

## Servers Managed

| Host | User | OS | Backup Method | Containers / Workloads | Mode |
|---|---|---|---|---|---|
| `192.168.4.4` | `shawn` | Debian (Pi OS) | `rpi-clone` (`/dev/mmcblk0`) | `glances`, `immich`, `jellyfin`, `syncthing` | Read/Write |
| `192.168.4.5` | `shawn` | Debian (Pi OS) | `rpi-clone` (`/dev/mmcblk0`) | `glances`, `immich-ml` | Read/Write |
| `192.168.4.18` | `shawn` | Debian (Pi OS) | None | `glances` | Read/Write |
| `192.168.4.19` | `shawn` | Fedora (`dnf`) | None | `glances0`, `frigate0` | Read/Write |
| `192.168.4.11` | `shawn` | Debian (Pi OS) | None | `pi2beink` | **Read-Only (OverlayFS)** |

---

## Upgrade Pipelines

### 1. Concurrent Master Upgrade (`upgrade_all.yml`)
Upgrades **all 5 servers simultaneously** using Ansible's `strategy: free`:
* `192.168.4.11` handles its overlay disable & reboot cycle.
* Concurrently, `.4`, `.5`, `.18`, and `.19` run their backups, OS updates, and Docker pulls without waiting for `.11`'s reboot.
* OS upgrades run across all machines in parallel.
* Prompt for sudo password once (`-K`).

### 2. Standard Servers Only (`upgrade.yml`)
Executes natively across standard servers (`.4`, `.5`, `.18`, `.19`) without touching `.11`:
1. **Load Check (`tags: [load_check]`)**: Waits for CPU load average to drop below threshold (`2.0` on `.18`, `4.0` on others).
2. **Backup (`tags: [backup]`)**: Runs `rpi-clone` on `.4` and `.5`.
3. **OS Packages (`tags: [os]`)**: Uses `apt full-upgrade` on Debian hosts and `dnf upgrade` on Fedora.
4. **Docker Stacks (`tags: [docker]`)**: Minimal downtime rolling update (`docker compose pull` while services stay online, then rolling `docker compose up -d` with load checks between each stack).

### 3. Read-Only Pi Maintenance Only (`readonly_upgrade.yml`)
Automates the full maintenance cycle for `192.168.4.11` in isolation:
1. Checks current overlay state (`raspi-config nonint get_overlay_now`).
2. Switches overlay to Read/Write (`raspi-config nonint do_overlayfs 1`).
3. Reboots into Read/Write mode and waits for SSH to return.
4. Runs OS updates (`apt update && apt full-upgrade -y && apt autoremove`).
5. Switches overlay back to Read-Only (`raspi-config nonint do_overlayfs 0`).
6. Reboots back into Read-Only mode and verifies safe RO status.

---

## Quick Start

A wrapper script `./run.sh` is provided so you do not need to activate the virtual environment manually.

### 1. Test Connectivity
```bash
./run.sh ping
```

### 2. Upgrade ALL 5 Servers Concurrently (Recommended)
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

### 5. Dry Run (Simulate Changes Without Installing)
```bash
./run.sh upgrade-all --check -K
```

### 6. Update Docker Containers Only (Zero Downtime Pull)
```bash
./run.sh upgrade --tags docker
```

### 7. OS Package Updates Only
```bash
./run.sh upgrade --tags os -K
```

### 8. Backup Only
```bash
./run.sh backup -K
```

### 9. Disk Space Maintenance & Cleanup
```bash
./run.sh cleanup -K                      # Clean disk space across all standard servers
./run.sh cleanup --limit 192.168.4.18 -K # Clean disk space on a specific host
```

### 10. Target a Single Server
```bash
./run.sh upgrade --limit 192.168.4.4 -K
```

### 11. Run Arbitrary Ad-hoc Commands
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
├── upgrade_all.yml        # Concurrent master upgrade playbook (strategy: free)
├── tasks/
│   └── restart_docker_stack.yml # Modular stack restart with load check
├── requirements.txt       # Python dependencies
├── run.sh                 # Convenience CLI wrapper
└── .venv/                 # Local Python virtual environment (gitignored)
```
