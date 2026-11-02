# Selfhosted Infrastructure & Automation

Ansible automation for managing home servers natively (load monitoring, `rpi-clone` backups, OS updates, Docker compose services, read-only overlay Pi maintenance, and Arch Linux ARM PiKVM maintenance).

---

## Servers Managed

| Host | User | OS | Backup Method | Containers / Workloads | Mode |
|---|---|---|---|---|---|
| `192.168.4.4` | `shawn` | Debian (Pi OS) | `rpi-clone` (`/dev/mmcblk0`) | `glances`, `immich`, `jellyfin`, `syncthing` | Read/Write |
| `192.168.4.5` | `shawn` | Debian (Pi OS) | `rpi-clone` (`/dev/mmcblk0`) | `glances`, `immich-ml`, `semaphore`, native Caddy | Read/Write |
| `192.168.4.18` | `shawn` | Debian / Ubuntu | Btrfs RAID 1 (`/var`) | `glances`, persistent VLC RTSP stream (`snap` vlc) | Read/Write (`/` on eMMC, `/var` on Btrfs RAID 1) |
| `192.168.4.19` | `shawn` | Fedora (`dnf`) | None | `glances0`, `frigate0`, `hermes` | Read/Write |
| `192.168.4.11` | `shawn` | Debian (Pi OS) | None | `pi2beink` | **Read-Only (OverlayFS & Boot Protection)** |
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

# 9. Validate and reload Caddy reverse proxy (192.168.4.5)
./run.sh caddy

# 10. Reclaim disk space across standard servers (journal vacuum, docker prune)
./run.sh cleanup -K
```

---

## Documentation Deep Dives

Detailed architecture, lifecycle procedures, and troubleshooting guides are organized in the [`docs/`](docs/) directory:

* 🏗️ **[Cluster Architecture & Managed Hosts](docs/architecture.md)**: Hardware layout, network topology, appliance details (Hermes desktop container, OpenClaw UTM VMs, Split-Storage Chromebook, Read-Only comparison).
* 🔄 **[Upgrade Pipelines & Lifecycles](docs/pipelines.md)**: Staged execution flows, safety gates (scrub check, load check, reboot evaluation), and tag-based selective execution.
* 💾 **[Btrfs Storage Architecture & Scrubs](docs/storage-btrfs.md)**: Health checks, pool scrubs, scrub safety gates, `/var` RAID 1 migration, and live drive replacement.
* 🔒 **[Read-Only Appliances](docs/appliances.md)**: Maintenance lifecycles, remount mechanics, and verification for OverlayFS Pi (`.11`) and Arch Linux PiKVM (`.66`).
* ⚙️ **[Specialized Workflows & Services](docs/workflows.md)**: Caddy reverse proxy deployment, Semaphore runner safety, data share/Immich sync, password rotation, Docker secrets, and Ansible Vault rekeying.
* 🛠️ **[Troubleshooting Runbooks](docs/troubleshooting.md)**: Recovery steps for high load halts, `rpi-clone` backup failures, drive degradation, read-only lock failures, and VLC stream freezes.

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
│   ├── workflows.md           # Caddy, Semaphore runner safety, Vault, and password updates
│   └── troubleshooting.md     # Failure mitigation runbooks and emergency recovery
│
├── compose/                   # Docker compose stacks by host (e.g. 192.168.4.19/hermes)
├── files/                     # Static configs (Caddyfile, upgrade_host5.sh, litellm config)
├── tasks/                     # Modular Ansible tasks (caddy, btrfs, docker, vlc, reboot)
└── vars/                      # Encrypted secrets (vault.yml)
```
