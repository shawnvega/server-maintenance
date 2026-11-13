# Cluster Architecture & Managed Hosts

This document details the hardware, network topology, operating systems, storage layouts, and specialized appliance architectures across the homelab cluster.

---

## Managed Hosts Overview

| Host | User | OS | Backup Method | Mode | Containers / Workloads |
|---|---|---|---|---|---|
| `192.168.4.4` | `shawn` | Debian (Pi OS) | `rpi-clone` (`/dev/mmcblk0`) | Read/Write | OpenMediaVault (`:80`/`:443`), `glances`, `immich`, `jellyfin`, `syncthing` |
| `192.168.4.5` | `shawn` | Debian (Pi OS) | `rpi-clone` (`/dev/mmcblk0`) | Read/Write | Cockpit (`:9090`), `glances`, `homepage` (`:3001` & `:80`), `immich-ml`, `litellm` (`:4000`), native Caddy, Cockpit systemd automation timers |
| `192.168.4.18` | `shawn` | Debian / Ubuntu | Btrfs RAID 1 (`/var`) | Read/Write (`/` on eMMC, `/var` on Btrfs RAID 1) | `glances`, persistent VLC RTSP stream (`snap` vlc) |
| `192.168.4.19` | `shawn` | Fedora (`dnf`) | Dual-tier (Local HDD + Pi 5) | Read/Write | Cockpit (`:9090`), `glances0`, `frigate` (`:8971`), `hermes` (gateway `:9119`, API `:8642`, optional desktop `:6081`), `open-webui` (`:3000`), `wayvnc` / `noVNC` (`:5900`/`:6080`, `1500x1000` @ 2x) |
| `192.168.4.11` | `shawn` | Debian (Pi OS) | None | **Read-Only (OverlayFS & Boot Protection)** | `pi2beink`, `glances` (`:61208`) |
| `192.168.4.66` | `root` | Arch Linux ARM | None | **Read-Only (Native ext4/vfat ro)** | PiKVM (`kvmd`) |
| `192.168.64.6` | `shawn` | Debian 13 (UTM VM) | None | Read/Write | `openclaw` (Gateway backed by Mac host Ollama) |
| `192.168.64.9` | `shawn` | Debian 13 (UTM VM) | None | Read/Write | `openclaw` (Experimental Gateway backed by Mac host Ollama) |

---

## Appliance & Storage Architectures

### 1. Hermes & AI Stack (`192.168.4.19`, `192.168.4.5`, `192.168.4.8`)
* **Host Environment**: Fedora Linux (`192.168.4.19`, co-located with Frigate NVR) runs `hermes-gateway` (`:9119` Web/WS, `:8642` OpenAI API), optional `hermes-desktop` (`:6081` noVNC sandbox), and `open-webui` (`:3000`).
* **Inference & STT Routing**: Requests route through the central LiteLLM proxy on Pi 5 (`192.168.4.5:4000`) supporting a hybrid multi-tier failover cascade: primary OpenRouter cloud routes (`openrouter-free`, `gemma4-26b-free`, `google/gemma-4-26b-a4b-it`) fail over to local Apple Silicon Ollama (`192.168.4.8:11434`), and all routes ultimately fail over to universal cloud backup `google/gemma-4-31b-it`. Audio transcription routes to local Mac MLX Whisper (`192.168.4.8:8080`).
* **Deep Reference**: See [hermes.md](hermes.md) for container limits, permissions invariants, model/STT routing, and backup/DR runbooks.

### 2. OpenClaw UTM VMs (`192.168.64.6`, `192.168.64.9`)
* **Host Environment**: Debian 13 ARM64 virtual machines hosted natively on macOS using UTM.
* **Purpose**: Hosts autonomous AI gateway services connecting to local Ollama instances running on the host Mac (`192.168.64.1:11434`).
* **Configuration**: Documented in [.agents/skills/openclaw-setup/SKILL.md](../.agents/skills/openclaw-setup/SKILL.md).

### 3. Split-Storage Btrfs RAID 1 Chromebook (`192.168.4.18`)
* **Storage Distribution**:
  * Internal eMMC (`/dev/mmcblk1`): Fast storage for `/boot/efi`, root `/` (`/usr`, `/etc`, `/home`), and `/swapfile`.
  * RAM (`tmpfs`): Fast volatile storage mounted at `/tmp`.
  * External 3-Device Btrfs Pool: Dedicated Btrfs RAID 1 (`-d raid1 -m raid1`, `compress=zstd:3,noatime,nofail`) mounted on `/var` across `/dev/sda` (7.6 GB USB microSD reader), `/dev/sdb` (7.5 GB USB thumb drive), and `/dev/sdc` (59.5 GB SD card).
* **Automation**: Partitioning, formatting, data migration, and fstab updates are automated via `migrate_var_btrfs.yml`. See [storage-btrfs.md](storage-btrfs.md) for details.

### 4. Homepage Dashboard & Reverse Proxy (`192.168.4.5`)
* **Ingress**: Native Caddy terminates port `80` (`http://192.168.4.5`) and proxies to Homepage (`127.0.0.1:3001`), providing tiles and Glances metrics for Core Infrastructure, Automation & AI, Media & Storage, and Monitoring.
* **Deep Reference**: See [homepage.md](homepage.md) for config schemas, Docker socket permissions, and troubleshooting, and [workflows.md](workflows.md#1-native-caddy-reverse-proxy-19216845) for Caddy routing.

### 5. Read-Only Comparison: OverlayFS Pi vs Native PiKVM

The cluster operates two distinct read-only appliance implementations with different operational lifecycles:

| Attribute | OverlayFS Pi (`192.168.4.11`) | PiKVM (`192.168.4.66`) |
|---|---|---|
| **OS** | Debian / Raspberry Pi OS | Arch Linux ARM |
| **User Account** | `shawn` (uses sudo `-K`) | `root` (direct SSH key) |
| **Ansible Remote Tmp** | Standard / default | `ansible_remote_tmp=/tmp/.ansible` (writes to `tmpfs`) |
| **Read-Only Mechanism** | Kernel OverlayFS (writes redirected to RAM tmpfs) + `/boot` ro | Native ext4 root `/` and `/boot` mounted `ro` via kernel cmdline & fstab |
| **Remount Controls** | `raspi-config nonint do_overlayfs 0\|1` | `/usr/bin/rw`, `/usr/bin/ro` |
| **Upgrade Mechanism** | Disable overlay -> Reboot -> `apt` -> Enable overlay -> Reboot | `/usr/bin/pikvm-update --no-reboot` -> Reboot if updated |
| **Verification** | `raspi-config nonint get_overlay_now` (0=RO) | `findmnt -n -o OPTIONS /` (ro) & `kvmd -m` integrity |

For deep operational runbooks, see [appliances.md](appliances.md).

---

## Inventory & Grouping Conventions

Inventory configuration is centralized in `inventory.ini`:
* `standard_servers`: `192.168.4.4`, `192.168.4.5`, `192.168.4.18`, `192.168.4.19`
* `readonly_servers`: `192.168.4.11`
* `pikvm_servers`: `192.168.4.66`
* `btrfs_storage_servers`: `192.168.4.4`, `192.168.4.5`
* `btrfs_servers`: `192.168.4.4`, `192.168.4.5`, `192.168.4.18`, `192.168.4.19`
* `servers:children`: Combines `standard_servers`, `readonly_servers`, and `pikvm_servers` for master concurrent pipelines.
