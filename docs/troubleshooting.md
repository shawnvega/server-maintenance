# Homelab Incident Triage & Quick Recovery Runbooks

This document provides a rapid incident triage matrix and instant CLI recovery commands for common failures across the homelab cluster. For comprehensive architecture and configuration details, follow the links to dedicated subsystem documentation.

---

## Quick Triage Decision Matrix

| Subsystem / Symptom | Root Cause | Instant CLI Fix / Override | Full Runbook |
|---|---|---|---|
| **Pipeline halted on load check** | Load avg > threshold during batch job | `./run.sh upgrade -K -e "load_threshold=8.0"` or `--skip-tags load_check` | [docs/pipelines.md](pipelines.md#1-high-system-load-halts-upgrade-pipeline) |
| **`rpi-clone` backup failure** | Block device missing or renamed | `./run.sh upgrade -K --skip-tags backup` | [docs/pipelines.md](pipelines.md#2-rpi-clone-backup-failures) |
| **OverlayFS Pi stuck in RW (`.11`)** | Maintenance cycle interrupted | `ssh shawn@192.168.4.11 'sudo raspi-config nonint enable_bootro && sudo raspi-config nonint do_overlayfs 0 && sudo reboot'` | [docs/appliances.md](appliances.md#manual-emergency-recovery) |
| **PiKVM stuck in RW (`.66`)** | Filesystem unlocked | `ssh root@192.168.4.66 '/usr/bin/ro'` (or `reboot`) | [docs/appliances.md](appliances.md#manual-emergency-recovery-1) |
| **PiKVM KVMD verification error** | Configuration error or interrupted update | `ssh root@192.168.4.66 'kvmd -m'` *(do NOT reboot)* | [docs/appliances.md](appliances.md#kvmd-service-integrity-recovery-kvmd--m) |
| **Btrfs RAID 1 drive error (`.18`)** | Failing disk device | `ssh shawn@192.168.4.18 'sudo btrfs replace start <src_dev> <new_dev> /var'` | [docs/storage-btrfs.md](storage-btrfs.md#drive-replacement-procedure) |
| **Hermes 30s reconnect loop (`.19`)** | `/opt/data` is world-writable (`0777`) | `ssh shawn@192.168.4.19 'chmod 755 /home/shawn/docker/hermes/data'` | [docs/hermes.md](hermes.md#2-security--workspace-permissions-invariant) |
| **Hermes wrong model / endpoint** | Reads `/opt/data/config.yaml` | `ssh shawn@192.168.4.19 "docker exec hermes-gateway /opt/hermes/.venv/bin/hermes config set model.default coding-26b"` | [docs/hermes.md](hermes.md#default-model-resolution-configyaml) |
| **Homepage HTTP 400 Bad Request** | Next.js host header protection | Add host IP/domain to `HOMEPAGE_ALLOWED_HOSTS` in `compose.yml` | [docs/homepage.md](homepage.md#1-host-validation-failed-400-bad-request) |
| **Homepage Docker socket error** | GID mismatch (`EACCES`) | Set `PGID=990` in `compose.yml` (`docker` group on Pi OS) | [docs/homepage.md](homepage.md#4-docker-socket-permission-denied-eacces-varrundockersock) |
| **Frozen VLC RTSP stream (`.18`)** | Crashed media process or display sleep | `./run.sh restart-vlc` | [docs/pipelines.md](pipelines.md#3-vlc-rtsp-video-stream-recovery-192168418) |

---

## 1. Upgrades & Pipelines
* **High Load**: Inspect top CPU consumers with `./run.sh raw 'ps aux --sort=-%cpu | head -n 10'`. Bypass with `./run.sh upgrade -K --skip-tags load_check`.
* **Backup Errors**: Verify connected disks with `./run.sh raw 'lsblk'`. Bypass with `./run.sh upgrade -K --skip-tags backup`.
* *Deep Reference*: [docs/pipelines.md](pipelines.md#pipeline-troubleshooting--overrides)

## 2. Storage & Appliances
* **Btrfs Degradation**: Inspect health with `./run.sh check-btrfs` or `ssh shawn@192.168.4.18 'sudo btrfs device stats /var'`.
* **Read-Only Lock Verification**:
  * Pi 11: `ssh shawn@192.168.4.11 'sudo raspi-config nonint get_overlay_now'` (expects `0`).
  * PiKVM: `ssh root@192.168.4.66 'findmnt -n -o OPTIONS /; findmnt -n -o OPTIONS /boot'` (expects `ro`).
* *Deep Reference*: [docs/storage-btrfs.md](storage-btrfs.md) and [docs/appliances.md](appliances.md)

## 3. Workloads & Container Services
* **Hermes Agent**: Verify internal gateway bootstrap with `./run.sh test-hermes`. Ensure host directory permissions remain `0755` (`go-w`).
* **Homepage Dashboard**: Redeploy after config adjustments with `./run.sh homepage`.
* **VLC RTSP Stream**: Recover camera feed on Chromebook with `./run.sh restart-vlc`.
* *Deep Reference*: [docs/hermes.md](hermes.md), [docs/homepage.md](homepage.md), and [docs/workflows.md](workflows.md)
