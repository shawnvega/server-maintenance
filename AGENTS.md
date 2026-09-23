# AGENTS.md

## Project Overview
This repository manages automation and configuration for self-hosted home servers using Ansible in a project-local Python virtual environment (`.venv`).

### Managed Hosts
| Host | User | OS | Backup Method | Role |
|---|---|---|---|---|
| `192.168.4.4` | `shawn` | Debian (Pi OS) | `rpi-clone` (`/dev/mmcblk0`) | Home server (glances, immich, jellyfin, syncthing) |
| `192.168.4.5` | `shawn` | Debian (Pi OS) | `rpi-clone` (`/dev/mmcblk0`) | Home server (glances, etc.) |
| `192.168.4.18` | `shawn` | Debian (Pi OS) | None | Home server (glances, etc.) |
| `192.168.4.19` | `shawn` | Fedora (`dnf`) | None | Home server (glances0, etc.) |

---

## Environment & Tooling
* **Python Virtual Environment**: `.venv/` at repository root.
* **Dependencies**: Defined in `requirements.txt` (contains `ansible>=9.0.0`).
* **CLI Wrapper**: `./run.sh` wraps `.venv/bin/ansible-playbook` and `ansible`, auto-creating the venv if missing.

---

## Common Commands

### Connectivity Check
```bash
./run.sh ping
```

### Backup Only
```bash
./run.sh backup -K
```

### Upgrade Playbook (with Backup Tag)
```bash
# Run backup + upgrade across servers
./run.sh upgrade -K

# Run upgrade without backup
./run.sh upgrade --skip-tags backup

# Target a single server
./run.sh upgrade --limit 192.168.4.4 -K
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
* `inventory.ini`: Server definitions, host variables (`backup_method`, `backup_device`), and connection parameters.
* `ansible.cfg`: Core Ansible configuration (inventory path, local tmp dir, YAML stdout callback, SSH pipelining).
* `backup.yml`: Dedicated playbook for `rpi-clone` backups.
* `upgrade.yml`: Playbook that executes pre-upgrade backups and `~/bin/upgradeEverything.sh` asynchronously with polling.
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
