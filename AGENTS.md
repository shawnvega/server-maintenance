# AGENTS.md

## Project Overview
This repository manages automation and configuration for self-hosted home servers natively using Ansible in a project-local Python virtual environment (`.venv`).

### Managed Hosts
| Host | User | OS | Backup Method | Containers / Workloads |
|---|---|---|---|---|
| `192.168.4.4` | `shawn` | Debian (Pi OS) | `rpi-clone` (`/dev/mmcblk0`) | `glances`, `immich`, `jellyfin`, `syncthing` |
| `192.168.4.5` | `shawn` | Debian (Pi OS) | `rpi-clone` (`/dev/mmcblk0`) | `glances`, `immich-ml` |
| `192.168.4.18` | `shawn` | Debian (Pi OS) | None | `glances` |
| `192.168.4.19` | `shawn` | Fedora (`dnf`) | None | `glances0`, `frigate0` |

---

## Environment & Tooling
* **Python Virtual Environment**: `.venv/` at repository root.
* **Dependencies**: Defined in `requirements.txt` (contains `ansible>=9.0.0`).
* **CLI Wrapper**: `./run.sh` wraps `.venv/bin/ansible-playbook` and `ansible`, auto-creating the venv if missing.

---

## Upgrade Pipeline Stages (`upgrade.yml`)
1. **Load Check (`tags: [load_check]`)**: Waits for loadavg to drop below `load_threshold`.
2. **Backup (`tags: [backup]`)**: Runs `rpi-clone` on hosts with `backup_method == 'rpi-clone'`. Halts on error.
3. **OS Upgrades (`tags: [os]`)**: Uses `apt` for Debian/Pi OS and `dnf` for Fedora.
4. **Docker Stacks (`tags: [docker]`)**: Minimal downtime update (`docker compose pull` then `docker compose up -d`).

---

## Common Commands

### Connectivity Check
```bash
./run.sh ping
```

### Full Upgrade Pipeline
```bash
./run.sh upgrade -K
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
* `inventory.ini`: Server definitions, host variables (`backup_method`, `backup_device`, `load_threshold`, `docker_stacks`), and connection parameters.
* `ansible.cfg`: Core Ansible configuration (inventory path, local tmp dir, YAML stdout callback, SSH pipelining).
* `upgrade.yml`: Native multi-stage upgrade playbook.
* `backup.yml`: Dedicated playbook for `rpi-clone` backups.
* `ping.yml`: Quick connectivity verification playbook.
* `run.sh`: Main entrypoint for humans and automation.
* `requirements.txt`: Python package requirements.
* `AGENTS.md` / `CLAUDE.md`: Repository instructions and conventions for AI assistants.
* `.gitignore`: Excludes `.venv/`, `.ansible/`, retry files, and system logs.

### Guidelines for AI Agents
1. **Always use `.venv` or `./run.sh`**: Never invoke global `ansible` directly.
2. **Validate Syntax Before Commits**: Run `.venv/bin/ansible-playbook <playbook> --syntax-check` when creating or modifying playbooks.
3. **Respect Safety Checks**: Verify host variables before running hardware/backup operations like `rpi-clone`.
4. **Preserve `local_tmp` in `ansible.cfg`**: Keep temporary directory pointing to `./.ansible/tmp` to avoid sandbox and permission issues with `/Users/shawn/.ansible`.
