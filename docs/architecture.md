# Cluster Architecture & Managed Hosts

This document details the hardware, network topology, operating systems, storage layouts, and specialized appliance architectures across the homelab cluster.

---

## Managed Hosts Overview

| Host | User | OS | Backup Method | Mode | Containers / Workloads |
|---|---|---|---|---|---|
| `192.168.4.4` | `shawn` | Debian (Pi OS) | `rpi-clone` (`/dev/mmcblk0`) | Read/Write | `glances`, `immich`, `jellyfin`, `syncthing` |
| `192.168.4.5` | `shawn` | Debian (Pi OS) | `rpi-clone` (`/dev/mmcblk0`) | Read/Write | `glances`, `homepage` (`:3001` & `:80`), `immich-ml`, `semaphore` (`:3000`, LAN only), native Caddy reverse proxy |
| `192.168.4.18` | `shawn` | Debian / Ubuntu | Btrfs RAID 1 (`/var`) | Read/Write (`/` on eMMC, `/var` on Btrfs RAID 1) | `glances`, persistent VLC RTSP stream (`snap` vlc) |
| `192.168.4.19` | `shawn` | Fedora (`dnf`) | None | Read/Write | `glances0`, `frigate0`, `hermes` (gateway `:9119` + desktop `:6080`) |
| `192.168.4.11` | `shawn` | Debian (Pi OS) | None | **Read-Only (OverlayFS & Boot Protection)** | `pi2beink` |
| `192.168.4.66` | `root` | Arch Linux ARM | None | **Read-Only (Native ext4/vfat ro)** | PiKVM (`kvmd`) |
| `192.168.64.6` | `shawn` | Debian 13 (UTM VM) | None | Read/Write | `openclaw` (Gateway backed by Mac host Ollama) |
| `192.168.64.9` | `shawn` | Debian 13 (UTM VM) | None | Read/Write | `openclaw` (Experimental Gateway backed by Mac host Ollama) |

---

## Appliance & Storage Architectures

### 1. Hermes Dual-Container Stack (`192.168.4.19`)
* **Host Environment**: Fedora Linux (uses `dnf`), co-located with Frigate NVR.
* **Architecture**:
  * `hermes-gateway` (`nousresearch/hermes-agent:latest`): Authenticated REST/WebSocket agent runtime and dashboard on port `9119` (`http://192.168.4.19:9119`). Connects to local Ollama on the host Mac (`192.168.4.8:4000`) via LiteLLM proxy with Bearer token authentication.
  * `hermes-desktop` (`hermes-desktop:minimal`): Sandboxed X11 / Openbox / noVNC virtual desktop on port `6080` (`http://192.168.4.19:6080`), pre-configured with LXTerminal, Chromium (`--no-sandbox`), and ObConf.
  * **Workspace Storage & Permissions**: `/home/shawn/docker/hermes/data` mounted to `/opt/data` (gateway) and `/home/hermes/workspace` (desktop). Must strictly be mode `0755` (`go-w`) owned by UID 1000; mode `0777` trips Hermes POSIX security validation (`unsafe_control_permissions`).
  * **Model Resolution**: Runtime default model is managed in `/home/shawn/docker/hermes/data/config.yaml` (`model.default: coding-26b`, `provider: custom`) routed to Mac host LiteLLM (`http://192.168.4.8:4000/v1`).
* **Configuration**: Managed under `compose/192.168.4.19/hermes/` and documented in [.agents/skills/setup-hermes/SKILL.md](../.agents/skills/setup-hermes/SKILL.md).

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
* **Host Environment**: Raspberry Pi 5 running native Caddy reverse proxy and Docker compose stacks.
* **Architecture**:
  * `homepage` (`ghcr.io/gethomepage/homepage:latest`): Centralized homelab command dashboard providing real-time widgets, Glances metrics across nodes, Docker container state tracking, and direct bookmarks.
  * **Network Ports & Ingress**:
    * Direct container port: `http://192.168.4.5:3001`
    * Caddy native reverse proxy: Ingress on port 80 (`http://192.168.4.5`) automatically proxies to Homepage at `127.0.0.1:3001`.
  * **Permissions & Group Access**: Runs as `PUID=1000` (`shawn`) and `PGID=990` (`docker` group) to grant read-only access to `/var/run/docker.sock` for live container health badges.
  * **Configuration Source of Truth**: Managed under `compose/192.168.4.5/homepage/config/` (`services.yaml`, `widgets.yaml`, `bookmarks.yaml`, `docker.yaml`, `settings.yaml`). Deployed and reloaded via `./run.sh homepage`.

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
