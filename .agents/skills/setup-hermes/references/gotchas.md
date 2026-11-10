# Hermes Setup Gotchas & Troubleshooting Lessons

This reference details specific failure modes, symptoms, root causes, and fixes discovered when configuring, deploying, and running the Hermes Desktop and Gateway stack on Fedora (`192.168.4.19`).

---

## Quick Reference Index

| Symptom / Topic | Root Cause | Section |
|---|---|---|
| `not a directory: Are you trying to mount a directory onto a file?` | Fedora has no `/etc/timezone`; Docker creates it as a dir | [1. Fedora `/etc/timezone` Mount Failure](#1-the-fedora-etctimezone-mount-failure) |
| Pre-pull task fails with `[Errno 2] No such file or directory` | New or custom build-from-source stacks have no remote image | [2. Pre-Pulling New / Custom Docker Stacks](#2-pre-pulling-new-or-build-from-source-docker-stacks) |
| Container fails with missing `Dockerfile` or volume `EACCES` | Ansible only copied `compose.yml`; permissions not synced | [3. Ansible Custom Build Context Synchronization](#3-ansible-synchronization-of-custom-build-contexts) |
| `pipx install "litellm[proxy]"` fails with PyO3 / maturin errors | Python 3.15 pre-release has no pre-compiled wheels on macOS | [4. Mac Python 3.15 LiteLLM Wheel Failures](#4-mac-python-315-pre-release-incompatibility-with-litellm-wheels) |
| `Syntax error in template: unexpected '.'` on ad-hoc commands | `-a` string evaluates Jinja expressions on `{{.Name}}` / Go templates | [5. Ansible Ad-hoc Jinja Templating Conflicts](#5-ansible-ad-hoc-jinja-templating-conflicts) |
| Container logs `Warning: Input is not a terminal (fd=0)` & exits 0 | Default entrypoint starts interactive CLI without daemon flag | [6. Headless Container Exit on Non-TTY Stdin](#6-headless-container-exit-on-non-tty-stdin-fd0) |
| `HERMES_DASHBOARD_INSECURE no longer disables the auth gate` | Upstream June 2026 hardening requires basic auth or OAuth | [7. Dashboard Authentication Hardening](#7-june-2026-dashboard-authentication-hardening) |
| `Conflict. The container name "/hermes-desktop" is already in use` | Service renamed in compose before removing old container | [8. Docker Compose Service Renaming Conflicts](#8-docker-compose-service-renaming-conflicts) |
| `curl: (56) Recv failure` immediately after container start | s6-overlay init stages require 10–15s for migrations & uvicorn | [9. Cold-Boot Dashboard Readiness Delay](#9-cold-boot-dashboard-readiness-delay) |
| `Failed to execute child process "x-terminal-emulator"` or Chromium fails | Missing package / Chromium requires `--no-sandbox` in Docker | [10. Missing Openbox Menu Executables](#10-missing-openbox-menu-executables) |
| `healthcheck failed fatally: only one connection allowed` | BuildKit session deadlocked after abnormal termination | [11. Docker BuildKit Session Deadlock](#11-docker-buildkit-session-deadlock) |
| Countdown banner `"─ retrying in 30s"` & `unsafe_control_permissions` | `/opt/data` is world-writable (`0777`); must be `0755` | [12. TUI Gateway Reconnect Loop](#12-tui-gateway-reconnect-loop-on-world-writable-workspace) |
| Web UI / TUI shows wrong model (e.g. `opus 4.6`) despite env vars | Hermes reads model config from `/opt/data/config.yaml` | [13. Model Configuration in `config.yaml`](#13-hermes-model-configuration-in-configyaml) |
| `ModuleNotFoundError: No module named 'yaml'` inside container | `/opt/hermes/.venv` lacks PyYAML; use `hermes config` CLI | [14. In-Container Ad-Hoc Python Introspection](#14-in-container-ad-hoc-python-introspection) |
| LiteLLM port 4000 exposed to entire LAN on Mac | Default binding to 0.0.0.0 is open without firewall rules | [15. Mac Host Port 4000 Firewall Exposure](#15-mac-host-port-4000-firewall-exposure-macos-pf) |
| Fresh deploy resets model to `opus 4.6` unless manually configured | Profile `config.yaml` is missing on fresh deployments | [16. Profile Pre-Seeding via `config.yaml.j2`](#16-automatic-profile-pre-seeding-via-configyaml) |
| Hermes shows 256k context window (`.../256k`) instead of 128k | Base architecture metadata reports 256k; LiteLLM lacks `model_info` | [17. Context Window Mismatch (128k vs 256k)](#17-context-window-mismatch-128k-vs-256k-between-ollama-litellm-and-hermes) |
| Voice dictation / mic fails or is disabled in dashboard | Insecure HTTP origin (`getUserMedia`) or missing STT backend | [18. Voice Dictation & MLX Whisper Setup](#18-voice-dictation-speech-to-text-and-mlx-whisper-integration) |
| Web UI model switcher only shows `coding-26b` | Bare `custom` provider probes `/models` without auth (HTTP 401) | [19. Web UI Model Switcher Only Displays Default Model](#19-web-ui-model-switcher-only-displays-default-model-coding-26b) |

---

### 1. The Fedora `/etc/timezone` Mount Failure
* **The Symptom**:
  ```text
  Error response from daemon: failed to create task for container: failed to create shim task:
  OCI runtime create failed: runc create failed: unable to start container process:
  error mounting "/etc/timezone" to rootfs at "/etc/timezone": mount src=/etc/timezone, dst=/etc/timezone,
  flags=MS_BIND|MS_REC: not a directory: Are you trying to mount a directory onto a file?
  ```
* **Root Cause**:
  Debian and Ubuntu define `/etc/timezone` as a text file. **Fedora does NOT have `/etc/timezone`**; it exclusively uses `/etc/localtime` (symlinked to `/usr/share/zoneinfo/...`).
  When Docker encounters a bind mount source path that does not exist on the host, **Docker automatically creates it as a directory**. When `runc` attempts to mount this new host directory over the container's file location, it crashes.
* **The Fix**:
  1. Never mount `/etc/timezone` on Fedora hosts. In `compose.yml`, mount **only** `/etc/localtime`:
     ```yaml
     volumes:
       - /home/shawn/docker/hermes/data:/home/hermes/workspace
       - /etc/localtime:/etc/localtime:ro
     ```
  2. If Docker already created the corrupt `/etc/timezone` directory on the Fedora host, clean it up before retrying:
     ```bash
     ssh shawn@192.168.4.19 'sudo rm -rf /etc/timezone'
     ```

---

### 2. Pre-Pulling New or Build-From-Source Docker Stacks
* **The Symptom**:
  Ansible task `Pull updated Docker images while containers stay online` failed with `[Errno 2] No such file or directory` or aborted when pulling a newly defined stack.
* **Root Cause**:
  In `upgrade.yml` and `upgrade_all.yml`, the pre-pull task iterates over `docker_stacks` using `chdir: "{{ ansible_facts['user_dir'] }}/{{ item }}"`.
  When a new stack is added to `inventory.ini` (e.g. `docker/hermes`), the remote directory does not exist yet because `restart_docker_stack.yml` has not run yet. Furthermore, custom image stacks (`build: .`) do not have remote registry images to pull.
* **The Fix**:
  In `upgrade.yml` and `upgrade_all.yml`, check if the directory and compose file exist before attempting `docker compose pull`:
  ```bash
  stack_dir="{{ ansible_facts['user_dir'] }}/{{ item }}"
  if [ ! -d "$stack_dir" ] || [ ! -f "$stack_dir/compose.yml" -a ! -f "$stack_dir/docker-compose.yml" ]; then
    echo "Stack not initialized yet, skipping pre-pull."
    exit 0
  fi
  cd "$stack_dir"
  for attempt in 1 2 3; do
    if docker compose pull 2>/dev/null; then
      exit 0
    fi
    sleep 5
  done
  exit 0
  ```

---

### 3. Ansible Synchronization of Custom Build Contexts
* **The Symptom**:
  Standard stacks only sync `compose.yml`. A custom container build fails because `Dockerfile` or `supervisord.conf` is missing on the remote host, or the container cannot write to its mounted volume (`EACCES: permission denied`).
* **The Fix**:
  In `tasks/restart_docker_stack.yml`:
  1. Add `Dockerfile` to the fileglob copy task:
     ```yaml
     with_fileglob:
       - "compose/{{ inventory_hostname }}/{{ stack_item | basename }}/compose.yml"
       - "compose/{{ inventory_hostname }}/{{ stack_item | basename }}/Dockerfile"
     ```
  2. Add conditional copy for `config/` subdirectories:
     ```yaml
     - name: "Check if config directory exists for {{ stack_item }}"
       ansible.builtin.stat:
         path: "{{ playbook_dir }}/compose/{{ inventory_hostname }}/{{ stack_item | basename }}/config"
       delegate_to: localhost
       register: stack_config_dir_stat

     - name: "Sync config directory for {{ stack_item }}"
       ansible.builtin.copy:
         src: "{{ playbook_dir }}/compose/{{ inventory_hostname }}/{{ stack_item | basename }}/config"
         dest: "{{ ansible_facts['user_dir'] }}/{{ stack_item }}/"
         mode: '0755'
       when: stack_config_dir_stat.stat.exists and stack_config_dir_stat.stat.isdir
     ```
  3. Ensure the host workspace directory has `0755` permissions (owned by host UID 1000 `shawn`) so the unprivileged container user (`hermes`, UID 1000) can read and write files without triggering Hermes's security check against world-writable directories (`mode 0777`):
     ```yaml
     - name: "Ensure data workspace directory exists for hermes"
       ansible.builtin.file:
         path: "{{ ansible_facts['user_dir'] }}/docker/hermes/data"
         state: directory
         mode: '0755'
       when: (stack_item | basename) == 'hermes'
     ```
  4. Dynamically append `--build` to `docker compose up -d` if a `Dockerfile` exists:
     ```yaml
     cmd: "docker compose up -d --remove-orphans {{ '--build' if stack_dockerfile_stat.stat.exists else '' }}"
     ```

---

### 4. Mac Python 3.15 Pre-release Incompatibility with LiteLLM Wheels
* **The Symptom**:
  Running `pipx install "litellm[proxy]"` on macOS fails with compiler errors:
  ```text
  error: the configured Python interpreter version (3.15) is newer than PyO3's maximum supported version (3.14)
  error: command ['maturin', 'pep517', 'build-wheel'] returned non-zero exit status 1
  pip failed to build packages: fastuuid, orjson, pydantic-core, tiktoken
  ```
* **Root Cause**:
  Homebrew installed Python 3.15 development/pre-release as the system default. PyPI packages using Rust extensions (`pyo3-ffi`, `maturin`) do not have pre-built wheels for Python 3.15 and fail compiling from source.
* **The Fix**:
  Force `pipx` to build using stable Python 3.12:
  ```bash
  pipx install --python /opt/homebrew/bin/python3.12 "litellm[proxy]"
  ```

---

### 5. Ansible Ad-hoc Jinja Templating Conflicts
* **The Symptom**:
  Running commands like `.venv/bin/ansible ... -m command -a "docker stats --format '{{.Name}}'"` or `docker inspect --format '{{json .Config.Env}}'` crashes before execution:
  ```text
  [ERROR]: Task failed: Syntax error in template: unexpected '.'
  # or:
  [ERROR]: Task failed: Finalization of task args for 'ansible.builtin.command' failed: Error while resolving value for '_raw_params': 'json' is undefined
  ```
* **Root Cause**:
  Ansible automatically runs Jinja2 evaluation on arguments passed via `-a`. Any double curly braces `{{ ... }}` (such as Docker Go template formatting) are parsed as Ansible template expressions rather than remote command strings.
* **The Fix**:
  Avoid double curly braces in `-a` ad-hoc strings. Use standard non-formatted command output (e.g. `docker exec <container> env`, `docker stats --no-stream`, `docker ps`), wrap the command inside a single-quoted shell script, or use playbook tasks with `{% raw %} ... {% endraw %}`.

---

### 6. Headless Container Exit on Non-TTY Stdin (`fd=0`)
* **The Symptom**:
  When starting `nousresearch/hermes-agent:latest` without explicit command arguments in Docker Compose, the container logs:
  ```text
  Warning: Input is not a terminal (fd=0).
  Shutting down… (finalizing session)
  Goodbye! ☤
  ```
  and the container exits cleanly with code 0 after ~30 seconds.
* **Root Cause**:
  The image entrypoint (`main-wrapper.sh`) defaults to starting the interactive command-line REPL (`hermes`). When run without an interactive TTY, the REPL detects `fd=0` is not a terminal and triggers an orderly session shutdown.
* **The Fix**:
  Always override the compose command to run the daemon service:
  ```yaml
  command: ["gateway", "run"]
  ```

---

### 7. June 2026 Dashboard Authentication Hardening
* **The Symptom**:
  Attempting to start `hermes dashboard` bound to `0.0.0.0` with `--insecure` outputs:
  ```text
  [dashboard] HERMES_DASHBOARD_INSECURE no longer disables the auth gate.
  [dashboard] A non-loopback dashboard requires an auth provider:
  [dashboard]   set HERMES_DASHBOARD_BASIC_AUTH_USERNAME + _PASSWORD (password)
  [dashboard]   or HERMES_DASHBOARD_OAUTH_CLIENT_ID (OAuth).
  ```
  and the server aborts or redirects all unauthenticated requests to `/login`.
* **Root Cause**:
  In upstream Hermes Agent (June 2026), public unauthenticated dashboard binds were permanently removed to prevent unauthorized execution via dashboard tools.
* **The Fix**:
  In `compose.yml` and `.env.j2`, declare basic authentication credentials:
  ```yaml
  environment:
    - HERMES_DASHBOARD=1
    - HERMES_DASHBOARD_HOST=0.0.0.0
    - HERMES_DASHBOARD_PORT=9119
    - HERMES_DASHBOARD_BASIC_AUTH_USERNAME=${HERMES_DASHBOARD_USERNAME:-admin}
    - HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=${HERMES_DASHBOARD_PASSWORD:-hermesadmin}
  ```
  The native desktop client will automatically prompt for username/password, authenticate against `/auth/password-login`, store the resulting session token, and connect to `/api/ws`.

---

### 8. Docker Compose Service Renaming Conflicts
* **The Symptom**:
  Renaming a service inside `compose.yml` (e.g. from `hermes:` to `desktop:`) while keeping the container name (`container_name: hermes-desktop`) causes `docker compose up -d` to fail:
  ```text
  Error response from daemon: Conflict. The container name "/hermes-desktop" is already in use by container "86b3f3...". You have to remove (or rename) that container to be able to reuse that name.
  ```
* **Root Cause**:
  Docker Compose tries to create the newly named service container before destroying the older service container that shares the same fixed container name.
* **The Fix**:
  Stop and remove the conflicting container before deploying the renamed service:
  ```bash
  ssh shawn@192.168.4.19 'docker rm -f hermes-desktop'
  ```

---

### 9. Cold-Boot Dashboard Readiness Delay
* **The Symptom**:
  Immediately after container creation, `curl http://192.168.4.19:9119/` fails with connection reset (`curl: (56) Recv failure`) or connection refused (`curl: (7)`).
* **Root Cause**:
  The `nousresearch/hermes-agent:latest` s6-overlay init stages take ~8–12 seconds to complete pre-flight tasks: running `/etc/cont-init.d/01-hermes-setup`, syncing bundled skills into `/opt/data/skills/`, reconciling database profiles, and initializing uvicorn.
* **The Fix**:
  Allow a 10–15 second grace period after container start before verifying readiness. The uvicorn server announces `HERMES_DASHBOARD_READY port=9119` in `docker logs hermes-gateway` when ready.

---

### 10. Missing Openbox Menu Executables
* **The Symptom**:
  Right-clicking the desktop in noVNC and clicking:
  - "Terminal emulator" yields: `Failed to execute child process "x-terminal-emulator" (No such file or directory)`.
  - "Web browser" silently fails to launch or exits immediately with exit code 1 (`[ERROR:zygote_host_impl_linux.cc] No usable sandbox!`).
  - "ObConf" fails to open.
* **Root Cause**:
  1. `openbox` default `/etc/xdg/openbox/menu.xml` invokes Debian alternatives `x-terminal-emulator` and `x-www-browser`, as well as `obconf`. Minimal Debian images do not include a terminal emulator package or `obconf`.
  2. `chromium` in Debian fails on startup inside unprivileged Docker containers (`no-new-privileges:true`) because Chromium's setuid sandbox cannot initialize without user namespace privileges.
* **The Fix**:
  1. Install `lxterminal` and `obconf` in the Dockerfile (`apt-get install -y --no-install-recommends lxterminal obconf`). `lxterminal` automatically registers itself as `x-terminal-emulator` via Debian alternatives.
  2. Configure `/etc/chromium.d/no-sandbox` with `export CHROMIUM_FLAGS="$CHROMIUM_FLAGS --no-sandbox"` so Chromium and `x-www-browser` launch reliably inside Docker without modifying system wrappers.

---

### 11. Docker BuildKit Session Deadlock
* **The Symptom**:
  Running `docker compose up -d --remove-orphans --build` hangs indefinitely at the build stage, specifically on `/usr/libexec/docker/cli-plugins/docker-buildx bake`. Inspecting `journalctl -u docker` shows repeating errors:
  ```text
  healthcheck failed fatally: Unavailable: connection error: desc = "transport: Error while dialing: only one connection allowed"
  ```
* **Root Cause**:
  When an existing or previous BuildKit build session does not terminate cleanly, Docker's internal build daemon refuses concurrent connections on the same build endpoint, deadlocking buildx in a futex wait.
* **The Fix**:
  1. Inspect running build processes on the host: `ps -eo pid,user,args | grep buildx`.
  2. Terminate the hung buildx client: `pkill -f docker-buildx`.
  3. Re-run `./run.sh upgrade --tags docker --limit 192.168.4.19`.

---

### 12. TUI Gateway Reconnect Loop on World-Writable Workspace
* **The Symptom**:
  When opening the Hermes chat interface (Web UI or Desktop connected to port `9119`), a countdown banner appears directly above the chat prompt:
  ```text
  ─ retrying in 30s (attempt 9)
  ```
  and `tui_gateway_crash.log` repeatedly logs:
  ```text
  [tui-parent] [lifecycle] scheduling gateway reconnect in 30000ms (attempt 9)
  ```
* **Root Cause & Architecture**:
  The chat terminal runs a Node.js TUI client (`/opt/hermes/ui-tui/dist/entry.js`), which executes `gateway_bootstrap.py` under Python to acquire an internal WebSocket grant (`ws://127.0.0.1:<port>/api/ws`) and an ephemeral authentication ticket (`hermes-gateway-ticket.<token>`) from the background gateway daemon.
  Hermes enforces strict POSIX security permissions on its data directory (`/opt/data`):
  1. **Mode Check**: If the directory has world-writable permissions (`0777`), `gateway_bootstrap.py` fails with:
     ```text
     gateway inaccessible: unsafe_control_permissions
     gateway inaccessible: /opt/data has mode 0777, writable by another user; chmod go-w /opt/data
     ```
  2. **UID Check**: If run under `root` (UID 0), `gateway_bootstrap.py` expects the directory to be owned by UID 0. It must run as the `hermes` container user (UID 1000).
  When `gateway_bootstrap.py` exits non-zero, `gatewayClient.ts` enters an exponential backoff reconnect loop (1s, 2s, 4s, 8s, 16s, capped at 30s), rendering the banner in the UI.
* **Diagnostics**:
  Test running the bootstrap script directly as user `hermes` inside the container:
  ```bash
  ssh shawn@192.168.4.19 "docker exec -u hermes hermes-gateway /opt/hermes/.venv/bin/python /opt/hermes/ui-tui/scripts/gateway_bootstrap.py"
  ```
  A healthy gateway outputs JSON:
  ```json
  {"url": "ws://127.0.0.1:57817/api/ws", "protocols": ["hermes-gateway-v1", "hermes-gateway-ticket.xyz..."], "profile_id": "/opt/data", "instance_id": "..."}
  ```
* **The Fix**:
  Ensure the host data directory is owned by host UID 1000 (`shawn`) and has permissions `0755` (`chmod go-w /home/shawn/docker/hermes/data`):
  ```bash
  ssh shawn@192.168.4.19 'chmod 755 /home/shawn/docker/hermes/data'
  ```
  The TUI immediately recovers and logs:
  ```text
  [tui-parent] [lifecycle] attached shared gateway recover url=ws://127.0.0.1:57817/api/ws
  ```
  and the retry banner disappears. Keep `mode: '0755'` in `tasks/restart_docker_stack.yml`.

---

### 13. Hermes Model Configuration in `config.yaml`
* **The Symptom**:
  The web chat or desktop TUI status bar displays an unexpected default model (e.g. `opus 4.6` in `─ ready │ opus 4.6 │ ...`) even when environment variables like `MODEL_NAME` or `OPENAI_BASE_URL` are passed in `compose.yml`.
* **Root Cause**:
  Upstream Hermes Agent manages model profiles directly in `/opt/data/config.yaml` (under the `model` block: `default`, `provider`, `base_url`, `api_key`). Docker environment variables like `MODEL_NAME` or `.env` `LLM_MODEL` are not used by the runtime when persistent configuration exists in the profile workspace.
* **The Fix**:
  Configure the model directly via the `hermes config` CLI inside `hermes-gateway`:
  ```bash
  # Set default model name (matching LiteLLM or Ollama model)
  docker exec hermes-gateway /opt/hermes/.venv/bin/hermes config set model.default coding-26b

  # Set provider to custom OpenAI-compatible endpoint
  docker exec hermes-gateway /opt/hermes/.venv/bin/hermes config set model.provider custom

  # Set base URL to LiteLLM proxy on the host Mac
  docker exec hermes-gateway /opt/hermes/.venv/bin/hermes config set model.base_url http://192.168.4.8:4000/v1

  # Set API key for LiteLLM Bearer authentication
  docker exec hermes-gateway /opt/hermes/.venv/bin/hermes config set model.api_key sk-hermes-mac-secret

  # Restart gateway to reload the runtime
  docker restart hermes-gateway
  ```
  Verify active model resolution with `docker exec hermes-gateway /opt/hermes/.venv/bin/hermes status`.

---

### 14. In-Container Ad-Hoc Python Introspection
* **The Symptom**:
  Running ad-hoc Python one-liners inside `hermes-gateway` to inspect YAML configuration fails:
  ```bash
  docker exec hermes-gateway /opt/hermes/.venv/bin/python -c "import yaml; ..."
  # Returns: ModuleNotFoundError: No module named 'yaml'
  ```
* **Root Cause**:
  The `nousresearch/hermes-agent` virtual environment (`/opt/hermes/.venv`) does not install the third-party `PyYAML` package directly; it uses `ruamel.yaml` and internal CLI abstractions.
* **The Fix**:
  Use the built-in CLI commands rather than ad-hoc Python scripts:
  * Inspect full configuration: `docker exec hermes-gateway /opt/hermes/.venv/bin/hermes config show`
  * Inspect resolved config path: `docker exec hermes-gateway /opt/hermes/.venv/bin/hermes config path`
  * Inspect a specific section or key: `docker exec hermes-gateway /opt/hermes/.venv/bin/hermes config get model`
  * Inspect active status & providers: `docker exec hermes-gateway /opt/hermes/.venv/bin/hermes status`

---

### 15. Mac Host Port 4000 Firewall Exposure (macOS PF)
* **The Symptom**:
  LiteLLM is started with `--host 0.0.0.0 --port 4000`, making the LLM inference proxy reachable by any device on the local network (192.168.4.x).
* **Root Cause**:
  Binding to all interfaces is necessary so the Fedora container (`192.168.4.19`) can send API requests across the LAN, but macOS has no per-port daemon isolation by default without Packet Filter (`pf`).
* **The Fix**:
  Isolate port 4000 using a dedicated macOS Packet Filter anchor:
  1. Create `/etc/pf.anchors/litellm.rules`:
     ```text
     block in proto tcp to any port 4000
     pass in quick proto tcp from 127.0.0.1 to any port 4000
     pass in quick proto tcp from 192.168.4.19 to any port 4000
     ```
  2. Validate and load the anchor into the active firewall:
     ```bash
     sudo pfctl -vnf /etc/pf.anchors/litellm.rules
     sudo pfctl -a litellm -f /etc/pf.anchors/litellm.rules
     sudo pfctl -a litellm -sr
     ```

---

### 16. Automatic Profile Pre-Seeding via `config.yaml`
* **The Symptom**:
  When spinning up a new Hermes deployment or after wiping the data directory `/home/shawn/docker/hermes/data`, the chat interface defaults to `opus 4.6` despite environment variables in `compose.yml` (`MODEL_NAME=coding-26b`, `OPENAI_BASE_URL=...`), requiring manual CLI intervention.
* **Root Cause**:
  Hermes prioritizes persistent profile settings in `/opt/data/config.yaml`. If the file does not exist, Hermes creates a default configuration pointing to Anthropic/Opus rather than reading Docker compose environment variables.
* **The Fix**:
  Ansible automatically templates `compose/192.168.4.19/hermes/config.yaml.j2` into `/home/shawn/docker/hermes/data/config.yaml` with `force: false`.
  This ensures:
  1. On first-run or clean deployments, the profile is pre-initialized with `model.default: coding-26b`, `provider: custom`, and `base_url: http://192.168.4.8:4000/v1`.
  2. Any subsequent in-app or CLI customizations made by the user are preserved and never overwritten by future Ansible runs.

---

### 17. Context Window Mismatch (128k vs 256k) Between Ollama, LiteLLM, and Hermes
* **The Symptom**:
  In the Hermes chat header or status bar, the model context limit displays `256k` (e.g. `coding 26b │ 17.2k/256k`), even though the underlying Ollama model was explicitly configured with `num_ctx 131072` (128k).
* **Root Cause**:
  1. In Ollama, running `curl http://127.0.0.1:11434/api/show -d '{"name": "gemma4:26b-mlx-code"}'` reveals two distinct context fields:
     - `parameters.num_ctx: 131072` (the configured runtime KV cache limit).
     - `model_info.gemma4.context_length: 262144` (the base model architecture definition).
  2. LiteLLM queries the Ollama model architecture and reports `max_input_tokens: 262144` on `GET /v1/models`, completely ignoring Ollama's runtime `num_ctx` setting.
  3. When an alias like `coding-26b` is configured without explicit token metadata, Hermes resolves context bounds from LiteLLM's advertised model limit or falls back to the 256k ceiling.
  4. **The Hazard**: Hermes's internal context compressor and sliding-window pruner would not engage until past 200k tokens, but Ollama's KV cache is capped at 128k, causing upstream inference errors and failed completions.
* **The Fix**:
  Explicitly specify `model_info` under each model entry in `files/litellm_mac_config.yaml`:
  ```yaml
    - model_name: coding-26b
      litellm_params:
        model: ollama_chat/gemma4:26b-mlx-code
        api_base: http://127.0.0.1:11434
      model_info:
        max_input_tokens: 131072
        max_output_tokens: 8192
  ```
  Then reload LiteLLM and restart the gateway:
  ```bash
  launchctl bootout gui/$(id -u)/com.litellm.proxy
  launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.litellm.proxy.plist
  ssh shawn@192.168.4.19 "docker restart hermes-gateway"
  ```

---

### 18. Voice Dictation, Speech-to-Text, and MLX Whisper Integration
* **The Symptom**:
  Clicking the microphone icon in the Hermes web dashboard fails silently, is greyed out, or raises a permission error (`navigator.mediaDevices.getUserMedia` error). Alternatively, voice transcription returns an internal server error or 500 when processing recorded audio.
* **Root Causes**:
  1. **Browser Security Model (Insecure Origin)**: Modern web browsers strictly forbid microphone capture (`getUserMedia`) on plain HTTP origins that are not `localhost`. Accessing the dashboard directly at `http://192.168.4.19:9119` triggers this block.
  2. **Missing STT Configuration in Hermes**: Hermes has no speech-to-text backend declared by default. Without an `stt:` block in `config.yaml`, the gateway cannot handle transcription uploads.
  3. **Launchd Environment Lacking `ffmpeg` in PATH**: When running an Apple Silicon Whisper server under macOS `launchd`, the default launchd daemon `PATH` does not include `/opt/homebrew/bin`. When `mlx_whisper` invokes `ffmpeg` to transcode browser WebM/Opus audio, it crashes with `[Errno 2] No such file or directory: 'ffmpeg'`.
* **The Fix**:
  1. **Provision MLX Whisper on Host Mac**:
     Run `./run.sh setup-whisper` to provision `com.mlx.whisper` on port 8080 and wire `whisper` into LiteLLM on port 4000.
  2. **Unblock Browser Microphone**:
     In Chrome, Edge, or Brave, open `chrome://flags/#unsafely-treat-insecure-origin-as-secure`, enable the flag, add `http://192.168.4.19:9119`, and relaunch the browser.
  3. **Configure Hermes STT**:
     Ensure `stt` is routed to LiteLLM in `/opt/data/config.yaml`:
     ```yaml
     stt:
       enabled: true
       provider: openai
       openai:
         base_url: http://192.168.4.8:4000/v1
         api_key: sk-hermes-mac-secret
         model: whisper
     ```
  4. **Verify**:
     Run `./run.sh test-hermes` to validate check #11 (MLX Whisper daemon, LiteLLM catalog, and Hermes STT configuration).

---

### 19. Web UI Model Switcher Only Displays Default Model (`coding-26b`)
* **The Symptom**:
  Opening the Hermes Web UI (`http://192.168.4.19:9119`) and clicking the model switcher only displays `coding-26b`, even though LiteLLM on `192.168.4.5:4000` has `coding-12b`, `coding-26b`, and `coding-31b` configured.
* **Root Cause**:
  Configuring `model.provider: custom` invokes Hermes's bare custom provider discovery (`_lap_bare_custom_row()` in `hermes_cli/model_switch_providers.py`), which probes `<base_url>/models` with an empty API key (`""`). Because LiteLLM requires Bearer token authentication (`sk-hermes-mac-secret`), the unauthenticated probe fails with HTTP 401 Unauthorized, and Hermes silently falls back to listing only `model.default`.
* **The Fix**:
  Configure LiteLLM as an authenticated provider under `providers:` in `/opt/data/config.yaml` and set `model.provider: litellm`:
  ```yaml
  model:
    default: coding-26b
    provider: litellm
    base_url: http://192.168.4.5:4000/v1
    api_key: sk-hermes-mac-secret

  providers:
    litellm:
      name: LiteLLM
      base_url: http://192.168.4.5:4000/v1
      api_key: sk-hermes-mac-secret
      models:
        - coding-12b
        - coding-26b
        - coding-31b
      discover_models: false
  ```
  Setting `discover_models: false` and declaring explicit `models:` pins the Web UI dropdown to the three coding models, preventing authentication failures and filtering out internal transcription or raw model tags.
  Then restart `hermes-gateway`:
  ```bash
  ssh shawn@192.168.4.19 "docker restart hermes-gateway"
  ```

