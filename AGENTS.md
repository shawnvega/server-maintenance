# AGENTS.md

## Project Overview
This repository manages automation and configuration for self-hosted home servers natively using Ansible in a project-local Python virtual environment (`.venv`).

### Managed Hosts Quick Reference
| Host | User | OS | Backup Method | Mode | Containers / Workloads |
|---|---|---|---|---|---|
| `192.168.4.4` | `shawn` | Debian (Pi OS) | `rpi-clone` (`/dev/mmcblk0`) | Read/Write | OpenMediaVault (`:80`/`:443`), `glances`, `immich`, `jellyfin`, `syncthing` |
| `192.168.4.5` | `shawn` | Debian (Pi OS) | `rpi-clone` (`/dev/mmcblk0`) | Read/Write | Cockpit (`:9090`), `glances`, `homepage` (`:3001` & `:80`), `immich-ml`, `litellm` (`:4000`), native Caddy, Cockpit systemd automation timers |
| `192.168.4.18` | `shawn` | Debian / Ubuntu | Btrfs RAID 1 (`/var`) | Read/Write (`/` on eMMC, `/var` on Btrfs RAID 1) | `glances`, persistent VLC stream (`snap` vlc) |
| `192.168.4.19` | `shawn` | Fedora (`dnf`) | None | Read/Write | Cockpit (`:9090`), `glances0`, `frigate` (`:8971`), `hermes` (gateway `:9119` + desktop `:6080`) |
| `192.168.4.11` | `shawn` | Debian (Pi OS) | None | **Read-Only (OverlayFS & Boot Protection)** | `pi2beink`, `glances` (`:61208`) |
| `192.168.4.66` | `root` | Arch Linux ARM | None | **Read-Only (Native ext4/vfat ro)** | PiKVM (`kvmd`) |
| `192.168.64.6` | `shawn` | Debian 13 (UTM VM) | None | Read/Write | `openclaw` (Gateway backed by Mac host Ollama) |
| `192.168.64.9` | `shawn` | Debian 13 (UTM VM) | None | Read/Write | `openclaw` (Experimental Gateway backed by Mac host Ollama) |

---

## Core Tooling & Virtual Environment (`.venv`)

This repository isolates Ansible and its dependencies in a project-local virtual environment at `.venv/`.
* **Execution Wrapper**: Always invoke `./run.sh <command>` or `.venv/bin/ansible-playbook`. Never invoke global `ansible` directly.
* **Auto-Provisioning**: `./run.sh` automatically creates `.venv` and installs `requirements.txt` if missing.
* **Manual Activation**: `source .venv/bin/activate` or execute binaries directly (`.venv/bin/ansible-playbook`).
* **Reset Virtual Environment**: `rm -rf .venv && ./run.sh ping`.

---

## Core Guardrails & Invariants for AI Agents

1. **Always use `.venv` or `./run.sh`**: Never execute global system `ansible` or `pip`.
2. **Validate Syntax Before Commits**: Run `.venv/bin/ansible-playbook <playbook.yml> --syntax-check` whenever creating or modifying playbooks.
3. **Respect Safety Checks**: Verify target devices in `inventory.ini` before running destructive or block storage commands (`rpi-clone`).
4. **Preserve `local_tmp` in `ansible.cfg`**: Keep `local_tmp = ./.ansible/tmp` to avoid permission errors with user home directories.
5. **PiKVM Invariants (`192.168.4.66`)**:
   * Runs Arch Linux ARM as `root` (no `sudo` required).
   * Uses `ansible_remote_tmp=/tmp/.ansible` (writes to `tmpfs` because `/root` is read-only).
   * Never run `apt`, `dpkg`, or `raspi-config` on PiKVM. Updates run strictly via `/usr/bin/pikvm-update --no-reboot`.
6. **Cockpit Systemd Automation (`192.168.4.5`)**:
   * Scheduled tasks (`ansible-backup-data`, `ansible-check-btrfs`, `ansible-cleanup`, `ansible-backup-rpi`, `ansible-scrub-btrfs`) run as native systemd timers on Host 5 and are monitored via Cockpit (:9090).
   * Deploy or update them anytime using `./run.sh deploy-automation`. On-demand master upgrades can be started directly in Cockpit via `ansible-upgrade-all.service`.
7. **Hermes Workspace Permissions (`192.168.4.19`)**:
   * Host data directory `/home/shawn/docker/hermes/data` must strictly be mode `0755` (`go-w`) and owned by UID 1000 (`shawn`). Never set `0777` (world-writable), which fails Hermes internal security gates (`unsafe_control_permissions`) and traps the chat TUI in an endless 30s reconnect loop.

---

## Documentation Router

Deep architectural and operational documentation is organized in `docs/`. **Read the relevant document before modifying or troubleshooting that subsystem:**

| Subsystem / Task | Document | Key Topics Covered |
|---|---|---|
| **Cluster Topology & Appliances** | [docs/architecture.md](docs/architecture.md) | Host specs, Hermes stack, OpenClaw UTM VMs, Split-Storage Chromebook, RO comparison |
| **Upgrade Pipelines & Lifecycles** | [docs/pipelines.md](docs/pipelines.md) | `upgrade_all.yml`, `upgrade.yml`, stage gates (scrub, load, reboot), tag execution, Mac upgrades |
| **Btrfs Storage & Scrubs** | [docs/storage-btrfs.md](docs/storage-btrfs.md) | Health checks (`check-btrfs`), scrubs (`scrub-btrfs`), RAID 1 `/var` migration & drive replacement |
| **Read-Only Appliances** | [docs/appliances.md](docs/appliances.md) | OverlayFS Pi (`.11`) RW/RO lifecycle & recovery, Arch PiKVM (`.66`) mounts & `pikvm-update` |
| **Hermes Agent Stack** | [docs/hermes.md](docs/hermes.md) | Gateway/desktop dual-container architecture, LiteLLM/Ollama routes, permissions invariants, STT |
| **Homepage Dashboard** | [docs/homepage.md](docs/homepage.md) | Dashboard architecture, Caddy reverse proxy, Glances widgets, host header rules, Docker socket |
| **Workflows, Caddy & Vault** | [docs/workflows.md](docs/workflows.md) | Native Caddy reload, Cockpit systemd automation, Immich sync, password update, Vault rekey |
| **Troubleshooting & Recovery** | [docs/troubleshooting.md](docs/troubleshooting.md) | Quick incident triage matrix, instant CLI recovery commands, links to deep guides |

---

## Essential Command Cheatsheet

```bash
# Connectivity
./run.sh ping

# Master Concurrent Upgrade (all 6 nodes simultaneously)
./run.sh upgrade-all -K

# Standard Nodes Upgrade (.4, .5, .18, .19)
./run.sh upgrade -K

# Read-Only Pi Maintenance Cycle (.11)
./run.sh upgrade-ro -K

# PiKVM Maintenance (.66, connects as root, no -K needed)
./run.sh upgrade-pikvm

# Local Mac Workstation Maintenance
./run.sh upgrade-mac                     # Standard update
./run.sh upgrade-mac -n                  # Dry run preview

# Btrfs Storage Health & Scrubs
./run.sh check-btrfs                     # Health check across all Btrfs hosts
./run.sh scrub-btrfs                     # Start Btrfs scrub on Pi 5
./run.sh scrub-btrfs --all               # Start Btrfs scrub across all hosts

# Service Maintenance
./run.sh homepage                      # Deploy & update Homepage dashboard (.5)
./run.sh litellm                       # Deploy & update LiteLLM AI Gateway (.5)
./run.sh caddy                           # Validate & reload native Caddy reverse proxy
./run.sh cleanup -K                      # Vacuum journals, clean package caches, prune docker
./run.sh restart-vlc                     # Restart persistent VLC RTSP stream (.18)
./run.sh test-hermes                     # Verify Hermes Gateway, Desktop, TUI grant & LiteLLM
./run.sh setup-whisper                   # Install & verify local Apple Silicon MLX Whisper daemon (.8)
./run.sh check-host5                     # Inspect Host 5 status log
./run.sh upgrade-host5 -K                # Trigger detached standalone upgrade for Host 5
./run.sh backup-data -K                  # Sync Immich DB & data shares to Pi 5
./run.sh deploy-automation               # Deploy systemd timers & services for Cockpit (:9090) on Pi 5

# Ad-hoc Shell & Container Commands
./run.sh raw 'uptime'
./run.sh raw 'df -h'
./run.sh raw 'docker exec -u hermes hermes-gateway /opt/hermes/.venv/bin/hermes profile list' --limit 192.168.4.19
ssh -t shawn@192.168.4.19 'docker exec -it -u hermes hermes-gateway bash'
```
