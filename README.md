# Selfhosted Infrastructure & Automation

Ansible automation for managing home servers natively (load monitoring, rpi-clone backups, OS updates, and Docker compose services).

## Servers Managed

| Host | User | OS | Backup Method | Containers / Workloads |
|---|---|---|---|---|
| `192.168.4.4` | `shawn` | Debian (Pi OS) | `rpi-clone` (`/dev/mmcblk0`) | `glances`, `immich`, `jellyfin`, `syncthing` |
| `192.168.4.5` | `shawn` | Debian (Pi OS) | `rpi-clone` (`/dev/mmcblk0`) | `glances`, `immich-ml` |
| `192.168.4.18` | `shawn` | Debian (Pi OS) | None | `glances` |
| `192.168.4.19` | `shawn` | Fedora (`dnf`) | None | `glances0`, `frigate0` |

---

## Upgrade Pipeline Stages

The upgrade playbook (`upgrade.yml`) executes natively in 4 clean stages:
1. **Load Check (`tags: [load_check]`)**: Waits for CPU load average to drop below threshold (`2.0` on `.18`, `4.0` on others).
2. **Backup (`tags: [backup]`)**: Runs `rpi-clone` on `.4` and `.5`. If backup fails, pipeline halts to protect containers.
3. **OS Packages (`tags: [os]`)**: Uses `apt full-upgrade` on Debian hosts and `dnf upgrade` on Fedora.
4. **Docker Stacks (`tags: [docker]`)**: Minimal downtime rolling update (`docker compose pull` while services stay online, then `docker compose up -d`).

---

## Quick Start

A wrapper script `./run.sh` is provided so you do not need to activate the virtual environment manually.

### 1. Test Connectivity
```bash
./run.sh ping
```

### 2. Full Pipeline (Backup + OS + Docker)
```bash
./run.sh upgrade -K
```

### 3. Update Docker Containers Only (Zero Downtime Pull)
```bash
./run.sh upgrade --tags docker
```

### 4. OS Package Updates Only
```bash
./run.sh upgrade --tags os -K
```

### 5. Backup Only
```bash
./run.sh backup -K
```

### 6. Upgrade Without Backup
```bash
./run.sh upgrade --skip-tags backup -K
```

### 7. Target a Single Server
```bash
./run.sh upgrade --limit 192.168.4.4 -K
```

### 8. Run Arbitrary Ad-hoc Commands
```bash
./run.sh raw 'uptime'
./run.sh raw 'df -h'
```

---

## Structure

```
.
├── .gitignore
├── ansible.cfg        # Ansible defaults (inventory, yaml output, SSH pipelining)
├── inventory.ini      # Server definitions, backup devices, and docker stack lists
├── ping.yml           # Connectivity check playbook
├── backup.yml         # Dedicated backup playbook
├── requirements.txt   # Python dependencies
├── run.sh             # Convenience CLI wrapper
├── upgrade.yml        # Native multi-stage upgrade playbook
└── .venv/             # Local Python virtual environment (gitignored)
```
