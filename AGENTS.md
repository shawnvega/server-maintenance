# AGENTS.md

## Project Overview
This repository manages automation and configuration for self-hosted home servers using Ansible in a project-local Python virtual environment (`.venv`).

### Managed Hosts
| Host | User | Role |
|---|---|---|
| `192.168.4.4` | `shawn` | Home server |
| `192.168.4.5` | `shawn` | Home server |
| `192.168.4.18` | `shawn` | Home server |
| `192.168.4.19` | `shawn` | Home server |

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

### Upgrade Playbook
```bash
# Run across all servers concurrently
./run.sh upgrade

# Target a single server
./run.sh upgrade --limit 192.168.4.4

# Prompt for sudo password if required
./run.sh upgrade -K
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
* `inventory.ini`: Server definitions and connection parameters.
* `ansible.cfg`: Core Ansible configuration (inventory path, local tmp dir, YAML stdout callback, SSH pipelining).
* `upgrade.yml`: Playbook that executes `~/bin/upgradeEverything.sh` asynchronously with polling.
* `ping.yml`: Quick connectivity verification playbook.
* `run.sh`: Main entrypoint for humans and automation.
* `requirements.txt`: Python package requirements.
* `.gitignore`: Excludes `.venv/`, `.ansible/`, retry files, and system logs.

### Guidelines for AI Agents
1. **Always use `.venv` or `./run.sh`**: Never invoke global `ansible` directly.
2. **Validate Syntax Before Commits**: Run `.venv/bin/ansible-playbook <playbook> --syntax-check` when creating or modifying playbooks.
3. **Respect Safety Checks**: When writing tasks that execute scripts on remote hosts, verify file existence (`ansible.builtin.stat`) and use reasonable timeouts / async polling.
4. **Preserve `local_tmp` in `ansible.cfg`**: Keep temporary directory pointing to `./.ansible/tmp` to avoid sandbox and permission issues with `/Users/shawn/.ansible`.
