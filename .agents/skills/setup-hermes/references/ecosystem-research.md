# Hermes & LiteLLM Ecosystem Research & Technical Notes

This reference details external ecosystem research, upstream library quirks, architecture deep-dives, and performance decisions behind the Hermes Desktop and LiteLLM integration.

---

## Technical Topics Index

1. [LiteLLM Packaging & Homebrew Distribution](#1-litellm-packaging--homebrew-distribution)
2. [Chromium Shared Memory Limits in Docker (`shm_size`)](#2-chromium-shared-memory-limits-in-docker-shm_size-1gb)
3. [Alpine Linux (`musl`) vs. Debian (`glibc`) for Computer Use](#3-alpine-linux-musl-vs-debian-glibc-for-computer-use-agents)
4. [Debian noVNC & Websockify Asset Layout](#4-debian-novnc--websockify-asset-layout)
5. [Xvfb Color Depth & TrueColor Requirements](#5-xvfb-color-depth--truecolor-requirements)
6. [Handling Thinking Models in LiteLLM (`reasoning_content`)](#6-handling-thinking-models-in-litellm-reasoning_content)
7. [Official Multi-Arch Distribution (`nousresearch/hermes-agent:latest`)](#7-official-multi-arch-distribution-nousresearchhermes-agentlatest)
8. [Hermes Desktop macOS Remote Gateway Connection Protocol](#8-hermes-desktop-macos-remote-gateway-connection-protocol)
9. [LiteLLM Proxy Health Check vs Inference Endpoints (`/health` 500 Bug)](#9-litellm-proxy-health-check-vs-inference-endpoints-health-500-bug)
10. [Hermes Native Ollama Route Probes vs OpenAI API Proxy](#10-hermes-native-ollama-route-probes-vs-openai-api-proxy)
11. [TUI Reconnect Backoff Ladder & WebSocket Ticket Grant](#11-tui-reconnect-backoff-ladder--websocket-ticket-grant)
12. [Model Aliasing in LiteLLM & Clean Endpoint Routing (`coding-26b`)](#12-model-aliasing-in-litellm--clean-endpoint-routing-coding-26b)
13. [Gateway In-Memory Daemon State vs Profile Reloading](#13-gateway-in-memory-daemon-state-vs-profile-reloading)
14. [Context Window Resolution & Metadata Overrides in LiteLLM / Hermes](#14-context-window-resolution--metadata-overrides-in-litellm--hermes)

---

### 1. LiteLLM Packaging & Homebrew Distribution
* **Homebrew Formula Status**: There is **no official Homebrew formula** for LiteLLM (`brew install litellm` does not exist).
* **Package Extras Dependency (`litellm[proxy]`)**:
  LiteLLM separates the basic SDK from the proxy server CLI. Running `pip install litellm` installs only the client library. If you invoke `litellm --config ...`, it fails with:
  ```text
  ImportError: Missing dependency No module named 'apscheduler'. Run `pip install 'litellm[proxy]'`
  ```
  The `[proxy]` extra pulls in `fastapi`, `uvicorn`, `apscheduler`, `gunicorn`, and `rq`.
* **Recommended Host Alternatives**:
  1. `pipx install --python /opt/homebrew/bin/python3.12 "litellm[proxy]"`
  2. Official Docker container: `ghcr.io/berriai/litellm:main-latest`

---

### 2. Chromium Shared Memory Limits in Docker (`shm_size: "1gb"`)
* **The Problem**: By default, Docker allocates only **64 MB** of shared memory (`/dev/shm`) to each container.
* **The Failure Mode**: Chromium, Playwright, and Electron browsers rely heavily on `/dev/shm` for GPU rendering, inter-process communication (IPC), and compositing. In an AI agent environment with high-resolution screenshotting, opening heavy JavaScript pages exhausts 64MB almost immediately, causing silent browser crashes with exit code 139 (SIGSEGV) or the infamous `Aw, Snap!` page error.
* **The Fix**: Always set `shm_size: "1gb"` in `compose.yml` for any container running Chromium or Playwright.

---

### 3. Alpine Linux (`musl`) vs. Debian (`glibc`) for Computer Use Agents
* **Playwright Compatibility**: Microsoft Playwright **does not officially support Alpine Linux** (`musl libc`) for its browser drivers (`chromium`, `firefox`, `webkit`). Attempting `playwright install` inside Alpine fails or requires complex community builds.
* **PyPI Wheel Support**: Foundational agent packages (`opencv-python`, `pillow`, `pyautogui`, `pydantic-core`, `tiktoken`) only publish pre-compiled `manylinux` wheels for `glibc`. On Alpine, they either fail to build or require heavy C/C++/Rust build chains (`build-base`, `rust`, `cargo`) that bloat the container image by over 1GB.
* **Conclusion**: `debian:bookworm-slim` provides native `glibc` binary wheel support while keeping idle memory consumption at an identical **~84 MiB RAM**.

---

### 4. Debian noVNC & Websockify Asset Layout
* **Asset Location**: Debian packages `novnc` and `websockify` separately. The HTML5 VNC client files are installed into `/usr/share/novnc/`.
* **Default Page Routing**: The main entrypoint in Debian is `/usr/share/novnc/vnc.html`. If you browse to `http://<host>:6080/`, `websockify` will serve a generic directory listing unless `index.html` exists.
* **The Fix**: Add a symlink during build:
  ```dockerfile
  RUN ln -sf /usr/share/novnc/vnc.html /usr/share/novnc/index.html
  ```
  And start `websockify` pointing to the web root:
  ```ini
  command=/usr/bin/websockify --web /usr/share/novnc 6080 127.0.0.1:5900
  ```

---

### 5. Xvfb Color Depth & TrueColor Requirements
* **Color Depth Necessity**: `Xvfb` must be launched with `-screen 0 1280x800x24 -ac +extension GLX +render -noreset`.
* Setting color depth to 16-bit or 8-bit causes modern Chromium builds to fail launching or render pitch-black frames. 24-bit TrueColor (`depth=24, bpp=32`) is strictly required for `scrot`, `xdotool`, and PyAutoGUI pixel inspection to work reliably.

---

### 6. Handling Thinking Models in LiteLLM (`reasoning_content`)
* **Thinking Token Accounting**: Models like `gemma4:26b-mlx-code` or DeepSeek R1 that support reasoning spend output tokens on their internal thoughts before generating text.
* **Empty Content Pitfall**: If `max_tokens` is configured too low in API requests (e.g. `max_tokens: 20`), the model exhausts its quota inside the thinking trace (`reasoning_content`), returning `finish_reason: "length"` with an empty `content` field.
* **Recommendation**: When configuring Hermes agent prompts, ensure `max_tokens` (or `max_output_tokens`) is set to at least 1024–4096 so reasoning can complete and return actionable tool calls.

---

### 7. Official Multi-Arch Distribution (`nousresearch/hermes-agent:latest`)
* **Image Registry**: Published officially on Docker Hub as `nousresearch/hermes-agent:latest`.
* **Architecture Support**: Multi-arch manifest (`linux/amd64`, `linux/arm64`).
* **Built-in Services**:
  * `s6-rc` supervision tree with `/init` as PID 1.
  * `main-hermes`: Core messaging and tool engine.
  * `dashboard`: Fast uvicorn REST and WebSocket server with embedded React web UI dist (`/opt/hermes/hermes_cli/web_dist`).

---

### 8. Hermes Desktop macOS Remote Gateway Connection Protocol
* **Client App**: `/Applications/Hermes.app` (`com.nousresearch.hermes.setup`, built with Tauri, Rust, and WebKit).
* **Remote Gateway Endpoint**:
  * Connects to HTTP(S) REST and WebSocket on port `9119` (e.g. `http://192.168.4.19:9119`).
  * Supports path prefixes when reverse-proxied (e.g. `https://domain.com/hermes`).
* **Auth Handshake**:
  1. Probes the base URL (`/`). If redirected (`302`) to `/login`, client detects auth requirement.
  2. Submits credentials to `POST /auth/password-login` (`{"provider": "basic", "username": "...", "password": "..."}`).
  3. Receives authenticated session cookie/token and opens WebSocket at `ws://<host>:9119/api/ws`.

---

### 9. LiteLLM Proxy Health Check vs Inference Endpoints (`/health` 500 Bug)
* **The Symptom**:
  Running `curl http://127.0.0.1:4000/health` or `http://192.168.4.8:4000/health` returns:
  ```text
  HTTP/1.1 500 Internal Server Error
  Internal Server Error
  ```
  and `~/Library/Logs/litellm.error.log` reports `ModuleNotFoundError: No module named 'prisma'`.
* **Root Cause**:
  When LiteLLM runs as a stateless local proxy without an external Prisma database configured, its unhandled exception middleware in `proxy_server.py` (`otel_unhandled_exception_handler`) attempts to inspect `PrismaDBExceptionHandler.is_database_infrastructure_error()`, which attempts to import `prisma`. The missing optional database package causes the health endpoint to throw 500.
* **The Reality**:
  The core OpenAI inference proxy routes (`/v1/models`, `/v1/chat/completions`) are completely unaffected and work normally.
* **The Rule**:
  **Never use `/health` to evaluate LiteLLM proxy status.** Instead, probe the model catalog or test an inference completion:
  ```bash
  curl -s -H "Authorization: Bearer sk-hermes-mac-secret" http://192.168.4.8:4000/v1/models
  ```

---

### 10. Hermes Native Ollama Route Probes vs OpenAI API Proxy
* **The Symptom**:
  LiteLLM access logs (`~/Library/Logs/litellm.log`) show periodic 404 warnings from Hermes:
  ```text
  INFO: 192.168.4.19 - "GET /api/tags HTTP/1.1" 404 Not Found
  INFO: 192.168.4.19 - "POST /api/show HTTP/1.1" 404 Not Found
  INFO: 192.168.4.19 - "GET /v1/props HTTP/1.1" 404 Not Found
  INFO: 192.168.4.19 - "GET /version HTTP/1.1" 404 Not Found
  ```
* **Root Cause**:
  When configured with an Ollama model name prefix (`ollama/...`), Hermes Agent probes native Ollama API endpoints (`/api/tags`, `/api/show`) first to auto-discover context windows and parameter capabilities.
  Because LiteLLM is strictly an OpenAI-compatible proxy (`/v1/*`), it returns 404 for these native Ollama endpoints.
* **The Reality**:
  Hermes catches these 404s gracefully, falls back to `GET /v1/models`, and uses standard OpenAI `/v1/chat/completions`. These 404 log entries are benign.

---

### 11. TUI Reconnect Backoff Ladder & WebSocket Ticket Grant
* **The Mechanism**:
  When a user connects via browser or desktop to the web terminal on port `9119`, Hermes spawns a Node.js TUI client ([`entry.js`](file:///opt/hermes/ui-tui/dist/entry.js)).
  The TUI uses `gateway_bootstrap.py` to acquire an ephemeral authentication ticket (`protocols: ["hermes-gateway-v1", "hermes-gateway-ticket.<token>"]`) and local WebSocket endpoint (`ws://127.0.0.1:<port>/api/ws`).
* **The Reconnect Ladder**:
  If the bootstrap script fails (e.g. bad file permissions on `/opt/data`), `gatewayClient.ts` executes an exponential backoff reconnect ladder:
  $$\text{delay} = \min(1000 \times 2^{(\text{attempt} - 1)}, 30000)\text{ ms}$$
  `1s -> 2s -> 4s -> 8s -> 16s -> 30s` (capped at 30s).
  This renders directly on the UI above the prompt as `"─ retrying in 30s (attempt X) "`.
  Inspecting `/home/shawn/docker/hermes/data/logs/tui_gateway_crash.log` will reveal the exact lifecycle transitions.

---

### 12. Model Aliasing in LiteLLM & Clean Endpoint Routing (`coding-26b`)
* **The Background**:
  The Mac host runs Ollama serving `gemma4:26b-mlx-code`. In `files/litellm_mac_config.yaml`, three model names are declared:
  1. `ollama/gemma4:26b-mlx-code`
  2. `gemma4:26b-mlx-code`
  3. `coding-26b`
* **Why Use `coding-26b` over `ollama/...` in Hermes**:
  When Hermes encounters a model string containing `ollama/`, its client heuristics infer a native Ollama endpoint and probe `/api/tags` and `/api/show` before falling back to `/v1/*` OpenAI completion routes.
  By aliasing the model as `coding-26b` and setting `provider: "custom"`, Hermes treats LiteLLM strictly as an OpenAI-compatible wire (`POST /v1/chat/completions`), completely avoiding the noisy 404 route probe phase and ensuring clean model labeling in both the CLI and web status bar.

---

### 13. Gateway In-Memory Daemon State vs Profile Reloading
* **The Mechanism**:
  `hermes-gateway` runs persistent background processes:
  * Fast uvicorn REST/WebSocket server for the dashboard
  * Background s6-rc services (`main-hermes` and `dashboard`)
  * Node.js TUI client broker
* **The State Invalidation Trap**:
  When modifying `/opt/data/config.yaml` or running `hermes config set model.default ...`, the CLI updates the YAML file on disk immediately. However, the long-running uvicorn server and active WebSocket sessions maintain the previously instantiated model client in memory until the container or service is explicitly restarted (`docker restart hermes-gateway`). Always trigger a restart after changing core provider credentials or default model selections.

---

### 14. Context Window Resolution & Metadata Overrides in LiteLLM / Hermes
* **The Background**:
  Ollama models report two separate metrics when probed via `/api/show`:
  1. `parameters`: User-defined runtime parameters like `num_ctx: 131072` (128k).
  2. `model_info`: Native architecture configuration like `gemma4.context_length: 262144` (256k).
* **The Interaction with LiteLLM & Hermes**:
  LiteLLM inspects `model_info` from Ollama and reports `max_input_tokens: 262144` on its `/v1/models` route. Hermes's context resolution engine (`agent.model_metadata.get_model_context_length()`) consumes this endpoint directly. If the model alias does not define explicit constraints, Hermes adopts the 256k ceiling.
* **The Fix**:
  LiteLLM allows declarative overrides via the `model_info` stanza in its configuration dictionary:
  ```yaml
  model_list:
    - model_name: coding-26b
      litellm_params:
        model: ollama_chat/gemma4:26b-mlx-code
        api_base: http://127.0.0.1:11434
      model_info:
        max_input_tokens: 131072
        max_output_tokens: 8192
  ```
  This immediately clamps LiteLLM's advertised capacity to 128k, ensuring Hermes compresses context before Ollama's KV cache limit is exceeded.
