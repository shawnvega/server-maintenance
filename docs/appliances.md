# Read-Only Appliance Architectures: OverlayFS Pi & Arch Linux PiKVM

This document provides deep architectural details, maintenance lifecycles, and operational procedures for the cluster's two read-only appliances: the **OverlayFS Raspberry Pi (`192.168.4.11`)** and the **Native Read-Only Arch Linux PiKVM (`192.168.4.66`)**.

---

## 1. OverlayFS Raspberry Pi (`192.168.4.11`)

### Architecture & Mechanics
* **Operating System**: Debian / Raspberry Pi OS.
* **Authentication**: User `shawn` via SSH key with sudo (`-K`).
* **Root Protection**: Linux kernel OverlayFS mounts a read-only lower filesystem from the SD card/storage, while redirecting all runtime writes (`/tmp`, `/var`, configuration changes) into a volatile upper `tmpfs` in RAM. Any writes made during runtime vanish upon reboot.
* **Boot Protection**: The `/boot/firmware` (or `/boot`) FAT partition is marked read-only in `/etc/fstab`.

### State Detection (`raspi-config nonint`)
The running and configured states can be queried without interactive menus:
* `get_overlay_now`: Running overlay status (`0` = Active / Read-Only, `1` = Inactive / Read-Write).
* `get_overlay_conf`: Configured overlay status for next boot (`0` = Will boot RO, `1` = Will boot RW).
* `get_bootro_now`: Running boot partition status (`0` = Read-Only, `1` = Read-Write).
* `get_bootro_conf`: Configured boot partition status in `/etc/fstab` (`0` = Read-Only, `1` = Read-Write).

### Maintenance Lifecycle (`readonly_upgrade.yml`)
To perform package upgrades, the appliance must temporarily transition to Read/Write mode:
1. Verify current status.
2. Disable overlay: `raspi-config nonint do_overlayfs 1`.
3. Reboot host into RW mode.
4. Remount boot partition as writable: `mount -o remount,rw /boot/firmware`.
5. Verify both root and boot filesystems are writable (`touch /etc/.test_rw && rm -f /etc/.test_rw`).
6. Heal dpkg if needed (`dpkg --configure -a`) and upgrade packages (`apt update && apt full-upgrade -y && apt autoremove`).
7. Re-enable boot write protection (`raspi-config nonint enable_bootro`) and remount boot read-only.
8. Re-enable overlay: `raspi-config nonint do_overlayfs 0`.
9. Reboot back into Read-Only mode.
10. Verify post-reboot state: assert `get_overlay_now == 0` and `get_bootro_now == 0`.

### Execution
```bash
./run.sh upgrade-ro -K
```

### Manual Emergency Recovery
If a maintenance cycle is interrupted and the Pi remains in Read/Write mode:
```bash
# Verify current state (expect 1 if stuck in RW)
ssh shawn@192.168.4.11 'sudo raspi-config nonint get_overlay_now'

# Force back to Read-Only and reboot
ssh shawn@192.168.4.11 'sudo raspi-config nonint enable_bootro && sudo raspi-config nonint do_overlayfs 0 && sudo reboot'
```

---

## 2. Native Read-Only PiKVM (`192.168.4.66`)

### Architecture & Mechanics
* **Operating System**: Arch Linux ARM.
* **Authentication**: Direct `root` SSH login with SSH keys (no `sudo` or `-K` needed).
* **Remote Tmp Configuration**: Because `/root` is read-only when mounted `ro`, Ansible requires `ansible_remote_tmp=/tmp/.ansible` (configured in `inventory.ini`), writing directly to the volatile `tmpfs` at `/tmp`.
* **Filesystem Protection**: Unlike OverlayFS, PiKVM uses native read-only filesystem mounts:
  * `/` (ext4) and `/boot` (vfat) are mounted `ro` via kernel command line parameters (`ro`) and `/etc/fstab`.
  * Temporary files and runtime logs write to memory-backed `tmpfs` mounts (`/tmp`, `/var/log`).
* **Mount Control Scripts**: PiKVM provides native helper binaries:
  * `/usr/bin/rw`: Remounts `/` and `/boot` as read-write.
  * `/usr/bin/ro`: Remounts `/` and `/boot` as read-only.

### Critical Safety Invariants for PiKVM
* **Never use Debian tools**: Do NOT run `apt`, `dpkg`, or `raspi-config` on PiKVM.
* **Never run raw pacman upgrade**: Do NOT run `pacman -Syu` directly.
* **Always use official pikvm-update**: System updates must be applied exclusively via `/usr/bin/pikvm-update --no-reboot`. This official script performs repository synchronization, package signature validation, cache cleaning, pacman updates, and critically, `kvmd -m` integrity verification.
* **KVMD Integrity Gate**: If `kvmd -m` fails, do NOT reboot the host. Inspect `kvmd -m` output and resolve the configuration issue before rebooting.

### Maintenance Lifecycle (`pikvm_upgrade.yml`)
1. Inspect initial mount status via `findmnt -n -o OPTIONS /`.
2. Check system load against threshold.
3. Run official `/usr/bin/pikvm-update --no-reboot`.
4. Inspect exit code:
   * **Exit Code `100`** (Updates were installed): A reboot is required. A system reboot automatically re-engages the kernel command line `ro` parameters, returning the machine to a clean read-only state.
   * **Exit Code `0`** (System already up to date): No reboot required. Execute `/usr/bin/ro` to guarantee the filesystem is locked.
5. Verify post-upgrade status: Assert `/` and `/boot` are mounted `ro` and `kvmd -m` returns status 0.

### Execution
```bash
./run.sh upgrade-pikvm
```

### Manual Emergency Recovery
If PiKVM filesystems are left in Read/Write mode:
```bash
# Check current mount options
ssh root@192.168.4.66 'findmnt -n -o OPTIONS /; findmnt -n -o OPTIONS /boot'

# Lock back to read-only manually
ssh root@192.168.4.66 '/usr/bin/ro'

# Or reboot (kernel cmdline guarantees read-only boot)
ssh root@192.168.4.66 'reboot'
```

### KVMD Service Integrity Recovery (`kvmd -m`)
> [!CAUTION]
> Do NOT reboot PiKVM if `kvmd -m` integrity verification fails, as it may render remote KVM access inaccessible.

If `kvmd -m` reports errors:
```bash
# Inspect validation errors
ssh root@192.168.4.66 'kvmd -m'

# Check service logs
ssh root@192.168.4.66 'journalctl -u kvmd -n 50 --no-pager'

# Re-run update to resolve interrupted package upgrades
ssh root@192.168.4.66 '/usr/bin/pikvm-update --no-reboot'
```

