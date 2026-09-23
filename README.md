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

### Standard Servers (`upgrade.yml`)
Executes natively across standard servers in 4 clean stages:
1. **Load Check (`tags: [load_check]`)**: Waits for CPU load average to drop below threshold (`2.0` on `.18`, `4.0` on others).
2. **Backup (`tags: [backup]`)**: Runs `rpi-clone` on `.4` and `.5`. If backup fails, pipeline halts to protect containers.
3. **OS Packages (`tags: [os]`)**: Uses `apt full-upgrade` on Debian hosts and `dnf upgrade` on Fedora.
4. **Docker Stacks (`tags: [docker]`)**: Minimal downtime rolling update (`docker compose pull` while services stay online, then `docker compose up -d`).

### Read-Only Pi Maintenance (`readonly_upgrade.yml`)
Automates the full maintenance cycle for `192.168.4.11`:
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

### 2. Standard Servers Upgrade (Backup + OS + Docker)
```bash
./run.sh upgrade -K
```

### 3. Read-Only Pi Upgrade (RW -> Reboot -> Upgrade -> RO -> Reboot)
```bash
./run.sh upgrade-ro -K
```

### 4. Update Docker Containers Only (Zero Downtime Pull)
```bash
./run.sh upgrade --tags docker
```

### 5. OS Package Updates Only
```bash
./run.sh upgrade --tags os -K
```

### 6. Backup Only
```bash
./run.sh backup -K
```

### 7. Upgrade Without Backup
```bash
./run.sh upgrade --skip-tags backup -K
```

### 8. Target a Single Server
```bash
./run.sh upgrade --limit 192.168.4.4 -K
```

### 9. Run Arbitrary Ad-hoc Commands
```bash
./run.sh raw 'uptime'
./run.sh raw 'df -h'
```

---

## Structure

```
.
├── .gitignore
├── ansible.cfg            # Ansible defaults (inventory, yaml output, SSH pipelining)
├── inventory.ini          # Server definitions, backup devices, and docker stack lists
├── ping.yml               # Connectivity check playbook
├── backup.yml             # Dedicated backup playbook
├── upgrade.yml            # Multi-stage upgrade playbook for standard servers
├── readonly_upgrade.yml   # Read-Only Pi automated maintenance cycle
├── requirements.txt       # Python dependencies
├── run.sh                 # Convenience CLI wrapper
└── .venv/                 # Local Python virtual environment (gitignored)
```
