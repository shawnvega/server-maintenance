# Selfhosted Infrastructure & Automation

Ansible automation for managing home servers.

## Servers Managed

| Host | User | OS | Backup Method |
|---|---|---|---|
| `192.168.4.4` | `shawn` | Debian (Pi OS) | `rpi-clone` (`/dev/mmcblk0`) |
| `192.168.4.5` | `shawn` | Debian (Pi OS) | `rpi-clone` (`/dev/mmcblk0`) |
| `192.168.4.18` | `shawn` | Debian (Pi OS) | None |
| `192.168.4.19` | `shawn` | Fedora (`dnf`) | None |

---

## Quick Start

A wrapper script `./run.sh` is provided so you do not need to activate the virtual environment manually.

### 1. Test Connectivity
Test SSH ping across all 4 servers:
```bash
./run.sh ping
```

### 2. Backup Only
Run `rpi-clone` only on the servers that have backups configured:
```bash
./run.sh backup -K
```

### 3. Run Full Pipeline (Backup + Upgrade)
Runs pre-upgrade backup first, then runs upgrade across all servers:
```bash
./run.sh upgrade -K
```

### 4. Upgrade Without Backup
Skip the backup stage and immediately run upgrades:
```bash
./run.sh upgrade --skip-tags backup
```

### 5. Target a Single Server
```bash
./run.sh upgrade --limit 192.168.4.4 -K
```

### 6. Run Arbitrary Ad-hoc Commands
```bash
./run.sh raw 'uptime'
./run.sh raw 'df -h'
```

---

## Manual Ansible Usage (Direct Venv)

If you prefer activating the virtual environment directly:

```bash
source .venv/bin/activate
ansible-playbook ping.yml
ansible-playbook backup.yml -K
ansible-playbook upgrade.yml -K
```

## Structure

```
.
├── .gitignore
├── ansible.cfg        # Ansible defaults (inventory, yaml output, SSH pipelining)
├── inventory.ini      # Server hosts & backup variables
├── ping.yml           # Connectivity check playbook
├── backup.yml         # Dedicated backup playbook
├── requirements.txt   # Python dependencies
├── run.sh             # Convenience CLI wrapper
├── upgrade.yml        # Main upgrade playbook (with pre-upgrade backup tag)
└── .venv/             # Local Python virtual environment (gitignored)
```
