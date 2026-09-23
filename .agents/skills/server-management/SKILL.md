---
name: server-management
description: >-
  Use this skill when running server upgrades, executing or verifying rpi-clone backups,
  handling Read-Only OverlayFS maintenance cycles on Raspberry Pi, updating Docker compose stacks,
  or troubleshooting homelab hosts.
---

# Homelab Server Management Skill

This skill provides step-by-step operational runbooks and troubleshooting procedures for managing the self-hosted cluster using Ansible in the local `.venv`.

---

## 1. Safety Guardrails & Requirements

* **Always execute commands through `./run.sh` or `.venv/bin/ansible-playbook`**: Never invoke global `ansible` directly.
* **Validate syntax before executing**:
  ```bash
  .venv/bin/ansible-playbook <playbook.yml> --syntax-check
  ```
* **Verify target devices before backups**: Always verify `backup_device` in [inventory.ini](file:///Users/shawn/StudioProjects/selfhosted/inventory.ini) before running `rpi-clone` to prevent data loss.

---

## 2. Operational Procedures

### A. Pre-Flight Connectivity Check
Verify SSH connectivity and privilege escalation readiness before starting maintenance:
```bash
./run.sh ping
```

### B. Standard Servers Upgrade Pipeline
Targets hosts in the `standard_servers` group (`192.168.4.4`, `192.168.4.5`, `192.168.4.18`, `192.168.4.19`).

```bash
# Full pipeline (Load check -> rpi-clone backup -> OS packages -> Docker compose pull & recreate)
./run.sh upgrade -K

# Run on a single host
./run.sh upgrade --limit 192.168.4.4 -K

# Skip backup (e.g., if already backed up recently)
./run.sh upgrade --skip-tags backup -K

# Selective stage execution:
./run.sh upgrade --tags os -K          # OS package upgrades only
./run.sh upgrade --tags docker         # Docker container updates only (no sudo needed)
./run.sh upgrade --tags backup -K      # Pre-upgrade backups only
```

### C. Read-Only Raspberry Pi Maintenance Cycle
Targets `192.168.4.11` running Debian/Pi OS with an active OverlayFS.

```bash
./run.sh upgrade-ro -K
```
**Cycle steps executed by [readonly_upgrade.yml](file:///Users/shawn/StudioProjects/selfhosted/readonly_upgrade.yml)**:
1. Detect overlay status (`raspi-config nonint get_overlay_now`).
2. Switch configuration to Read/Write (`raspi-config nonint do_overlayfs 1`).
3. Reboot and poll until SSH recovers.
4. Verify filesystem is Read/Write (`stdout == '1'`).
5. Wait for system loadavg to drop below `load_threshold`.
6. Upgrade OS packages (`apt update && apt full-upgrade -y && apt autoremove`).
7. Switch configuration back to Read-Only (`raspi-config nonint do_overlayfs 0`).
8. Reboot and poll until SSH recovers.
9. Verify filesystem is safely Read-Only (`stdout == '0'`).

### D. Dedicated Backups (`rpi-clone`)
Run hardware backups to destination SD/NVMe/USB storage:
```bash
# Run backup for all configured hosts (192.168.4.4, 192.168.4.5)
./run.sh backup -K

# Run backup on a specific host
./run.sh backup --limit 192.168.4.4 -K
```

### E. Ad-hoc Diagnostics and Cluster Inspection
Execute commands across all nodes or targeted servers:
```bash
./run.sh raw 'uptime'
./run.sh raw 'df -h'
./run.sh raw 'docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Image}}"'
```

---

## 3. Failure Mitigation & Troubleshooting

### High Loadavg Halting Pipeline
* If Stage 1 fails with a load threshold timeout, inspect running processes:
  ```bash
  ./run.sh raw 'ps aux --sort=-%cpu | head -n 10'
  ```
* If load is temporarily high due to indexing or background tasks, rerun with an override variable:
  ```bash
  ./run.sh upgrade -K -e "load_threshold=8.0"
  ```

### `rpi-clone` Failure
* If `rpi-clone` fails, check if the backup device was dismounted or changed device name:
  ```bash
  ./run.sh raw 'lsblk'
  ```
* Verify the target device specified in `inventory.ini` matches the current block device.

### Read-Only Pi Fails to Return to Read-Only
* If `readonly_upgrade.yml` fails at Step 4, check current status manually:
  ```bash
  ssh shawn@192.168.4.11 'sudo raspi-config nonint get_overlay_now'
  ```
  - Output `0` = Overlay active (Read-Only).
  - Output `1` = Overlay disabled (Read/Write).
* To manually force back into Read-Only mode:
  ```bash
  ssh shawn@192.168.4.11 'sudo raspi-config nonint do_overlayfs 0 && sudo reboot'
  ```

---

## 4. Modern Ansible (v14 / Core 2.21) Playbook Standards

When writing or editing playbooks in this repository:
1. **Fact Access**: Always use `ansible_facts['<name>']` (e.g. `ansible_facts['os_family']`) rather than deprecated bare facts like `ansible_os_family`.
2. **Explicit Returns**: Provide explicit `changed_when:` and `failed_when:` on any `command`, `shell`, or `raw` tasks (implicit `rc` failure inference is deprecated).
3. **Strict Booleans in Conditionals**: Ensure `when:` expressions evaluate strictly to booleans (e.g., `when: backup_method | default('none') == 'rpi-clone'`). Do not embed `{{ }}` templates inside `when:`.
