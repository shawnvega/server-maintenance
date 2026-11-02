# Specialized Workflows, Services & Maintenance

This document covers operational workflows for the reverse proxy, Semaphore runner safety, backup synchronization, credential rotation, secret management, and service cleanup.

---

## 1. Native Caddy Reverse Proxy (`192.168.4.5`)

Host `192.168.4.5` runs Caddy natively as a systemd service (`caddy.service`), providing HTTPS ingress and reverse proxy routing for cluster services.

* **Source of Truth**: `files/caddy/Caddyfile` in the repository.
* **Deployment Playbook**: `caddy.yml` (using `tasks/deploy_caddy.yml`).
* **Validation & Zero-Downtime Reload**:
  1. Copies `files/caddy/Caddyfile` to `/etc/caddy/Caddyfile` on the host.
  2. Runs `caddy validate --config /etc/caddy/Caddyfile` before applying. If validation fails, Ansible halts without interrupting traffic.
  3. Executes `systemctl reload caddy` for zero-downtime reconfiguration.

### Commands
```bash
# Validate and deploy Caddy configuration
./run.sh caddy

# Or trigger during a standard upgrade via tags
./run.sh upgrade --tags caddy
```

---

## 2. Host 5 Standalone Maintenance & Semaphore Runner Safety

### The Semaphore Runner Conflict
Semaphore UI executes automation playbooks inside a container hosted on `192.168.4.5`. If Ansible upgrades `192.168.4.5` directly through Semaphore:
* Restarting Docker or upgrading network/system components terminates the active Semaphore runner container, crashing the playbook run mid-execution.

### The Safety Solution
1. **Runner Detection (`tasks/check_semaphore_safety.yml`)**:
   * Master and standard upgrade playbooks (`upgrade_all.yml`, `upgrade.yml`) detect if they are running inside Semaphore.
   * If detected, execution for `192.168.4.5` is cleanly ended (`meta: end_host`), while displaying the status and timestamp of Host 5's last independent maintenance run.
2. **Standalone Maintenance Script (`files/upgrade_host5.sh`)**:
   * A native bash script deployed to `/home/shawn/scripts/upgrade_host5.sh`.
   * Enables Docker `live-restore` to keep containers running during Docker engine updates.
   * Records execution logs and structured status to `/home/shawn/logs/upgrade_host5.status`.
3. **Detached Execution (`trigger_host5_upgrade.yml`)**:
   * Launches `upgrade_host5.sh` using `systemd-run` as a transient, detached background unit.
   * Safe to trigger from Semaphore or CLI because the job outlives the runner session.

### Commands
```bash
# Check status of the last Host 5 upgrade
./run.sh check-host5

# Deploy latest upgrade_host5.sh script and enable Docker live-restore
./run.sh deploy-host5 -K

# Fire-and-forget standalone upgrade via systemd
./run.sh upgrade-host5 -K
```

---

## 3. Data Share & Immich Sync (`backup_data.yml`)

Backs up user data shares, external drive pools, and Immich media/database from `192.168.4.4` to the Pi 5 (`192.168.4.5`) storage pool:
* Handles automated database dumps for Immich Postgres.
* Synchronizes photo library using checksum-verified `rsync`.
* Fully compatible with unattended Semaphore UI scheduled task templates.

```bash
./run.sh backup-data -K
```

For remote script backups and cron management on `192.168.4.4`, see `setup_remote_backup.yml`.

---

## 4. Universal Password Rotation (`change_password.yml`)

Synchronizes a password change across every account in the cluster in a single invocation:
* Prompts interactively once for the new password (with confirmation).
* Updates user password for `shawn` across standard servers (`192.168.4.4`, `.5`, `.18`, `.19`).
* Temporarily reboots `192.168.4.11` (OverlayFS Pi) into RW mode, updates `shawn`, and reboots back into verified Read-Only mode.
* Updates `root` system account on PiKVM (`192.168.4.66`).
* Updates the PiKVM Web UI `admin` password via `/usr/bin/kvmd-htpasswd`.

```bash
./run.sh change-password -K
```

---

## 5. Docker Compose Secrets & Ansible Vault

### Docker Stack Management
* Compose definitions live in `compose/<host>/<service>/compose.yml`.
* Environment variable templates live alongside as `.env.j2`.
* During `./run.sh upgrade --tags docker`, Ansible syncs compose files, renders `.env.j2` templates with decrypted secrets, and performs rolling container recreations.

### Changing Vault Passwords
Sensitive variables (passwords, tokens, API keys) are stored encrypted in `vars/vault.yml`. The password is read from `.vault_pass` (gitignored).

To rekey the vault with a new password:
1. Ensure `.vault_pass` contains your **current** password.
2. Run interactive rekey:
   ```bash
   .venv/bin/ansible-vault rekey --new-vault-id prompt vars/vault.yml
   ```
3. Type the new password when prompted.
4. Update `.vault_pass` with the new password string.

---

## 6. Decommission PHP / WordPress Workloads (`shutdown_php.yml`)

Permanently stops WordPress and PHP workloads while preserving storage volumes:
1. Stops WordPress and database containers.
2. Sets container restart policies to `no`.
3. Closes listening web ports.
4. Updates Caddy configuration to block ingress and return HTTP 503 Service Unavailable.

```bash
./run.sh shutdown-php
```

---

## 7. Disk Space Cleanup & Maintenance (`cleanup.yml`)

Reclaims disk space across all standard Linux hosts:
* Vacuums systemd journal logs older than 7 days (`journalctl --vacuum-time=7d`).
* Cleans package manager caches (`apt-get clean`, `dnf clean all`).
* Runs `docker system prune -af --volumes` to purge dangling images and stopped containers.

```bash
# Clean all standard hosts
./run.sh cleanup -K

# Clean single host (e.g. Chromebook)
./run.sh cleanup --limit 192.168.4.18 -K
```
