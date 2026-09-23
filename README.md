# Selfhosted Infrastructure & Automation

Ansible automation for managing home servers.

## Servers Managed

| Host | Description |
|---|---|
| `192.168.4.4` | Home server |
| `192.168.4.5` | Home server |
| `192.168.4.18` | Home server |
| `192.168.4.19` | Home server |

User: `shawn`

---

## Quick Start

A wrapper script `./run.sh` is provided so you do not need to activate the virtual environment manually.

### 1. Test Connectivity
Test SSH ping across all 4 servers:
```bash
./run.sh ping
```

### 2. Run Upgrade Across All Servers
Runs `source ~/bin/upgradeEverything.sh` in parallel on all servers:
```bash
./run.sh upgrade
```

### 3. Target a Single Server (e.g. for testing)
```bash
./run.sh upgrade --limit 192.168.4.4
```

### 4. Run with Sudo Password Prompt
If your upgrade script requires `sudo` privileges:
```bash
./run.sh upgrade -K
```

### 5. Run Arbitrary Ad-hoc Commands
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
ansible-playbook upgrade.yml
```

## Structure

```
.
├── .gitignore
├── ansible.cfg        # Ansible defaults (inventory, yaml output, SSH pipelining)
├── inventory.ini      # Server hosts & connection variables
├── ping.yml           # Connectivity check playbook
├── requirements.txt   # Python dependencies
├── run.sh             # Convenience CLI wrapper
├── upgrade.yml        # Main upgrade playbook
└── .venv/             # Local Python virtual environment (gitignored)
```
