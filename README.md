# Selfhosted Infrastructure & Automation

Ansible automation for managing home servers natively (load monitoring, `rpi-clone` backups, OS updates, Docker compose services, read-only overlay Pi maintenance, and Arch Linux ARM PiKVM maintenance).

---

## Servers Managed

| Host | User | OS | Backup Method | Containers / Workloads | Mode |
|---|---|---|---|---|---|
| `192.168.4.4` | `shawn` | Debian (Pi OS) | `rpi-clone` (`/dev/mmcblk0`) | OpenMediaVault (`:80`/`:443`), `glances`, `immich`, `jellyfin`, `syncthing` | Read/Write |
| `192.168.4.5` | `shawn` | Debian (Pi OS) | `rpi-clone` (`/dev/mmcblk0`) | `glances`, `homepage` (`:3001` & `:80`), `immich-ml`, `litellm` (`:4000`), native Caddy, Cockpit systemd automation timers | Read/Write |
| `192.168.4.18` | `shawn` | Debian / Ubuntu | Btrfs RAID 1 (`/var`) | `glances`, persistent VLC RTSP stream (`snap` vlc) | Read/Write (`/` on eMMC, `/var` on Btrfs RAID 1) |
| `192.168.4.19` | `shawn` | Fedora (`dnf`) | Dual-tier (Local HDD + Pi 5) | Cockpit (`:9090`), `glances0`, `frigate` (`:8971`), `hermes` (`:9119`/`:8642`, optional desktop `:6081`), `open-webui` (`:3000`), host desktop `noVNC` (`:6080`) | Read/Write |
| `192.168.4.11` | `shawn` | Debian (Pi OS) | None | `pi2beink`, `glances` (`:61208`) | **Read-Only (OverlayFS & Boot Protection)** |
| `192.168.4.66` | `root` | Arch Linux ARM | None | PiKVM (`kvmd`) | **Read-Only (Native ext4/vfat ro)** |
| `192.168.64.6` | `shawn` | Debian 13 (UTM VM) | None | `openclaw` (Gateway backed by Mac host Ollama) | Read/Write |
| `192.168.64.9` | `shawn` | Debian 13 (UTM VM) | None | `openclaw` (Experimental Gateway backed by Mac host Ollama) | Read/Write |

---

## Quick Start

A wrapper script `./run.sh` is provided so you do not need to activate the virtual environment manually. It auto-provisions `.venv` and manages vault credentials transparently.

```bash
# 1. Test connectivity across all nodes
./run.sh ping

# 2. Upgrade ALL 6 servers concurrently (Recommended)
./run.sh upgrade-all -K

# 3. Standard servers upgrade only (.4, .5, .18, .19)
./run.sh upgrade -K

# 4. Read-Only Pi upgrade cycle (.11)
./run.sh upgrade-ro -K

# 5. PiKVM upgrade cycle (.66, connects as root; no -K needed)
./run.sh upgrade-pikvm

# 6. Local Mac workstation upgrade (Homebrew, casks, npm, apps, macOS)
./run.sh upgrade-mac

# 7. Check Btrfs filesystem health across all storage nodes
./run.sh check-btrfs

# 8. Start Btrfs background scrub on Pi 5 storage pools
./run.sh scrub-btrfs

# 9. Deploy and update Homepage dashboard (192.168.4.5)
./run.sh homepage

# 10. Deploy and update Open-WebUI AI chat (192.168.4.19)
./run.sh open-webui

# 11. Deploy and update Hermes agent stack (192.168.4.19)
./run.sh hermes

# 12. Deploy and update LiteLLM AI Gateway (192.168.4.5)
./run.sh litellm

# 13. Validate and reload Caddy reverse proxy (192.168.4.5)
./run.sh caddy

# 14. Reclaim disk space across standard servers (journal vacuum, docker prune)
./run.sh cleanup -K
```

---

## Executing Commands Inside Docker Containers

Run one-off commands via `./run.sh raw` or open interactive shells via `ssh -t` (always pass `-u <user>` when writing to bind-mounted volumes):
```bash
./run.sh raw 'docker exec -u hermes hermes-gateway /opt/hermes/.venv/bin/hermes profile list' --limit 192.168.4.19
ssh -t shawn@192.168.4.19 'docker exec -it -u hermes hermes-gateway bash'
```
See [docs/workflows.md](docs/workflows.md#8-executing-commands-inside-docker-containers) for container isolation rules, Immich Postgres examples, and permission invariants.

---

## Documentation Deep Dives

Detailed architecture, lifecycle procedures, and troubleshooting guides are organized in the [`docs/`](docs/) directory:

* 🏗️ **[Cluster Architecture & Managed Hosts](docs/architecture.md)**: Hardware layout, network topology, appliance details (Hermes desktop container, OpenClaw UTM VMs, Split-Storage Chromebook, Read-Only comparison).
* 🔄 **[Upgrade Pipelines & Lifecycles](docs/pipelines.md)**: Staged execution flows, safety gates (scrub check, load check, reboot evaluation), and tag-based selective execution.
* 💾 **[Btrfs Storage Architecture & Scrubs](docs/storage-btrfs.md)**: Health checks, pool scrubs, scrub safety gates, `/var` RAID 1 migration, and live drive replacement.
* 🔒 **[Read-Only Appliances](docs/appliances.md)**: Maintenance lifecycles, remount mechanics, and verification for OverlayFS Pi (`.11`) and Arch Linux PiKVM (`.66`).
* 🤖 **[Hermes Agent Stack](docs/hermes.md)**: Architecture, LiteLLM/Ollama integration, LXTerminal sandboxing, STT/Whisper, and permissions invariants.
* 📊 **[Homepage Dashboard](docs/homepage.md)**: Dashboard layout, Caddy reverse proxy routing, Glances widgets, and Docker socket permissions.
* ⚙️ **[Specialized Workflows & Services](docs/workflows.md)**: Caddy reverse proxy deployment, Cockpit systemd automation, data share/Immich sync, password rotation, Docker secrets, Ansible Vault rekeying, Docker `exec`, and host Wayland VNC.
* 🛠️ **[Incident Triage & Recovery](docs/troubleshooting.md)**: Rapid triage matrix and instant CLI recovery commands across all hosts and workloads.

---

## Repository Structure

```
.
├── AGENTS.md                  # Instructions and core invariants for AI agents (lean index)
├── CLAUDE.md -> AGENTS.md     # Symlink for Claude Code
├── README.md                  # Project overview and quick start dashboard
├── ansible.cfg                # Ansible defaults (forks=10, inventory, yaml output, SSH pipelining)
├── inventory.ini              # Host definitions, backup targets, and Docker stack lists
├── run.sh                     # Main entrypoint wrapper for humans and automation
├── requirements.txt           # Python dependencies (ansible>=9.0.0)
│
├── docs/                      # Dedicated technical documentation
│   ├── architecture.md        # Hardware, hosts, and appliance architectural differences
│   ├── pipelines.md           # Master, standard, ro, pikvm, and mac upgrade lifecycles
│   ├── storage-btrfs.md       # Btrfs health, scrubs, and Chromebook RAID 1 management
│   ├── appliances.md          # Read-Only mechanics for OverlayFS Pi & PiKVM
│   ├── hermes.md              # Hermes AI agent, desktop sandbox, and LiteLLM integration
│   ├── homepage.md            # Homepage dashboard widgets, Caddy ingress, and host header rules
│   ├── workflows.md           # Caddy, Cockpit automation, Vault, password updates, and host VNC
│   └── troubleshooting.md     # Rapid incident triage matrix and emergency runbooks
│
├── compose/                   # Docker compose stacks by host (e.g. 192.168.4.19/hermes)
├── files/                     # Static configs (Caddyfile, upgrade_host5.sh, litellm config)
├── tasks/                     # Modular Ansible tasks (caddy, btrfs, docker, vlc, reboot)
└── vars/                      # Encrypted secrets (vault.yml)
```
