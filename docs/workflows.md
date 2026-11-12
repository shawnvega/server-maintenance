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

## 2. Cockpit Systemd Automation & Host 5 Maintenance (`192.168.4.5`)

Host `192.168.4.5` runs automated Ansible maintenance schedules natively via systemd services and timers, fully observable and manageable via the **Cockpit Web Console** (`https://192.168.4.5:9090`).

### Cockpit Web Dashboard Integration
* **Services View** (`System > Services`): Lists all `ansible-*.service` units with real-time status (green `active`/`success` vs red `failed`), and provides a **"Start"** button to execute tasks on demand without opening SSH.
* **Timers View** (`Services > Timers`): Displays upcoming scheduled execution times, interval countdowns, and last-run timestamps.
* **Logs View** (`Logs` or service unit page): Shows full timestamped, colorized Ansible journal logs with play recaps.

### Registered Schedules & Units
| Service / Timer Unit | Action / Playbook | Default Schedule | Description |
|---|---|---|---|
| `ansible-backup-data.timer` | `./run.sh backup-data` | Daily `02:00` | Syncs Immich database, photos, and shares from Host 4 to Host 5. |
| `ansible-check-btrfs.timer` | `./run.sh check-btrfs` | Daily `06:00` | Audits Btrfs pools across `.4`, `.5`, `.18`, `.19` for errors. |
| `ansible-backup-rpi.timer` | `./run.sh backup` | Sunday `03:00` | Runs `rpi-clone` bootable SD card mirror backups. |
| `ansible-cleanup.timer` | `./run.sh cleanup` | Sunday `04:00` | Vacuums system journals, cleans apt/dnf caches, and prunes Docker. |
| `ansible-scrub-btrfs.timer` | `./run.sh scrub-btrfs --all` | 1st Sat `01:00` | Monthly Btrfs filesystem scrub for silent bit-rot repair. |
| `ansible-upgrade-all.timer` | `./run.sh upgrade-all` | Monday `01:00` | Weekly full concurrent cluster upgrade (also triggerable on-demand). |

### Deployment & Management Commands
```bash
# Deploy or update systemd timers & services to Host 5
./run.sh deploy-automation

# Inspect active timers directly on Host 5
ssh shawn@192.168.4.5 'systemctl list-timers "ansible-*"'

# Manually trigger a task from CLI (or click "Start" in Cockpit UI)
ssh shawn@192.168.4.5 'sudo systemctl start ansible-backup-data.service'

# View live journal logs
ssh shawn@192.168.4.5 'journalctl -u ansible-backup-data.service -f'
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
  Hermes Gateway delegates STT requests to `http://192.168.4.5:4000/v1` using bearer authentication, keeping CPU load off the dual-core Fedora node.
* **Verification**:
  Execute `./run.sh test-hermes` to verify the complete LLM and STT pipeline.
* **Documentation**:
  Refer to [.agents/skills/mlx-whisper/SKILL.md](../.agents/skills/mlx-whisper/SKILL.md) for architecture, configuration schemas, and troubleshooting.

---

## 11. LiteLLM AI Gateway & Routing (Pi 5)

The cluster runs a centralized **LiteLLM Proxy** Docker container on `192.168.4.5:4000` acting as an authenticated 24/7 gateway and fallback router.

* **Deployment & Updates**:
  ```bash
  ./run.sh litellm
  ```
  Deploys and recreates `compose/192.168.4.5/litellm` using `deploy_litellm.yml`.
* **Routing**:
  * Chat Completions (`coding-12b`, `coding-26b`, `coding-31b`): Proxies to Apple Silicon Mac Ollama (`192.168.4.8:11434`) with 128k context bounds.
  * Speech-to-Text (`whisper`): Proxies to Apple Silicon Mac MLX Whisper (`192.168.4.8:8080/v1`).
  * Fallbacks: Configurable in `compose/192.168.4.5/litellm/config/litellm_config.yaml` to seamlessly redirect to cloud APIs (Gemini, Groq, OpenAI) when the Mac is offline.
* **Mac Firewall Security**:
  Access from Pi 5 to Mac backends (`11434`, `8080`) is gated by macOS PF firewall (`/etc/pf.anchors/com.homelab.litellm`), configured via `./scripts/setup_mac_firewall.sh`.

---

## 12. Host Wayland VNC, noVNC & Display Scaling (`192.168.4.19`)

Host `192.168.4.19` runs a native **Wayland VNC server (`wayvnc`)** on port `5900` and **noVNC (`websockify`)** on port `6080` mirroring the physical **`labwc`** (`lxqt-wayland`) desktop—while the optional `hermes-desktop` sandbox container uses port `6081` (`desktop` profile).

* **Permanent Display Scaling**: `~/.config/lxqt/labwc/autostart` runs `wlr-randr --output eDP-1 --scale 2`, giving `eDP-1` (`3000x2000@60.0`) a permanent `1500x1000` logical resolution whether or not VNC is connected.
* **SDDM Autologin**: `/etc/sddm.conf.d/autologin.conf` automatically logs `shawn` into `lxqt-wayland.desktop` on boot so `wayvnc.service` and `novnc.service` (`systemctl --user status wayvnc novnc`) start immediately.
* **Firewall & Client Access**: `firewalld` permits `5900/tcp` and `6080/tcp` only from `192.168.4.0/24`.
  * **Browser (`noVNC`)**: `https://192.168.4.19:6080/` (TLS/WSS with self-signed cert so browser WebCrypto supports `wayvnc` RSA-AES auth; login as `shawn` + VNC password).
  * **Native VNC Client**: Connect **`TigerVNC.app`** or **`VNC Viewer.app`** to `192.168.4.19:5900` (login as `shawn` + VNC password).
* **Deployment & Password Rotation**:
  ```bash
  ./run.sh setup-vnc
  ```



