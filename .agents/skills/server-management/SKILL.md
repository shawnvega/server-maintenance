---
name: server-management
description: >-
  Use this skill when running server upgrades, executing or verifying rpi-clone backups,
  handling Read-Only OverlayFS maintenance cycles on Raspberry Pi, updating Docker compose stacks,
  managing Cockpit systemd automation, or troubleshooting homelab hosts.
---

# Homelab Server Management Skill

Operational runbooks and safety guardrails for managing the self-hosted cluster using Ansible in the local `.venv`.

---

## Quick Triage Decision Matrix

| Symptom / Error | Root Cause | Instant Resolution |
|---|---|---|
| Stage 1 halts on loadavg threshold | Background indexing/scrubbing active | Inspect `./run.sh raw 'ps aux --sort=-%cpu \| head -n 10'` or override `./run.sh upgrade -K -e "load_threshold=8.0"` |
| `rpi-clone` fails on `.4` or `.5` | Backup device unmounted or changed letter | Check `./run.sh raw 'lsblk'` and verify `backup_device` in [inventory.ini](../../../inventory.ini) |
| `.11` Read-Only Pi stuck in RW mode | `readonly_upgrade.yml` aborted mid-run | Check `ssh shawn@192.168.4.11 'sudo raspi-config nonint get_overlay_now'` (`0`=RO, `1`=RW); restore with `do_overlayfs 0 && sudo reboot` |
| `Failed to create temporary directory` on `/tmp/.ansible` | Play-level `become: true` left `/tmp/.ansible` root-owned | Remove root-owned `/tmp/.ansible` on target and scope `become: true` to individual tasks only |
| Fedora VNC gray screen (`192.168.4.19`) | `miriway-shell` lacks `ImageCopyCaptureManagerV1` | Use `compositor=labwc` in `~/.config/lxqt/session.conf` with pre-created `~/.config/lxqt/labwc/autostart` |

---

## 1. Safety Guardrails & Requirements

* **Always use `./run.sh` or `.venv/bin/ansible-playbook`**: Never invoke global `ansible` directly.
* **Validate syntax before committing or running**:
  ```bash
  .venv/bin/ansible-playbook <playbook.yml> --syntax-check
  ```
* **Verify `backup_device`** in [inventory.ini](../../../inventory.ini) before running `rpi-clone` to prevent data loss.
* **Privilege Scoping with `remote_tmp`**: Never set `become: true` at the play level on playbooks using `copy`/`template`; pre-create `/tmp/.ansible` (`0700`) as the SSH user and apply `become: true` only on root tasks.

---

## 2. Operational Procedures

### A. Pre-Flight & Ad-Hoc Diagnostics
```bash
./run.sh ping
./run.sh raw 'uptime'
./run.sh raw 'df -h'
./run.sh raw 'docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Image}}"'
```

### B. Upgrade Pipelines
```bash
# Master concurrent upgrade (all 6 nodes simultaneously)
./run.sh upgrade-all -K

# Standard servers (.4, .5, .18, .19)
./run.sh upgrade -K
./run.sh upgrade --limit 192.168.4.18 -K
./run.sh upgrade --skip-tags backup -K
./run.sh upgrade -K -e "ignore_btrfs_scrub=true"   # Override active Btrfs scrub skip

# Selective stage tags: os, snap, docker, vlc, backup, reboot
./run.sh upgrade --tags docker                     # Docker updates only (no sudo)

# Read-Only Pi (.11 OverlayFS) & Arch PiKVM (.66)
./run.sh upgrade-ro -K
./run.sh upgrade-pikvm                             # Connects as root, no -K needed

# Local Mac workstation
./run.sh upgrade-mac
./run.sh upgrade-mac -n                            # Dry run preview
```

### C. Backups & Btrfs Storage
```bash
./run.sh backup -K                                 # rpi-clone block backup (.4, .5)
./run.sh backup-data -K                            # Immich DB & data share sync (.4 -> .5)

./run.sh check-btrfs                               # Health check across .4, .5, .18, .19
./run.sh check-btrfs --limit 192.168.4.18          # Btrfs RAID 1 /var on .18
./run.sh scrub-btrfs                               # Start scrub on Pi 5 (.5)
./run.sh scrub-btrfs --all                         # Start scrub across all Btrfs hosts
```

### D. Host 5 (`192.168.4.5`) Standalone Maintenance & Cockpit Automation
Scheduled tasks (`ansible-backup-data`, `ansible-check-btrfs`, `ansible-cleanup`, `ansible-backup-rpi`, `ansible-scrub-btrfs`) run as native systemd timers on Pi 5 and are monitored via **Cockpit (`:9090`)**. On-demand master upgrades can be triggered in Cockpit via `ansible-upgrade-all.service`.
```bash
./run.sh deploy-automation                         # Deploy/update Cockpit systemd timers & services
./run.sh check-host5                               # Inspect ~/logs/upgrade_host5.status
./run.sh deploy-host5 -K                           # Deploy standalone upgrade_host5.sh + live-restore
./run.sh upgrade-host5 -K                          # Trigger detached standalone upgrade on .5
```

---

## 3. Modern Ansible (v14 / Core 2.21) Standards

1. **Fact Access**: Use `ansible_facts['<name>']` (e.g., `ansible_facts['os_family']`) instead of deprecated bare `ansible_*` facts.
2. **Explicit Returns**: Set explicit `changed_when:` and `failed_when:` on `command`, `shell`, and `raw` tasks.
3. **Strict Booleans**: Ensure `when:` expressions evaluate strictly to booleans without `{{ }}` templates.

---

## 4. Documentation Router

| Document | Topics Covered |
|---|---|
| [docs/architecture.md](../../../docs/architecture.md) | Host specs, cluster topology, split-storage Chromebook |
| [docs/pipelines.md](../../../docs/pipelines.md) | `upgrade_all.yml`, `upgrade.yml` stage gates, tag execution |
| [docs/storage-btrfs.md](../../../docs/storage-btrfs.md) | Btrfs health checks, scrubs, RAID 1 `/var` maintenance |
| [docs/appliances.md](../../../docs/appliances.md) | OverlayFS Pi (`.11`) & Arch PiKVM (`.66`) internals |
| [docs/workflows.md](../../../docs/workflows.md) | Cockpit systemd timers, Caddy reload, Vault rekey |
| [docs/troubleshooting.md](../../../docs/troubleshooting.md) | Incident triage matrix & CLI recovery commands |
