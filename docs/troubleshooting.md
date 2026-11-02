# Homelab Troubleshooting & Failure Mitigation Runbooks

This document provides mitigation procedures, diagnostics, and recovery steps for common operational issues across the homelab infrastructure.

---

## 1. High System Load Halts Upgrade Pipeline

### Symptoms
Stage 1 (`load_check`) in `upgrade.yml` or `upgrade_all.yml` times out waiting for load average to drop below the threshold (`load_threshold`).

### Investigation
Inspect top CPU-consuming processes across the cluster or on the blocked host:
```bash
./run.sh raw 'ps aux --sort=-%cpu | head -n 10'
```
* On `192.168.4.19`: Check Frigate camera ingestion or Hermes model inference.
* On `192.168.4.4` / `.5`: Check Immich machine learning transcode or indexing jobs.

### Mitigation & Overrides
If high load is due to expected batch background processing and it is safe to proceed:
```bash
# Temporarily override load threshold for the run
./run.sh upgrade -K -e "load_threshold=8.0"

# Or skip the load check entirely
./run.sh upgrade -K --skip-tags load_check
```

---

## 2. `rpi-clone` Backup Failures

### Symptoms
Stage 2 (`backup`) halts with an error executing `rpi-clone`.

### Investigation
Check whether the target block device disconnected, went read-only, or shifted device names:
```bash
./run.sh raw 'lsblk'
```
* Compare the actual disk device with `backup_device` configured in `inventory.ini` (e.g. `/dev/mmcblk0` vs `/dev/sda`).
* Check kernel ring buffer for USB reset or I/O errors:
  ```bash
  ssh shawn@192.168.4.4 'sudo dmesg -T | grep -E "(mmc|sd|error)" | tail -n 20'
  ```

### Mitigation
1. If the device node changed (e.g. from `/dev/sda` to `/dev/sdb`), update `inventory.ini`.
2. If the destination card is full or corrupted, format or replace the target SD/USB card.
3. To proceed with OS updates without backing up:
   ```bash
   ./run.sh upgrade -K --skip-tags backup
   ```

---

## 3. Btrfs RAID 1 Drive Degradation or Failure (`192.168.4.18`)

### Symptoms
Btrfs health check (`./run.sh check-btrfs`) reports non-zero `io_errs`, `write_errs`, or `corruption_errs` on `/var`.

### Investigation
Inspect drive mirror allocations and error counters:
```bash
ssh shawn@192.168.4.18 'sudo btrfs filesystem usage -T /var'
ssh shawn@192.168.4.18 'sudo btrfs device stats /var'
```
Check disk presence and partition layout:
```bash
ssh shawn@192.168.4.18 'sudo btrfs filesystem show /var'
```

### Drive Replacement Procedure
Btrfs allows online live replacement of a failing drive without taking the filesystem offline:
1. Attach replacement storage device (e.g. `/dev/sdd`).
2. Start live replacement:
   ```bash
   # Syntax: btrfs replace start <failing_dev_or_devid> <new_dev> <mountpoint>
   ssh shawn@192.168.4.18 'sudo btrfs replace start /dev/sda /dev/sdd /var'
   ```
3. Check replacement progress:
   ```bash
   ssh shawn@192.168.4.18 'sudo btrfs replace status /var'
   ```
4. Once replacement reports `100% finished`, reset device error statistics:
   ```bash
   ssh shawn@192.168.4.18 'sudo btrfs device stats -z /var'
   ```

---

## 4. OverlayFS Pi Fails to Return to Read-Only (`192.168.4.11`)

### Symptoms
Post-upgrade assertion fails with `get_overlay_now != 0`, or manual inspection shows the filesystem is writable.

### Investigation
Check active and configured status:
```bash
ssh shawn@192.168.4.11 'sudo raspi-config nonint get_overlay_now'
ssh shawn@192.168.4.11 'sudo raspi-config nonint get_bootro_now'
```
* Output `0` = Read-Only (Expected normal state)
* Output `1` = Read-Write (Abnormal if maintenance is complete)

### Recovery
Force boot write protection, enable overlay, and reboot:
```bash
ssh shawn@192.168.4.11 'sudo raspi-config nonint enable_bootro && sudo raspi-config nonint do_overlayfs 0 && sudo reboot'
```
Wait 30 seconds, reconnect, and verify:
```bash
ssh shawn@192.168.4.11 'sudo raspi-config nonint get_overlay_now' # Should return 0
```

---

## 5. PiKVM Fails to Return to Read-Only or KVMD Errors (`192.168.4.66`)

### Symptoms
Filesystem remains read-write after update, or `kvmd -m` service verification fails.

### Investigation
Check mount status:
```bash
ssh root@192.168.4.66 'findmnt -n -o OPTIONS /; findmnt -n -o OPTIONS /boot'
```

### Recovery: Read-Only Remount
If filesystems remain read-write (`rw`):
```bash
ssh root@192.168.4.66 '/usr/bin/ro'
```
If `/usr/bin/ro` fails due to open write locks, reboot the device (PiKVM kernel parameters boot directly into `ro` mode):
```bash
ssh root@192.168.4.66 'reboot'
```

### Recovery: KVMD Service Integrity (`kvmd -m`)
> [!CAUTION]
> Do NOT reboot PiKVM if `kvmd -m` integrity verification fails, as it may render remote KVM access inaccessible.

Inspect validation errors:
```bash
ssh root@192.168.4.66 'kvmd -m'
```
* Check for syntax errors in `/etc/kvmd/override.yaml`.
* Check service logs: `journalctl -u kvmd -n 50 --no-pager`.
* Re-run `/usr/bin/pikvm-update --no-reboot` to resolve interrupted package upgrades.

---

## 6. VLC RTSP Video Stream Issues (`192.168.4.18`)

### Symptoms
Fullscreen camera monitor stream on the Chromebook display is frozen or closed.

### Investigation & Restart
Check whether VLC is running:
```bash
ssh shawn@192.168.4.18 'pgrep -x vlc'
```
Restart stream using the dedicated shortcut:
```bash
./run.sh restart-vlc
```
If display errors occur, ensure X11 display session `:0` is active:
```bash
ssh shawn@192.168.4.18 'DISPLAY=:0 xrandr'
```
