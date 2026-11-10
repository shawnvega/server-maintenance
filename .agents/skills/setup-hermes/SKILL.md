---
name: setup-hermes
description: >-
  Use this skill when provisioning, configuring, troubleshooting, or upgrading the Hermes
  desktop agent container on Fedora (192.168.4.19), connecting it to LiteLLM on the host Mac,
  or managing custom Docker build stacks in Ansible.
---

# Hermes Desktop Setup & Management

This skill guides the provisioning, lifecycle management, verification, and troubleshooting of the **Hermes Desktop Agent** on `192.168.4.19` connected to **LiteLLM / Ollama** running on the host Mac (`192.168.4.8`).

For in-depth troubleshooting of specific errors or deep architectural background, refer to:
* **[references/gotchas.md](references/gotchas.md)**: 16 battle-tested gotchas, symptoms, root causes, and fixes.
* **[references/ecosystem-research.md](references/ecosystem-research.md)**: Research on LiteLLM packaging, Chromium shared memory, TrueColor, and auth handshakes.

---

## Quick Triage Decision Matrix

When encountering issues, locate your symptom below for the instant verified fix:

| Symptom / Error | Root Cause | Instant Resolution |
|---|---|---|
| Countdown banner `"─ retrying in 30s"` & `unsafe_control_permissions` | `/opt/data` workspace directory is world-writable (`0777`) | `ssh shawn@192.168.4.19 'chmod 755 /home/shawn/docker/hermes/data'` |
| Web UI or TUI status bar displays `opus 4.6` despite `.env` | Hermes reads model config from `/opt/data/config.yaml`, ignoring Docker env vars | `ssh shawn@192.168.4.19 "docker exec hermes-gateway /opt/hermes/.venv/bin/hermes config set model.default coding-26b && docker restart hermes-gateway"` |
| `OCI runtime create failed: not a directory` on `/etc/timezone` | Fedora lacks `/etc/timezone`; Docker created it as a directory | `ssh shawn@192.168.4.19 'sudo rm -rf /etc/timezone'` and mount only `/etc/localtime:ro` |
| `pipx install "litellm[proxy]"` fails on macOS with PyO3 / maturin errors | macOS default Python 3.15 lacks pre-built wheels | `pipx install --python /opt/homebrew/bin/python3.12 "litellm[proxy]"` |
| `curl http://192.168.4.8:4000/health` returns HTTP 500 Internal Server Error | LiteLLM stateless Prisma DB exception bug | **Benign**. Never use `/health`. Probe `GET /v1/models` instead. |
| Build hangs on `/usr/libexec/docker/cli-plugins/docker-buildx bake` | Deadlocked BuildKit session from abnormal termination | `ssh shawn@192.168.4.19 'pkill -f docker-buildx'` then re-run `./run.sh upgrade --tags docker --limit 192.168.4.19` |
| LiteLLM access logs show 404 for `GET /api/tags` and `POST /api/show` | Hermes model name starts with `ollama/`, triggering native route probes | Model aliasing: Use alias `coding-26b` and `provider: custom` to force OpenAI wire routes (`/v1/*`) |
| `curl: (56) Recv failure` immediately after starting container | s6-overlay init stages require 10–15s for migrations and uvicorn | Allow cold-boot grace period (~15s) until `HERMES_DASHBOARD_READY` appears in logs |
| Voice dictation / mic fails or disabled in dashboard | Insecure HTTP origin (`getUserMedia`) or missing STT backend | Run `./run.sh setup-whisper` and enable `chrome://flags/#unsafely-treat-insecure-origin-as-secure` |
| Web UI model switcher only shows `coding-26b` | Bare `custom` provider probes `/models` without auth (HTTP 401) | Define `providers.litellm` in `config.yaml` with Bearer key and restart gateway |

---

## 1. Quick Reference & Architecture

* **Host Machine (`192.168.4.19`)**:
  * OS: Fedora Linux 43 x86_64, Btrfs root.
  * Hardware: Intel Core i5-8200Y (2 cores / 4 threads), 8GB RAM.
  * Co-located workload: Frigate NVR (Coral TPU + `/dev/dri/renderD128` Intel VAAPI transcoding).
  * **Resource Allocation**:
    * `hermes-gateway`: `mem_limit: 4096m`, `mem_reservation: 1024m`, `cpus: 1.5`.
    * `hermes-desktop`: `mem_limit: 1536m`, `mem_reservation: 512m`, `cpus: 1.0`.
    * Combined maximum memory allocation is ~4GB, preserving 4GB for Fedora system overhead and Frigate NVR.
* **Dual-Container Stack (`compose/192.168.4.19/hermes/`)**:
  * **`hermes-gateway`** (Port **`9119`**): Core agent runtime, tool execution engine, session store, authenticated REST/WebSocket dashboard (`nousresearch/hermes-agent:latest`).
  * **`hermes-desktop`** (Port **`6080`**): Sandboxed virtual desktop (`hermes-desktop:minimal`) running `Xvfb` (display `:1`, 1280x800 24-bit TrueColor), `openbox`, `lxterminal`, `chromium` (`--no-sandbox`), and `noVNC` via `websockify`.
  * **Shared Workspace**: `/home/shawn/docker/hermes/data` mounted to `/opt/data` (gateway) and `/home/hermes/workspace` (desktop).
* **LLM & Audio STT Provider**:
  * Engine (Host Mac at `192.168.4.8`): Local Ollama serving 3 local coding models (`gemma4:12b-mlx-code`, `gemma4:26b-mlx-code`, `gemma4:31b-mlx-code` on port `11434`) + local MLX Whisper (`:8080`), protected by macOS PF firewall whitelist.
  * Central Proxy (Pi 5 at `192.168.4.5:4000`): Dockerized LiteLLM proxy with Bearer token authentication (`sk-hermes-mac-secret`), managed via `compose/192.168.4.5/litellm` and `./run.sh litellm`.
  * Configuration: `compose/192.168.4.5/litellm/config/litellm_config.yaml` declaring aliases `coding-12b`, `coding-26b` (default), and `coding-31b` for LLM, and `whisper` for `audio_transcription`. See [.agents/skills/mlx-whisper/SKILL.md](../mlx-whisper/SKILL.md).

### Coding Models Quick Reference & Usage
| Model Alias | Underlying Ollama Model | Footprint | Best Used For |
|---|---|---|---|
| `coding-12b` | `gemma4:12b-mlx-code` | ~7.7 GB | Fast interactive edits, simple functions, low resource consumption |
| `coding-26b` | `gemma4:26b-mlx-code` | ~17 GB | **Default model**: Balanced general-purpose coding agent workflows |
| `coding-31b` | `gemma4:31b-mlx-code` | ~19 GB | Complex multi-file reasoning, deep refactoring, complex logic |

#### How to Switch Between Coding Models
1. **In-Chat Hot-Swapping (Mid-Session)**:
   Inside any active Hermes web chat session, TUI, or gateway client, type:
   ```text
   /model coding-12b
   /model coding-26b
   /model coding-31b
   ```
2. **Persistent Default Model Switching**:
   To change the default model loaded across new sessions:
   ```bash
   ssh shawn@192.168.4.19 "docker exec hermes-gateway /opt/hermes/.venv/bin/hermes config set model.default coding-31b && docker restart hermes-gateway"
   ```

### Core Invariants

> [!IMPORTANT]
> 1. **Workspace Permissions (`0755`)**: Host directory `/home/shawn/docker/hermes/data` must strictly be mode `0755` (`go-w`) and owned by UID 1000 (`shawn`). Never use `0777` (world-writable), which trips Hermes internal security gates (`unsafe_control_permissions`) and traps the chat UI in an endless 30s reconnect loop.
> 2. **Fedora Timezone**: Fedora has no `/etc/timezone`. Mount **only** `/etc/localtime:/etc/localtime:ro`.
> 3. **LiteLLM Health Probes**: Never use `/health` to evaluate LiteLLM proxy status (stateless mode returns 500 due to an upstream Prisma check bug). Probe `GET /v1/models` instead.
> 4. **Model Configuration Precedence & Provider Declaration**: Hermes reads model definitions from `/opt/data/config.yaml`. To ensure the Web UI model switcher populates all coding models (`coding-12b`, `coding-26b`, `coding-31b`), LiteLLM must be declared under `providers.litellm` with Bearer auth and `model.provider: litellm` (bare `provider: custom` discovery probes fail with 401). Ansible automatically pre-seeds `config.yaml` on fresh deployments using `compose/192.168.4.19/hermes/config.yaml.j2`.

---

## 2. Operational Runbook

### Step 1: Manage LiteLLM Proxy on Pi 5

LiteLLM runs as a Docker container on Raspberry Pi 5 (`192.168.4.5:4000`).

#### Deploy or Restart LiteLLM
```bash
./run.sh litellm
```

Verify models from terminal:
```bash
curl -s -H "Authorization: Bearer sk-hermes-mac-secret" http://192.168.4.5:4000/v1/models
```
        <string>/Users/shawn/.local/bin/litellm</string>
        <string>--config</string>
        <string>/Users/shawn/StudioProjects/server-maintenance/files/litellm_mac_config.yaml</string>
        <string>--host</string>
        <string>0.0.0.0</string>
        <string>--port</string>
        <string>4000</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/Users/shawn/Library/Logs/litellm.log</string>
    <key>StandardErrorPath</key>
    <string>/Users/shawn/Library/Logs/litellm.error.log</string>
</dict>
</plist>
EOF

# 4. Bootstrap and start the service
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.litellm.proxy.plist
```

#### B. Lifecycle & Inspection Commands
```bash
# Inspect status & PID
launchctl print gui/$(id -u)/com.litellm.proxy

# Stop service
launchctl bootout gui/$(id -u)/com.litellm.proxy

# Start / Reload service
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.litellm.proxy.plist

# Inspect logs
tail -n 30 ~/Library/Logs/litellm.log
tail -n 30 ~/Library/Logs/litellm.error.log
```

#### C. Network Isolation via macOS Packet Filter (PF)
To restrict incoming traffic on port 4000 exclusively to localhost and the Fedora host (`192.168.4.19`):
1. Create `/etc/pf.anchors/litellm.rules`:
   ```text
   # Block external LAN access to LiteLLM port 4000 by default
   block in proto tcp to any port 4000

   # Allow local Mac loopback
   pass in quick proto tcp from 127.0.0.1 to any port 4000

   # Allow Fedora host running Hermes
   pass in quick proto tcp from 192.168.4.19 to any port 4000
   ```
2. Test and load anchor:
   ```bash
   sudo pfctl -vnf /etc/pf.anchors/litellm.rules
   sudo pfctl -a litellm -f /etc/pf.anchors/litellm.rules
   sudo pfctl -a litellm -sr
   ```

---

### Step 2: Deploy / Rebuild Hermes on `192.168.4.19`

Ansible manages the synchronization of `compose.yml`, `Dockerfile`, `config/supervisord.conf`, `.env`, and baseline `config.yaml`:
```bash
./run.sh upgrade --tags docker --limit 192.168.4.19
```

> [!NOTE]
> Ansible automatically:
> 1. Verifies system loadavg is below threshold (`4.0`).
> 2. Pre-creates `/home/shawn/docker/hermes/data` with strict mode `0755`.
> 3. Pre-seeds `/home/shawn/docker/hermes/data/config.yaml` if missing (via `config.yaml.j2`).
> 4. Builds `hermes-desktop:minimal` and restarts containers with `--remove-orphans`.

---

### Step 3: Automated Verification (Recommended)

Verify the entire stack in a single automated pass using the verification runner:
```bash
./run.sh test-hermes
```

This automated suite tests:
1. Local & remote LiteLLM proxy reachability (`HTTP 200` on `/v1/models`).
2. SSH reachability to `192.168.4.19`.
3. Host system load and memory headroom.
4. Workspace directory permissions (`0755`).
5. Container lifecycle (`hermes-gateway` and `hermes-desktop`).
6. Virtual Desktop port `6080` (supervisor `novnc`).
7. TUI gateway bootstrap & WebSocket grant ticket (`gateway_bootstrap.py` as UID 1000).
8. Container-to-Mac cross-host LiteLLM reachability.
9. Active Hermes profile model (`coding-26b`).
10. End-to-end chat completion inference.
11. Local MLX Whisper STT pipeline reachability.
12. GitHub CLI (`gh`) availability and configuration in `hermes-gateway` and `hermes-desktop`.
13. Java 21, Kotlin compiler, and Gradle toolchain availability in `hermes-gateway`.
14. Outbound SSH access from Hermes to cluster nodes (`192.168.4.5`, `192.168.4.18`).

---

### Step 4: Ad-Hoc / Manual Inspection Commands

If debugging a specific component manually:

#### A. Container Status & Startup Logs
```bash
# Check container status
.venv/bin/ansible 192.168.4.19 -m command -a "docker ps --filter name=hermes"

# Check gateway logs (look for HERMES_DASHBOARD_READY)
.venv/bin/ansible 192.168.4.19 -m command -a "docker logs hermes-gateway --tail 30"

# Check desktop sandbox logs
.venv/bin/ansible 192.168.4.19 -m command -a "docker logs hermes-desktop --tail 30"
```

#### B. Internal TUI Gateway Bootstrap & Workspace Permissions
```bash
.venv/bin/ansible 192.168.4.19 -m command -a "docker exec -u hermes hermes-gateway /opt/hermes/.venv/bin/python /opt/hermes/ui-tui/scripts/gateway_bootstrap.py"
```
*Expected Output:* JSON payload containing `url: ws://127.0.0.1:<port>/api/ws` and `hermes-gateway-ticket`.

#### C. LiteLLM Model Catalog & Inference Completion
```bash
# Model catalog check
.venv/bin/ansible 192.168.4.19 -m command -a "docker exec hermes-gateway curl -s -H 'Authorization: Bearer sk-hermes-mac-secret' http://192.168.4.5:4000/v1/models"

# End-to-end inference test
.venv/bin/ansible 192.168.4.19 -m command -a "docker exec hermes-gateway curl -s -X POST http://192.168.4.5:4000/v1/chat/completions -H 'Content-Type: application/json' -H 'Authorization: Bearer sk-hermes-mac-secret' -d '{\"model\": \"coding-26b\", \"messages\": [{\"role\": \"user\", \"content\": \"ping\"}], \"max_tokens\": 100}'"
```

#### D. Profile Management via `hermes` CLI
```bash
# Check resolved model configuration
.venv/bin/ansible 192.168.4.19 -m command -a "docker exec hermes-gateway /opt/hermes/.venv/bin/hermes config get model"

# Update profile manually if needed
.venv/bin/ansible 192.168.4.19 -m command -a "docker exec hermes-gateway /opt/hermes/.venv/bin/hermes config set model.default coding-26b"
.venv/bin/ansible 192.168.4.19 -m command -a "docker exec hermes-gateway /opt/hermes/.venv/bin/hermes config set model.provider custom"
.venv/bin/ansible 192.168.4.19 -m command -a "docker exec hermes-gateway /opt/hermes/.venv/bin/hermes config set model.base_url http://192.168.4.5:4000/v1"
.venv/bin/ansible 192.168.4.19 -m command -a "docker exec hermes-gateway /opt/hermes/.venv/bin/hermes config set model.api_key sk-hermes-mac-secret"
.venv/bin/ansible 192.168.4.19 -m command -a "docker restart hermes-gateway"
```

---

## 3. Client Access Endpoints

| Client / Interface | URL / Endpoint | Credentials | Notes |
|---|---|---|---|
| **macOS Native App** | `/Applications/Hermes.app` | Gateway URL: `http://192.168.4.19:9119`<br>User: `admin` / Pass: `hermesadmin` | Select "Remote gateway" mode |
| **Web Chat Dashboard** | `http://192.168.4.19:9119/` | User: `admin` / Pass: `hermesadmin` | In-browser chat, tool execution trace, workspace inspector |
| **Web Virtual Desktop** | `http://192.168.4.19:6080/` | None (sandboxed) | Right-click for Openbox menu: LXTerminal, Chromium (`--no-sandbox`), ObConf |

---

## 4. Computer-Use Desktop Tooling & Execution

The `hermes-desktop` container provides a complete sandboxed virtual graphical environment for automated computer use and web automation:
* **Display Configuration**: `Xvfb` running on `:1` at `1280x800x24` (24-bit TrueColor strictly required for pixel inspection and screenshotting).
* **Network Isolation**: `x11vnc` listens strictly on `127.0.0.1:5900` inside the container; external access is brokered via `websockify` on port `6080`.
* **Testing Browser & Screen Automation**:
  ```bash
  # Test screenshot tool inside desktop container
  .venv/bin/ansible 192.168.4.19 -m command -a "docker exec -u hermes hermes-desktop /home/hermes/venv/bin/python -c 'import pyautogui; print(pyautogui.size())'"

  # Verify Chromium launch without sandboxing errors
  .venv/bin/ansible 192.168.4.19 -m command -a "docker exec -u hermes hermes-desktop chromium --version"
  ```

---

## 5. Backup, Session Hygiene & Workspace Recovery

Because `192.168.4.19` has `backup_method=none` in inventory, persistent workspace state in `/home/shawn/docker/hermes/data` must be maintained carefully:

### A. Snapshotting / Backing Up Data Directory
To back up conversation histories, memories, and skills to Pi 5 (`192.168.4.5`):
```bash
ssh shawn@192.168.4.19 "rsync -avz --delete /home/shawn/docker/hermes/data/ shawn@192.168.4.5:/mnt/storage/backups/hermes/"
```

### B. Cleaning Up Old Logs & Caches
If disk space on Fedora root partition becomes constrained:
```bash
# Truncate TUI crash logs
ssh shawn@192.168.4.19 '> /home/shawn/docker/hermes/data/logs/tui_gateway_crash.log'

# Vacuum docker build and container logs
./run.sh cleanup --limit 192.168.4.19 -K
```

### C. Safe Profile Reset
If session databases corrupt, reset runtime state without losing custom skills:
```bash
ssh shawn@192.168.4.19 '
  cd /home/shawn/docker/hermes/data
  rm -rf logs/* cache/* *.sqlite *.sqlite-wal
  chmod 755 .
'
./run.sh test-hermes
```

---

## 6. Documentation Router

Refer to the specialized reference documents for detailed troubleshooting and design rationale:

| Reference Document | Key Topics Covered |
|---|---|
| **[references/gotchas.md](references/gotchas.md)** | • Fedora `/etc/timezone` vs `/etc/localtime`<br>• Pre-pulling new / custom build-from-source stacks<br>• Custom Docker context and permissions sync in Ansible<br>• Mac Python 3.15 wheel build failures with LiteLLM<br>• Jinja ad-hoc templating conflicts (`{{.Name}}`, Go templates)<br>• Headless container exit on non-TTY stdin (`fd=0`)<br>• Dashboard basic auth requirements<br>• Docker compose service renaming conflicts<br>• Cold-boot readiness timing (10–15s)<br>• Openbox menu alternatives & Chromium container flags<br>• Docker BuildKit session deadlock & recovery<br>• TUI reconnect loop (`unsafe_control_permissions`)<br>• Model config in `config.yaml` vs Docker env vars<br>• Container Python env lacking PyYAML (use `hermes config` CLI)<br>• macOS PF firewall configuration for LiteLLM port 4000<br>• Automatic baseline profile seeding via `config.yaml.j2`<br>• Context window mismatch (128k vs 256k) between Ollama & LiteLLM |
| **[references/ecosystem-research.md](references/ecosystem-research.md)** | • LiteLLM Homebrew status & `litellm[proxy]` extras<br>• Chromium shared memory limits (`shm_size: 1gb`)<br>• Alpine (`musl`) vs Debian (`glibc`) for computer-use agents<br>• Debian noVNC & websockify routing / asset paths<br>• Xvfb color depth (24-bit TrueColor) requirements<br>• Handling reasoning models (`reasoning_content`) in LiteLLM<br>• Official multi-arch Docker distribution internals<br>• macOS Desktop App remote gateway protocol & auth flow<br>• LiteLLM `/health` 500 Prisma bug vs `/v1/models`<br>• Hermes native Ollama 404 route probe handling<br>• TUI reconnect backoff ladder mechanism<br>• Model aliasing in LiteLLM (`coding-26b`)<br>• Gateway in-memory daemon state vs profile reloading<br>• Context window resolution & metadata overrides in LiteLLM / Hermes |
