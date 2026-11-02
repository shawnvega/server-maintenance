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
* **[references/gotchas.md](references/gotchas.md)**: 12 battle-tested gotchas, symptoms, root causes, and fixes.
* **[references/ecosystem-research.md](references/ecosystem-research.md)**: Research on LiteLLM packaging, Chromium shared memory, TrueColor, and auth handshakes.

---

## 1. Quick Reference & Architecture

* **Host Machine (`192.168.4.19`)**:
  * OS: Fedora Linux 43 x86_64, Btrfs root. Hardware: Intel Core i5-8200Y, 8GB RAM.
  * Co-located workload: Frigate NVR (Coral TPU + `/dev/dri/renderD128` Intel VAAPI).
* **Dual-Container Stack (`compose/192.168.4.19/hermes/`)**:
  * **`hermes-gateway`** (Port **`9119`**): Core agent runtime, tool execution engine, session store, authenticated REST/WebSocket dashboard (`nousresearch/hermes-agent:latest`).
  * **`hermes-desktop`** (Port **`6080`**): Sandboxed virtual desktop (`hermes-desktop:minimal`) running `Xvfb` (display `:1`), `openbox`, `lxterminal`, `chromium` (`--no-sandbox`), and `noVNC`.
  * **Shared Workspace**: `/home/shawn/docker/hermes/data` mounted to `/opt/data` (gateway) and `/home/hermes/workspace` (desktop).
* **LLM Provider (Host Mac at `192.168.4.8`)**:
  * Engine: Local Ollama serving `gemma4:26b-mlx-code`.
  * Proxy: LiteLLM proxy on `0.0.0.0:4000` with Bearer token authentication (`sk-hermes-mac-secret`), managed via macOS LaunchAgent (`~/Library/LaunchAgents/com.litellm.proxy.plist`).

### Core Invariants

> [!IMPORTANT]
> 1. **Workspace Permissions (`0755`)**: Host directory `/home/shawn/docker/hermes/data` must strictly be mode `0755` (`go-w`) and owned by UID 1000 (`shawn`). Never use `0777` (world-writable), which trips Hermes internal security gates (`unsafe_control_permissions`) and traps the chat UI in an endless 30s reconnect loop.
> 2. **Fedora Timezone**: Fedora has no `/etc/timezone`. Mount **only** `/etc/localtime:/etc/localtime:ro`.
> 3. **LiteLLM Health Probes**: Never use `/health` to evaluate LiteLLM proxy status (stateless mode returns 500 due to an upstream Prisma check bug). Probe `GET /v1/models` instead.

---

## 2. Operational Runbook

### Step 1: Manage LiteLLM Proxy on Mac
LiteLLM runs as a persistent user LaunchAgent on macOS (`~/Library/LaunchAgents/com.litellm.proxy.plist`):
```bash
# Inspect status & PID
launchctl print gui/$(id -u)/com.litellm.proxy

# Stop service
launchctl bootout gui/$(id -u)/com.litellm.proxy

# Start / Reload service
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.litellm.proxy.plist

# Inspect logs
tail -n 30 ~/Library/Logs/litellm.log
```

### Step 2: Deploy / Rebuild Hermes on `192.168.4.19`
Deploy configuration changes and rebuild custom container images via Ansible:
```bash
./run.sh upgrade --tags docker --limit 192.168.4.19
```

### Step 3: Verify Container Health
Check container state and inspect startup logs (allow ~10–15s for gateway initialization):
```bash
# Check container status
.venv/bin/ansible 192.168.4.19 -m command -a "docker ps --filter name=hermes"

# Check gateway logs (look for HERMES_DASHBOARD_READY)
.venv/bin/ansible 192.168.4.19 -m command -a "docker logs hermes-gateway --tail 30"

# Check desktop sandbox logs
.venv/bin/ansible 192.168.4.19 -m command -a "docker logs hermes-desktop --tail 30"
```

### Step 4: Verify End-to-End Connectivity

#### A. Internal TUI Gateway Bootstrap & Workspace Permissions
Confirm the internal gateway grants WebSocket tickets to the TUI without permission rejections:
```bash
.venv/bin/ansible 192.168.4.19 -m command -a "docker exec -u hermes hermes-gateway /opt/hermes/.venv/bin/python /opt/hermes/ui-tui/scripts/gateway_bootstrap.py"
```
*Expected Output:* JSON payload containing `url: ws://127.0.0.1:<port>/api/ws` and `hermes-gateway-ticket`.

#### B. LiteLLM Model Catalog Connectivity
Query the model catalog from inside the gateway container across the LAN to the Mac:
```bash
.venv/bin/ansible 192.168.4.19 -m command -a "docker exec hermes-gateway curl -s -H 'Authorization: Bearer sk-hermes-mac-secret' http://192.168.4.8:4000/v1/models"
```

#### C. End-to-End LLM Completion Test
Send a test inference completion from inside the container through LiteLLM to Ollama:
```bash
.venv/bin/ansible 192.168.4.19 -m command -a "docker exec hermes-gateway curl -s -X POST http://192.168.4.8:4000/v1/chat/completions -H 'Content-Type: application/json' -H 'Authorization: Bearer sk-hermes-mac-secret' -d '{\"model\": \"coding-26b\", \"messages\": [{\"role\": \"user\", \"content\": \"ping\"}], \"max_tokens\": 100}'"
```

---

## 3. Client Access Endpoints

| Client / Interface | URL / Endpoint | Credentials | Notes |
|---|---|---|---|
| **macOS Native App** | `/Applications/Hermes.app` | Gateway URL: `http://192.168.4.19:9119`<br>User: `admin` / Pass: `hermesadmin` | Select "Remote gateway" or "Connect to existing Hermes" mode |
| **Web Chat Dashboard** | `http://192.168.4.19:9119/` | User: `admin` / Pass: `hermesadmin` | Full in-browser web chat, tool execution trace, workspace inspector |
| **Web Virtual Desktop** | `http://192.168.4.19:6080/` | None (sandboxed) | Right-click for Openbox menu: LXTerminal, Chromium (`--no-sandbox`), ObConf |

---

## 4. Documentation & Reference Router

Refer to the specialized reference documents for detailed troubleshooting and design rationale:

| Reference Document | Key Topics Covered |
|---|---|
| **[references/gotchas.md](references/gotchas.md)** | • Fedora `/etc/timezone` vs `/etc/localtime` fix<br>• Pre-pulling new / custom build-from-source stacks<br>• Custom Docker context and permissions sync in Ansible<br>• Mac Python 3.15 wheel build failures with LiteLLM<br>• Jinja ad-hoc templating conflicts (`{{.Name}}`)<br>• Headless container exit on non-TTY stdin (`fd=0`)<br>• June 2026 Dashboard auth requirements<br>• Container naming conflict during compose rename<br>• Cold-boot readiness timing (10–15s)<br>• Openbox menu alternatives & Chromium container flags<br>• Docker BuildKit session deadlock & recovery<br>• TUI reconnect loop (`unsafe_control_permissions`) |
| **[references/ecosystem-research.md](references/ecosystem-research.md)** | • LiteLLM Homebrew status & `litellm[proxy]` extras<br>• Chromium shared memory limits (`shm_size: 1gb`)<br>• Alpine (`musl`) vs Debian (`glibc`) for computer-use agents<br>• Debian noVNC & websockify routing / asset paths<br>• Xvfb color depth (24-bit TrueColor) requirements<br>• Handling reasoning models (`reasoning_content`) in LiteLLM<br>• Official multi-arch Docker distribution internals<br>• macOS Desktop App remote gateway protocol & auth flow<br>• LiteLLM `/health` 500 Prisma bug vs `/v1/models`<br>• Hermes native Ollama 404 route probe handling<br>• TUI reconnect backoff ladder mechanism |
