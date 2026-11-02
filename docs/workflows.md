# Specialized Workflows, Services & Maintenance

This document covers operational workflows for the reverse proxy, Semaphore runner safety, backup synchronization, credential rotation, secret management, service cleanup, and executing commands inside Docker containers.

---

## 1. Native Caddy Reverse Proxy (`192.168.4.5`)

Host `192.168.4.5` runs Caddy natively as a systemd service (`caddy.service`), providing HTTPS ingress and reverse proxy routing for cluster services.

* **Source of Truth**: `files/caddy/Caddyfile` in the repository.
* **Deployment Playbook**: `caddy.yml` (using `tasks/deploy_caddy.yml`).
* **Active Routing Table**:
  | Ingress Domain | Target Upstream | Description |
  |---|---|---|
  | `http://192.168.4.5` | `http://127.0.0.1:3001` | Homepage homelab dashboard |
  | `immich.vvvega.com` | `http://192.168.4.4:2283` | Immich photo & video server |
  | `www.vvvega.com` | `503 Service Unavailable` | Static decommission response (WordPress removed) |
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

### Access Endpoints & Credentials
* **Local LAN URL**: `http://192.168.4.5:3000` (LAN only; external ingress disabled)
* **Initial Admin Credentials**: Username `admin` / Password `changeme` (configured in `compose/192.168.4.5/semaphore/docker-compose.yml`)

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
4. Update `.vault_pass` with the new password string:
   ```bash
   echo -n "new_password" > .vault_pass
   ```
5. Verify decryption:
   ```bash
   .venv/bin/ansible-vault view vars/vault.yml --vault-password-file .vault_pass
   ```

### Overriding Service Credentials (e.g. Hermes, Semaphore)
Default credentials defined in `.env.j2` templates can be overridden and stored securely in `vars/vault.yml`:

1. Edit vault:
   ```bash
   .venv/bin/ansible-vault edit vars/vault.yml
   ```
2. Add your custom variables:
   ```yaml
   # Hermes web dashboard credentials
   hermes_dashboard_username: "admin"
   hermes_dashboard_password: "your_secure_hermes_password"

   # Semaphore UI admin password
   semaphore_admin_password: "your_secure_semaphore_password"
   ```
3. Deploy the updated stack:
   * **For Hermes (`192.168.4.19`)**:
     ```bash
     ./run.sh upgrade --tags docker --limit 192.168.4.19
     ```
   * **For Semaphore (`192.168.4.5`)**:
     ```bash
     ./run.sh upgrade --tags docker --limit 192.168.4.5
     ```
     *(Ansible will re-render `.env` and automatically run `semaphore users change-by-login` to sync the running database password)*

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

---

## 8. Executing Commands Inside Docker Containers

Several critical cluster services run as Docker containers across hosts (`192.168.4.4`, `192.168.4.5`, and `192.168.4.19`). Administrative tasks often require inspecting container states, querying internal databases, or running container-local CLIs.

### Container Isolation & Architecture Gotcha

In dual-container or microservice stacks, CLI binaries exist **only inside the service container providing them**:

* **Hermes (`192.168.4.19`)**:
  * `hermes-gateway`: Houses the core agent runtime, Python virtual environment, and the `hermes` CLI (`/opt/hermes/.venv/bin/hermes`).
  * `hermes-desktop`: Houses the unprivileged, sandboxed X11/Openbox/noVNC desktop for web and browser automation. It does **not** have the `hermes` CLI installed, and commands run in its LXTerminal will report `hermes: command not found`.
* **Immich (`192.168.4.4`)**:
  * `immich_server`: Application APIs and CLI tools.
  * `immich_postgres`: Database engine where `psql` and `pg_isready` are available.

### Execution Methods

#### Method A: Ad-Hoc Command via `./run.sh raw`
Best for quick scripts, queries, or automations from the repository directory without opening a persistent SSH session. Always pass `--limit <target_host>`:

```bash
# List Hermes profiles inside hermes-gateway
./run.sh raw 'docker exec -u hermes hermes-gateway /opt/hermes/.venv/bin/hermes profile list' --limit 192.168.4.19

# Inspect model configuration
./run.sh raw 'docker exec hermes-gateway /opt/hermes/.venv/bin/hermes config get model' --limit 192.168.4.19

# Check Immich PostgreSQL database readiness
./run.sh raw 'docker exec immich_postgres pg_isready -U postgres' --limit 192.168.4.4
```

#### Method B: Single Command via Direct SSH
Convenient from any terminal on your local Mac:

```bash
# Rename a Hermes profile
ssh shawn@192.168.4.19 'docker exec -u hermes hermes-gateway /opt/hermes/.venv/bin/hermes profile rename <old-name> <new-name>'

# Query active PostgreSQL connections in Immich
ssh shawn@192.168.4.4 'docker exec -u postgres immich_postgres psql -c "SELECT count(*) FROM pg_stat_activity;"'
```

#### Method C: Interactive Shell via `ssh -t` + `docker exec -it`
When you need an interactive terminal session, pipe navigation, or a bash prompt inside a container, you must allocate a pseudo-terminal on both SSH and Docker using `ssh -t` and `docker exec -it`:

```bash
# Drop into an interactive bash prompt inside hermes-gateway as user hermes
ssh -t shawn@192.168.4.19 'docker exec -it -u hermes hermes-gateway bash'

# Drop into a PostgreSQL prompt inside immich_postgres
ssh -t shawn@192.168.4.4 'docker exec -it -u postgres immich_postgres psql -U postgres -d immich'
```

### Critical Rules & Permissions

> [!IMPORTANT]
> **Preserve File Ownership (`-u <user>` or `-u <uid>`)**:
> When running commands that modify files in bind-mounted host volumes (e.g. `/opt/data` mounted from `/home/shawn/docker/hermes/data`):
> * Default `docker exec` runs as container `root` (UID `0`). Any newly created files or directories will be owned by `root`.
> * This will trigger permission gate failures such as `unsafe_control_permissions` (trapping services in crash or reconnect loops).
> * **Always pass `-u hermes` or `-u 1000`** (or the respective service user) when creating or altering configuration, profiles, or cache data.

---

## 9. Homepage Homelab Dashboard (`192.168.4.5`)

The cluster runs a centralized **Homepage** dashboard container on `192.168.4.5` providing one-click access, status indicators, and live metrics for all homelab services.

* **Access Endpoints**:
  * Clean LAN URL: `http://192.168.4.5` (routed automatically via native Caddy on port 80).
  * Direct Container Port: `http://192.168.4.5:3001`
* **Configuration Files** (`compose/192.168.4.5/homepage/config/`):
  * `settings.yaml`: Title, layout categories (Core Infrastructure, Automation & AI, Media & Storage, Monitoring), theme, and search provider.
  * `services.yaml`: Service tiles, icons, URLs, container mapping, ping checks, and widgets (`glances` with `metric: cpu`). Includes OpenMediaVault (`192.168.4.4`), Cockpit (`192.168.4.19:9090`), all 5 Glances nodes (`.5`, `.4`, `.19`, `.18`, `.11`), and Frigate NVR (`https://192.168.4.19:8971`).
  * `widgets.yaml`: Header resources (Pi 5 CPU, memory, disk, and CPU temperature).
  * `bookmarks.yaml`: Quick link bookmarks.
  * `docker.yaml`: Local Docker socket configuration for live container status.
* **Deployment & Verification**:
  * Execute `./run.sh homepage` to sync static compose and config files to `~/docker/homepage` and recreate the container.
  * Playbook: `deploy_homepage.yml` (included in `docker_stacks` on `192.168.4.5`).

---

## 10. MLX Whisper Voice Dictation & STT Setup

The cluster utilizes local Apple Silicon Metal acceleration on the host Mac (`192.168.4.8`) to power low-latency speech-to-text dictation for client agents (such as Hermes on `192.168.4.19`).

* **One-Click Provisioning**:
  ```bash
  ./run.sh setup-whisper
  ```
  Runs `scripts/setup_mlx_whisper.sh` to configure the `com.mlx.whisper` LaunchAgent on port 8080, route transcription requests through LiteLLM on port 4000, and execute a local self-test.
* **Hermes Integration**:
  Hermes Gateway delegates STT requests to `http://192.168.4.8:4000/v1` using bearer authentication, keeping CPU load off the dual-core Fedora node.
* **Verification**:
  Execute `./run.sh test-hermes` to verify the complete LLM and STT pipeline.
* **Documentation**:
  Refer to [.agents/skills/mlx-whisper/SKILL.md](../.agents/skills/mlx-whisper/SKILL.md) for architecture, configuration schemas, and troubleshooting.


