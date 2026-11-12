# Btrfs Storage Architecture, Scrubs & Device Management

This document details Btrfs filesystem architecture across the homelab cluster, automated health monitoring, scrub operations, safety gates, and device maintenance.

---

## Cluster Btrfs Storage Roles

| Host | Group | Filesystems / Pools | Storage Role |
|---|---|---|---|
| `192.168.4.4` | `btrfs_storage_servers`, `btrfs_servers` | Mounted data pools | Immich photo storage, Syncthing synchronization, block backups |
| `192.168.4.5` | `btrfs_storage_servers`, `btrfs_servers` | `hdds`, `ssds` pools | Primary storage hub, Immich & Hermes backup target |
| `192.168.4.18` | `btrfs_servers` | `/var` (3-device RAID 1) | Replaces limited eMMC with mirrored storage across 3 flash devices |
| `192.168.4.19` | `btrfs_servers` | Root `/` (Fedora) | Default Fedora Btrfs root filesystem with subvolumes (`root`, `home`) |

---

## 1. Automated Health Inspection (`check-btrfs`)

Playbook: `btrfs_check.yml`

Automates cluster-wide health inspection across all mounted Btrfs filesystems without making modifications:
* **Filesystem Discovery**: Dynamically queries `findmnt` for all filesystems with type `btrfs`.
* **Device Error Counters**: Queries `btrfs device stats -z` for:
  * `corruption_errs` (silent data corruption detected via checksums)
  * `io_errs` (hardware I/O failures)
  * `read_errs` / `write_errs` / `generation_errs`
* **Allocation & Unallocated Space**: Parses `btrfs filesystem usage` to detect metadata or data chunk starvation.
* **Active Operations**: Reports if scrubs or balances are currently running.

### Commands
```bash
# Check Btrfs health across all Btrfs servers (.4, .5, .18, .19)
./run.sh check-btrfs

# Check Btrfs health on a specific server (e.g. Chromebook /var)
./run.sh check-btrfs --limit 192.168.4.18

# Check storage servers only (.4 & .5)
./run.sh check-btrfs -e target_hosts=btrfs_storage_servers
```

---

## 2. Background Scrub Operations (`scrub-btrfs`)

Btrfs scrub reads all data and metadata across disks, verifies checksums, and automatically fixes corrupt blocks if a redundant copy (RAID 1) exists.

### Scrub Lifecycles & Playbooks
* **Default Pi 5 Scrub (`btrfs_scrub.yml`)**:
  ```bash
  # Scrub all Btrfs pools on 192.168.4.5
  ./run.sh scrub-btrfs

  # Scrub specific pool on 192.168.4.5
  ./run.sh scrub-btrfs -e scrub_target=hdds
  ./run.sh scrub-btrfs -e scrub_target=ssds
  ```
* **Single-Host Dedicated Playbooks** (for targeted single-host runs):
  * `btrfs_scrub_4.yml`: Targets `192.168.4.4` (`./run.sh scrub-btrfs --limit 192.168.4.4`)
  * `btrfs_scrub_5.yml`: Targets `192.168.4.5`
  * `btrfs_scrub_18.yml`: Targets `192.168.4.18` (`/var` RAID 1)
  * `btrfs_scrub_19.yml`: Targets `192.168.4.19` (Fedora root)
* **Cluster-Wide Concurrent Scrub (`btrfs_scrub_all.yml`)**:
  ```bash
  ./run.sh scrub-btrfs --all
  ```

### Pre-Flight Scrub Safety Gate (`tasks/check_btrfs_scrub.yml`)
Because Btrfs scrub is heavily I/O intensive, running package upgrades, Docker builds, or reboots during a scrub degrades performance and risks interrupting data verification:
* During upgrade pipelines (`upgrade.yml` or `upgrade_all.yml`), Ansible queries `btrfs scrub status` on all mountpoints.
* If a scrub is active, Ansible logs progress, speed, bytes scrubbed, and ETA, then gracefully ends execution for that host (`meta: end_host`).
* Other non-scrubbing nodes continue their upgrades normally.
* **Override**: Pass `-e "ignore_btrfs_scrub=true"` or `--skip-tags scrub_check` to bypass this check.

---

## 3. Chromebook Split-Storage Btrfs RAID 1 (`192.168.4.18`)

The Chromebook uses a split-storage strategy:
* Fast internal eMMC (`/dev/mmcblk1`) stores `/boot/efi`, root `/` (`/usr`, `/etc`, `/home`), and `/swapfile`.
* RAM `tmpfs` stores `/tmp`.
* A 3-device Btrfs RAID 1 pool mounts at `/var` (`compress=zstd:3,noatime,nofail`) using:
  * `/dev/sda` (7.6 GB USB microSD card reader)
  * `/dev/sdb` (7.5 GB USB thumb drive)
  * `/dev/sdc` (59.5 GB SD card)

### Migration Playbook: `migrate_var_btrfs.yml`
Used when rebuilding or initializing `/var` storage:
1. Partitions and formats `/dev/sda`, `/dev/sdb`, `/dev/sdc` into a multi-device Btrfs RAID 1 pool (`-d raid1 -m raid1`).
2. Stops services writing to `/var` (Docker, VLC, logging).
3. Synchronizes existing `/var` contents into the new pool preserving permissions (`rsync -aHAX`).
4. Updates `/etc/fstab` with the new UUID and mount options.
5. Reclaims old eMMC space and verifies read/write integrity.

```bash
./run.sh migrate-var -K
```

### Drive Replacement Procedure
If a drive in the 3-device RAID 1 pool reports errors or fails:

1. **Check error counters and filesystem layout**:
   ```bash
   ssh shawn@192.168.4.18 'sudo btrfs filesystem usage -T /var'
   ssh shawn@192.168.4.18 'sudo btrfs device stats /var'
   ```
2. **Identify failed device ID**:
   ```bash
   ssh shawn@192.168.4.18 'sudo btrfs filesystem show /var'
   ```
3. **Insert new device and initiate live replacement**:
   ```bash
   # Syntax: btrfs replace start <source_dev_or_devid> <target_dev> <mountpoint>
   ssh shawn@192.168.4.18 'sudo btrfs replace start /dev/sda /dev/sdd /var'
   ```
4. **Monitor replacement progress**:
   ```bash
   ssh shawn@192.168.4.18 'sudo btrfs replace status /var'
   ```
5. **Reset device error counters**:
   ```bash
   ssh shawn@192.168.4.18 'sudo btrfs device stats -z /var'
   ```
6. Once complete, update `/etc/fstab` if device UUIDs or mount paths changed.
