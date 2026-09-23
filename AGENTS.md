# AGENTS.md

## Project Overview
This repository manages automation and configuration for self-hosted home servers natively using Ansible in a project-local Python virtual environment (`.venv`).

### Managed Hosts
| Host | User | OS | Backup Method | Mode | Containers / Workloads |
|---|---|---|---|---|---|
| `192.168.4.4` | `shawn` | Debian (Pi OS) | `rpi-clone` (`/dev/mmcblk0`) | Read/Write | `glances`, `immich`, `jellyfin`, `syncthing` |
| `192.168.4.5` | `shawn` | Debian (Pi OS) | `rpi-clone` (`/dev/mmcblk0`) | Read/Write | `glances`, `immich-ml` |
| `192.168.4.18` | `shawn` | Debian (Pi OS) | None | Read/Write | `glances` |
| `192.168.4.19` | `shawn` | Fedora (`dnf`) | None | Read/Write | `glances0`, `frigate0` |
| `192.168.4.11` | `shawn` | Debian (Pi OS) | None | **Read-Only (OverlayFS)** | `pi2beink` |

---

## Environment & Tooling
* **Python Virtual Environment**: `.venv/` at repository root.
* **Dependencies**: Defined in `requirements.txt` (contains `ansible>=9.0.0`).
* **CLI Wrapper**: `./run.sh` wraps `.venv/bin/ansible-playbook` and `ansible`, auto-creating the venv if missing.

---

## Upgrade Pipeline Stages

### Concurrent All-in-One (`upgrade_all.yml` targeting `servers`)
Uses `strategy: free` and `forks: 10` so all 5 servers run simultaneously:
1. `192.168.4.11` immediately begins its overlay disable & reboot cycle.
2. Simultaneously, standard servers run their load checks, `rpi-clone` backups, and container pulls.
3. OS package upgrades execute across all nodes concurrently.
4. `192.168.4.11` re-enables its overlay and reboots back into Read-Only mode while standard nodes restart Docker stacks.

### Standard Hosts Only (`upgrade.yml` targeting `standard_servers`)
1. **Load Check (`tags: [load_check]`)**: Waits for loadavg to drop below `load_threshold`.
2. **Backup (`tags: [backup]`)**: Runs `rpi-clone` on hosts with `backup_method == 'rpi-clone'`. Halts on error.
3. **OS Upgrades (`tags: [os]`)**: Uses `apt` for Debian/Pi OS and `dnf` for Fedora.
4. **Docker Stacks (`tags: [docker]`)**: Minimal downtime update (`docker compose pull` then rolling `docker compose up -d` with system load checks between each stack restart).

### Read-Only Pi Maintenance Only (`readonly_upgrade.yml` targeting `readonly_servers`)
1. **Detect Overlay**: `raspi-config nonint get_overlay_now`.
2. **Switch to RW**: `raspi-config nonint do_overlayfs 1`.
3. **Reboot**: Waits for host to reboot in RW mode.
4. **Upgrade**: `apt update && apt full-upgrade -y`.
5. **Switch to RO**: `raspi-config nonint do_overlayfs 0`.
6. **Reboot**: Waits for host to reboot back into verified Read-Only mode.

---

## Common Commands

### Connectivity Check
```bash
./run.sh ping
```

### Full Upgrade Pipelines
```bash
# All 5 servers simultaneously (strategy: free)
./run.sh upgrade-all -K

# Standard servers only (192.168.4.4, 4.5, 4.18, 4.19)
./run.sh upgrade -K

# Read-only server maintenance cycle only (192.168.4.11)
./run.sh upgrade-ro -K
```

### Selective Execution via Tags
```bash
./run.sh upgrade --tags docker            # Only update containers
./run.sh upgrade --tags os -K             # Only OS package upgrades
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

## File Structure & Conventions
* `inventory.ini`: Server definitions, host variables (`backup_method`, `backup_device`, `load_threshold`, `docker_stacks`), and groups (`standard_servers`, `readonly_servers`).
* `ansible.cfg`: Core Ansible configuration (forks=10, inventory path, local tmp dir, YAML stdout callback, SSH pipelining).
* `upgrade_all.yml`: Master concurrent upgrade playbook for all 5 servers.
* `upgrade.yml`: Native multi-stage upgrade playbook for standard servers.
* `cleanup.yml`: Automated disk space cleanup playbook (journal capping/vacuum, package cache clean, docker prune).
* `readonly_upgrade.yml`: Automated maintenance playbook for overlayfs read-only Raspberry Pi.
* `backup.yml`: Dedicated playbook for `rpi-clone` backups.
* `ping.yml`: Quick connectivity verification playbook.
* `tasks/restart_docker_stack.yml`: Modular task for restarting a docker stack with pre-restart system load verification.
* `run.sh`: Main entrypoint for humans and automation.
* `requirements.txt`: Python package requirements.
* `AGENTS.md` / `CLAUDE.md`: Repository instructions and conventions for AI assistants.
* `.gitignore`: Excludes `.venv/`, `.ansible/`, retry files, and system logs.

### Guidelines for AI Agents
1. **Always use `.venv` or `./run.sh`**: Never invoke global `ansible` directly.
2. **Validate Syntax Before Commits**: Run `.venv/bin/ansible-playbook <playbook> --syntax-check` when creating or modifying playbooks.
3. **Respect Safety Checks**: Verify host variables before running hardware/backup operations like `rpi-clone`.
4. **Preserve `local_tmp` in `ansible.cfg`**: Keep temporary directory pointing to `./.ansible/tmp` to avoid sandbox and permission issues with `/Users/shawn/.ansible`.
