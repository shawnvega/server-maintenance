# Hermes Agent Stack: Architecture, Configuration & Recovery

This document details the architecture, operational workflows, and troubleshooting runbooks for the **Hermes Desktop Agent** on `192.168.4.19` connected to **LiteLLM / Ollama** on `192.168.4.5` and the local MLX Whisper transcription daemon.

---

## 1. Architecture & Dual-Container Stack

Host `192.168.4.19` (Fedora Linux 43 x86_64, Btrfs root) runs a dual-container architecture in `compose/192.168.4.19/hermes/`:

| Container | Port | Role & Image | Resource Allocation |
|---|---|---|---|
| **`hermes-gateway`** | `9119` (HTTP/WS) | Agent runtime, CLI, tool execution engine, web dashboard (`nousresearch/hermes-agent:latest`) | `cpus: 1.5`, `mem_limit: 2560m`, `mem_reservation: 1024m` |
| **`hermes-desktop`** | `6080` (HTTP/VNC) | Unprivileged sandbox for browser/UI automation (`hermes-desktop:minimal`): `Xvfb` (:1, 1280x800), `openbox`, `chromium` (`--no-sandbox`), `noVNC` | `cpus: 1.0`, `mem_limit: 1536m`, `mem_reservation: 512m` |

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
* **Symptom**: Running `hermes` inside the virtual desktop terminal (`http://192.168.4.19:6080`) fails.
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
Verifies gateway bootstrap grant, LiteLLM model listing, test inference completion, and STT routes.
