# Hermes Agent Stack: Architecture, Configuration & Recovery

This document details the architecture, operational workflows, and troubleshooting runbooks for the **Hermes Desktop Agent** on `192.168.4.19` connected to **LiteLLM / Ollama** on `192.168.4.5` and the local MLX Whisper transcription daemon.

---

## 1. Architecture & Dual-Container Stack

Host `192.168.4.19` (Fedora Linux 43 x86_64, Btrfs root) runs a dual-container architecture in `compose/192.168.4.19/hermes/`:

| Container | Port | Role & Image | Resource Allocation |
|---|---|---|---|
| **`hermes-gateway`** | `9119` (HTTP/WS)<br>`8642` (OpenAI API) | Agent runtime, CLI, tool execution engine, web dashboard, OpenAI API server (`hermes-gateway:custom`) | `cpus: 1.5`, `mem_limit: 4096m`, `mem_reservation: 1024m` |
| **`hermes-desktop`** | `6081` (HTTP/VNC, `desktop` profile) | Optional unprivileged sandbox for browser/UI automation (`hermes-desktop:minimal`): `Xvfb` (:1, 1280x800), `openbox`, `chromium` (`--no-sandbox`), `noVNC` | `cpus: 1.0`, `mem_limit: 1536m`, `mem_reservation: 512m` |
| **`open-webui`** | `3000` (HTTP WebUI) | Feature-rich AI chat interface connected to Hermes Agent (`:8642`) and LiteLLM (`:4000`) (`ghcr.io/open-webui/open-webui:main`) | `cpus: 1.0`, `mem_limit: 1536m`, `mem_reservation: 512m` |

* **Co-located Workload**: Frigate NVR (Coral TPU + `/dev/dri/renderD128` Intel VAAPI transcoding) shares the host. Resource limits preserve ~4GB RAM for Fedora and Frigate.
* **Shared Storage**: Host directory `/home/shawn/docker/hermes/data` is mounted to `/opt/data` in `hermes-gateway` and `/home/hermes/workspace` in `hermes-desktop`.

---

## 2. Security & Workspace Permissions Invariant

> [!IMPORTANT]
> The host directory `/home/shawn/docker/hermes/data` must strictly have mode `0755` (`go-w`) and ownership UID 1000 (`shawn`). Never set `0777` (world-writable).

Hermes strictly validates POSIX directory permissions on `/opt/data`. If the directory is world-writable, `gateway_bootstrap.py` refuses to connect to prevent unauthorized socket manipulation, triggering a 30s reconnect loop in the web/TUI interface:
```text
gateway inaccessible: unsafe_control_permissions: /opt/data has mode 0777, writable by another user; chmod go-w /opt/data
```

### Permission Fix
```bash
ssh shawn@192.168.4.19 'chmod 755 /home/shawn/docker/hermes/data'
```
Once permissions are corrected, the TUI client immediately reconnects on the next tick.

---

## 3. LLM Backend & LiteLLM Integration

Hermes connects to models served by LiteLLM proxy on Raspberry Pi 5 (`http://192.168.4.5:4000/v1`).

### Default Model Resolution (`config.yaml`)
Hermes resolves its active model configuration from persistent `/opt/data/config.yaml` on the host, **not** from Docker environment variables:

```bash
# Inspect active model configuration
ssh shawn@192.168.4.19 "docker exec hermes-gateway /opt/hermes/.venv/bin/hermes config get model"

# Configure custom local endpoint
ssh shawn@192.168.4.19 "docker exec hermes-gateway /opt/hermes/.venv/bin/hermes config set model.default coding-26b"
ssh shawn@192.168.4.19 "docker exec hermes-gateway /opt/hermes/.venv/bin/hermes config set model.provider custom"
ssh shawn@192.168.4.19 "docker exec hermes-gateway /opt/hermes/.venv/bin/hermes config set model.base_url http://192.168.4.5:4000/v1"
ssh shawn@192.168.4.19 "docker exec hermes-gateway /opt/hermes/.venv/bin/hermes config set model.api_key sk-hermes-mac-secret"
ssh shawn@192.168.4.19 "docker restart hermes-gateway"
```

### Context Window Mismatch (128k vs 256k)
If Hermes displays `coding 26b │ ... / 256k` despite configuring Ollama with `num_ctx: 131072`:
* Ollama reports both runtime `num_ctx: 131072` and architectural `context_length: 262144`.
* LiteLLM advertises the architectural limit unless overridden.
* Ensure explicit `model_info` (`max_input_tokens: 131072`, `max_output_tokens: 8192`) is defined in `compose/192.168.4.5/litellm/config/litellm_config.yaml`.
* Redeploy LiteLLM with `./run.sh litellm` and restart `hermes-gateway`.

### LiteLLM AI Gateway (`192.168.4.5:4000`)
The cluster runs a centralized **LiteLLM Proxy** Docker container on `192.168.4.5:4000` acting as an authenticated 24/7 gateway and fallback router:
* **Deploy & Update**: `./run.sh litellm` (deploys `compose/192.168.4.5/litellm` via `deploy_litellm.yml`).
* **Routing**:
  * **Chat Completions** (`coding-12b`, `coding-26b`, `coding-31b`): Proxies to Apple Silicon Mac Ollama (`192.168.4.8:11434`) with 128k context bounds.
  * **Speech-to-Text** (`whisper`): Proxies to Apple Silicon Mac MLX Whisper (`192.168.4.8:8080/v1`).
  * **Cloud Primary & Fallbacks**: Routes `openrouter-free` and `gemma4-26b-free` with automatic failover cascade: Tier 1 Free Cloud (`:free`) -> Tier 2 Paid Cloud (`google/gemma-4-26b-a4b-it`) -> Tier 3 Local Mac (`coding-26b`) -> Tier 4 Universal Cloud Backup (`google/gemma-4-31b-it`).
  * **Universal Cloud Safety Net**: All local Mac routes (`coding-12b`, `coding-26b`, `coding-31b`) and cloud routes automatically fail over to `google/gemma-4-31b-it` when local hardware is offline or primary cloud endpoints fail.

#### Model Routing & Fallback Reference Table
| Model Alias | Backend | Context Bounds | Role & Failover Cascade |
|---|---|---|---|
| `openrouter-free` | OpenRouter `openrouter/free` | 131k / 16k | **Default**: Free cloud auto-router. Falls back to `google/gemma-4-26b-a4b-it` -> `coding-26b` -> `google/gemma-4-31b-it`. |
| `gemma4-26b-free` | OpenRouter `google/gemma-4-26b-a4b-it:free` | 256k / 16k | Free tier direct Gemma 4 26B. Falls back to `google/gemma-4-26b-a4b-it` -> `coding-26b` -> `google/gemma-4-31b-it`. |
| `google/gemma-4-26b-a4b-it` / `gemma4-26b-paid` | OpenRouter `google/gemma-4-26b-a4b-it` | 256k / 16k | **Paid 26B Route**: High uptime, zero local GPU load. Falls back to `coding-26b` -> `google/gemma-4-31b-it`. |
| `google/gemma-4-31b-it` / `gemma4-31b-paid` | OpenRouter `google/gemma-4-31b-it` | 256k / 16k | **Universal Cloud Backup**: Dense 31B parameter model serving as the ultimate safety net for all cluster workloads. |
| `coding-12b` | Mac Ollama `gemma4:12b-mlx-code` | 131k / 16k | Fast interactive edits, local Metal acceleration. Falls back to `google/gemma-4-31b-it` when Mac is offline. |
| `coding-26b` | Mac Ollama `gemma4:26b-mlx-code` | 131k / 16k | **Local Baseline**: Balanced agentic coding. Falls back to `google/gemma-4-31b-it` when Mac is offline. |
| `coding-31b` | Mac Ollama `gemma4:31b-mlx-code` | 131k / 16k | Deep architectural refactoring. Falls back to `google/gemma-4-31b-it` when Mac is offline. |
| `whisper` / `whisper-1` | Mac MLX Whisper (`:8080/v1`) | Audio STT | Local Metal STT transcription for voice dictation. |
* **Mac Firewall**: Access from Pi 5 to Mac backends (`11434`, `8080`) is gated by the macOS PF firewall (`/etc/pf.anchors/com.homelab.litellm`), configured via `./scripts/setup_mac_firewall.sh`.

### MLX Whisper Voice Dictation & STT (`192.168.4.8:8080`)
Local Apple Silicon Metal acceleration on the host Mac (`192.168.4.8`) powers low-latency speech-to-text dictation for Hermes on `192.168.4.19`:
* **Provisioning**: `./run.sh setup-whisper` runs `scripts/setup_mlx_whisper.sh` to configure the `com.mlx.whisper` LaunchAgent on port `8080`, route transcription through LiteLLM on port `4000`, and run a local self-test.
* **Documentation**: See [.agents/skills/mlx-whisper/SKILL.md](../.agents/skills/mlx-whisper/SKILL.md) for schemas and troubleshooting.

---

## 4. Troubleshooting & Diagnostics Runbooks

### 1. Countdown Banner: `─ retrying in 30s (attempt X)`
* **Symptom**: Web browser or TUI displays a countdown banner above the prompt.
* **Diagnosis**:
  ```bash
  ssh shawn@192.168.4.19 "docker exec -u hermes hermes-gateway /opt/hermes/.venv/bin/python /opt/hermes/ui-tui/scripts/gateway_bootstrap.py"
  ```
  * Returns `{"url": "ws://...", "protocols": [...]}`: Gateway is healthy.
  * Returns `unsafe_control_permissions` or `unsafe_control_path`: Permissions are invalid.
* **Resolution**:
  ```bash
  ssh shawn@192.168.4.19 'chmod 755 /home/shawn/docker/hermes/data'
  ```

### 2. LiteLLM `/health` Returns HTTP 500
* **Symptom**: `curl http://192.168.4.5:4000/health` returns HTTP 500 (`ModuleNotFoundError: No module named 'prisma'`).
* **Root Cause**: LiteLLM upstream stateless bug when no database is configured.
* **Resolution**: **Benign**. Do not probe `/health`. Verify connectivity using `/v1/models`:
  ```bash
  ssh shawn@192.168.4.19 "docker exec hermes-gateway curl -s -H 'Authorization: Bearer sk-hermes-mac-secret' http://192.168.4.5:4000/v1/models"
  ```

### 3. `hermes: command not found` in Desktop LXTerminal
* **Symptom**: Running `hermes` inside the virtual desktop terminal (`http://192.168.4.19:6081`) fails.
* **Root Cause**: `hermes-desktop` is an unprivileged browser sandbox. The agent runtime and CLI exist exclusively inside `hermes-gateway`.
* **Resolution**: Run commands targeting `hermes-gateway` via `docker exec`:
  ```bash
  ssh shawn@192.168.4.19 'docker exec -u hermes hermes-gateway /opt/hermes/.venv/bin/hermes <command>'
  ```

### 4. Voice Dictation / Microphone Disabled in Web UI
* **Symptom**: Microphone button is disabled or fails to capture audio in the browser.
* **Root Cause**: Browsers block `getUserMedia` on plain HTTP origins (`http://192.168.4.19:9119`).
* **Resolution**:
  1. In Chrome/Edge, navigate to `chrome://flags/#unsafely-treat-insecure-origin-as-secure`.
  2. Enable the flag, add `http://192.168.4.19:9119`, and restart the browser.
  3. Ensure local MLX Whisper is provisioned with `./run.sh setup-whisper`.

### 5. Automated Health Verification
Run the automated end-to-end test suite:
```bash
./run.sh test-hermes
```
Verifies gateway bootstrap grant, LiteLLM model listing, test inference completion, STT routes, Hermes OpenAI API server (`:8642`), and Open-WebUI (`:3000`).

---

## 5. Open-WebUI & Client Endpoints

| Client / Interface | URL / Endpoint | Credentials | Role |
|---|---|---|---|
| **Open-WebUI Dashboard** | `http://192.168.4.19:3000/` | Initial admin onboarding | Full-featured ChatGPT-style interface with `hermes-agent` and LiteLLM models |
| **Hermes OpenAI API** | `http://192.168.4.19:8642/v1` | Bearer token (`API_SERVER_KEY`) | OpenAI-compatible endpoint serving `/v1/models` and `/v1/chat/completions` |
| **Hermes Gateway Web UI** | `http://192.168.4.19:9119/` | User: `admin` / Pass: `hermesadmin` | Native web dashboard, session viewer, and tool trace |
| **Hermes Virtual Desktop** | `http://192.168.4.19:6081/` | None (sandboxed, `desktop` profile) | noVNC graphical browser/desktop environment |
| **macOS Native App** | `/Applications/Hermes.app` | Gateway URL: `http://192.168.4.19:9119` | Remote gateway client |

---

## 6. Backup, Consistency & Disaster Recovery

Hermes Agent stores live conversation histories, SQLite databases, skills, memories, and API keys in `/home/shawn/docker/hermes/data` (~5.0 GB raw). A dual-tier automated backup architecture protects this data with zero agent downtime:

* **Tier A (Local Snapshots)**: Rolling hardlink snapshots on Host 19 secondary 6.4TB HDD (`/srv/67e597dd-6061-415d-8a37-2246eabee10a/backups/hermes/`) for sub-minute rollback.
* **Tier B (Off-Host Mirror)**: Replicated to Raspberry Pi 5 central Btrfs storage (`/srv/dev-disk-by-uuid-c1c2d4dd-bc6b-4f1f-88dd-e4c8b48d2c3a/hermes_backup/`) for total disaster recovery.
* **Consistency**: Non-blocking atomic backups of all SQLite databases (`state.db`, `kanban.db`, `projects.db`, etc.) via Python C-API `sqlite3.backup()` with automated `PRAGMA integrity_check` verification.
* **Efficiency**: Excludes disposable caches (`cache/`, `.cache/`, `.gradle/`, `installs/`, temporary archives, runtime locks), reducing snapshot size by >80% to under 900 MB.
* **Workspace Invariant**: Guarantees mode `0755` (`go-w`) and UID `1000` (`shawn`) across backup and restore cycles.

### Running On-Demand Backup
```bash
./run.sh backup-hermes
```

### Automated Cockpit Scheduling
Deploy or update Cockpit automation on Pi 5 (`192.168.4.5:9090`):
```bash
./run.sh deploy-automation
```
Runs nightly at **02:30 AM** via `ansible-backup-hermes.timer`.

### Disaster Recovery Runbooks

#### Fast Local Rollback (< 2 minutes)
```bash
# 1. Stop containers
ssh shawn@192.168.4.19 'cd /home/shawn/docker/hermes && docker compose down'

# 2. Restore data from latest local snapshot
ssh shawn@192.168.4.19 '
  rsync -ah --delete /srv/67e597dd-6061-415d-8a37-2246eabee10a/backups/hermes/latest/ /home/shawn/docker/hermes/data/
  chmod 755 /home/shawn/docker/hermes/data
  chown -R shawn:shawn /home/shawn/docker/hermes/data
'

# 3. Restart and verify
ssh shawn@192.168.4.19 'cd /home/shawn/docker/hermes && docker compose up -d'
./run.sh test-hermes
```

#### Total Host Loss Recovery (from Pi 5 Backup)
```bash
# 1. Restore data directory from Pi 5
ssh shawn@192.168.4.5 '
  rsync -avz -e "ssh -o StrictHostKeyChecking=accept-new" \
  /srv/dev-disk-by-uuid-c1c2d4dd-bc6b-4f1f-88dd-e4c8b48d2c3a/hermes_backup/latest/ \
  shawn@192.168.4.19:/home/shawn/docker/hermes/data/
'

# 2. Enforce permissions
ssh shawn@192.168.4.19 'chmod 755 /home/shawn/docker/hermes/data && chown -R 1000:1000 /home/shawn/docker/hermes/data'

# 3. Rebuild and launch Hermes stack
./run.sh hermes
./run.sh test-hermes
```
