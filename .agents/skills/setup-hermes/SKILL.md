---
name: setup-hermes
description: >-
  Use this skill when provisioning, configuring, troubleshooting, or upgrading the Hermes
  desktop agent container on Fedora (192.168.4.19), connecting it to LiteLLM on the host Mac,
  or managing custom Docker build stacks in Ansible.
---

# Hermes Desktop Setup & Troubleshooting Skill

This skill documents the end-to-end architecture, deployment workflow, critical lessons learned/gotchas, and findings from external ecosystem research when running the **Hermes Desktop Agent** on `192.168.4.19` backed by **LiteLLM / Ollama** on the local Mac (`192.168.4.8`).

---

## 1. Architecture Overview

* **Host Machine (`192.168.4.19`)**:
  * OS: Fedora Linux 43 x86_64, Kernel 7.2+, Btrfs root.
  * Hardware: Intel Core i5-8200Y (2 cores / 4 threads, 5W TDP), 8GB RAM.
  * Primary Co-located Workload: **Frigate NVR** (utilizing Coral TPU and `/dev/dri/renderD128` Intel VAAPI).
* **Dual-Container Topology (`docker/hermes`)**:
  1. **Hermes Gateway & Dashboard (`hermes-gateway`)**:
     * Image: Official multi-arch `nousresearch/hermes-agent:latest` (Debian trixie + s6-overlay).
     * Role: Core agent runtime, tool registry, session persistence, skills sync, and authenticated REST/WebSocket dashboard on port **`9119`**.
     * Resource Caps: `mem_limit: 2560m`, `mem_reservation: 1024m`, `cpus: 1.5`, `shm_size: 1gb`.
  2. **Virtual Desktop Sandbox (`hermes-desktop`)**:
     * Image: `hermes-desktop:minimal` (Debian bookworm-slim + `glibc`).
     * Desktop Stack: `Xvfb` (display `:1`), `openbox` window manager (~15MB RAM), `x11vnc`, `noVNC` / `websockify` on port **`6080`**.
     * Role: Sandboxed graphical desktop environment for browser tools, computer use, and visual live inspection.
     * Resource Caps: `mem_limit: 1536m`, `mem_reservation: 512m`, `cpus: 1.0`, `shm_size: 1gb`.
  * **Shared Workspace**: `/home/shawn/docker/hermes/data` (`mode: 0777`) mounted to `/opt/data` in the gateway and `/home/hermes/workspace` in the desktop sandbox.
* **LLM Inference Provider (Host Mac at `192.168.4.8`)**:
  * Engine: Local Ollama serving `gemma4:26b-mlx-code`.
  * Proxy: LiteLLM running on `0.0.0.0:4000` with Bearer token authentication (`sk-hermes-mac-secret`), managed by a persistent user LaunchAgent (`~/Library/LaunchAgents/com.litellm.proxy.plist`).

---

## 2. Gotchas & "Things That Took Multiple Tries"

### A. The Fedora `/etc/timezone` Mount Failure
* **The Symptom**:
  ```
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

### B. Pre-Pulling New or Build-From-Source Docker Stacks
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

### C. Ansible Synchronization of Custom Build Contexts (`Dockerfile`, `config/`, permissions)
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
  3. Ensure the host workspace directory has `0777` permissions so the unprivileged container user (`hermes`, UID 1000) can read and write files without being blocked by host permissions:
     ```yaml
     - name: "Ensure data workspace directory exists for hermes"
       ansible.builtin.file:
         path: "{{ ansible_facts['user_dir'] }}/docker/hermes/data"
         state: directory
         mode: '0777'
       when: (stack_item | basename) == 'hermes'
     ```
  4. Dynamically append `--build` to `docker compose up -d` if a `Dockerfile` exists:
     ```yaml
     cmd: "docker compose up -d --remove-orphans {{ '--build' if stack_dockerfile_stat.stat.exists else '' }}"
     ```

---

### D. Mac Python 3.15 Pre-release Incompatibility with LiteLLM Wheels
* **The Symptom**:
  Running `pipx install "litellm[proxy]"` on macOS fails with massive compiler traceback errors:
  ```
  error: the configured Python interpreter version (3.15) is newer than PyO3's maximum supported version (3.14)
  error: command ['maturin', 'pep517', 'build-wheel'] returned non-zero exit status 1
  pip failed to build packages: fastuuid, orjson, pydantic-core, tiktoken
  ```
* **Root Cause**:
  Homebrew installed Python 3.15 development/pre-release as the system default. PyPI packages using Rust extensions (`pyo3-ffi`, `maturin`) do not have pre-built wheels for Python 3.15 and will fail compiling from source.
* **The Fix**:
  Force `pipx` to build using stable Python 3.12:
  ```bash
  pipx install --python /opt/homebrew/bin/python3.12 "litellm[proxy]"
  ```

---

### E. Ansible Ad-hoc Jinja Templating Conflicts
* **The Symptom**:
  Running commands like `.venv/bin/ansible ... -m command -a "docker stats --format '{{.Name}}'"` crashes before execution:
  ```
  [ERROR]: Task failed: Syntax error in template: unexpected '.'
  ```
* **Root Cause**:
  Ansible automatically runs Jinja2 evaluation on arguments passed via `-a`. Double curly braces `{{ ... }}` are parsed as Ansible template expressions rather than Docker format strings.
* **The Fix**:
  Avoid double curly braces in `-a` ad-hoc strings. Use standard command output (`docker stats --no-stream`, `docker ps`) or wrap the command inside a single-quoted shell script or playbook task with `{% raw %} ... {% endraw %}`.

---

### F. Headless Container Exit on Non-TTY Stdin (`fd=0`)
* **The Symptom**:
  When starting `nousresearch/hermes-agent:latest` without explicit command arguments in Docker Compose, the container logs:
  ```
  Warning: Input is not a terminal (fd=0).
  Shutting down… (finalizing session)
  Goodbye! ☤
  ```
  and the container exits cleanly with exit code 0 after ~30 seconds.
* **Root Cause**:
  The image entrypoint (`main-wrapper.sh`) defaults to starting the interactive command-line REPL (`hermes`). When run without an interactive TTY, the REPL detects `fd=0` is not a terminal and triggers an orderly session shutdown.
* **The Fix**:
  Always override the compose command to run the daemon service:
  ```yaml
  command: ["gateway", "run"]
  ```

---

### G. June 2026 Dashboard Authentication Hardening
* **The Symptom**:
  Attempting to start `hermes dashboard` bound to `0.0.0.0` with `--insecure` outputs:
  ```
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

### H. Docker Compose Service Renaming Conflicts
* **The Symptom**:
  Renaming a service inside `compose.yml` (e.g. from `hermes:` to `desktop:`) while keeping the container name (`container_name: hermes-desktop`) causes `docker compose up -d` to fail:
  ```
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

### I. Cold-Boot Dashboard Readiness Delay
* **The Symptom**:
  Immediately after container creation, `curl http://192.168.4.19:9119/` fails with connection reset (`curl: (56) Recv failure`) or connection refused (`curl: (7)`).
* **Root Cause**:
  The `nousresearch/hermes-agent:latest` s6-overlay init stages take ~8–12 seconds to complete pre-flight tasks: running `/etc/cont-init.d/01-hermes-setup`, syncing 58 bundled skills into `/opt/data/skills/`, reconciling database profiles, and initializing uvicorn.
* **The Fix**:
  Allow a 10–15 second grace period after container start before verifying readiness. The uvicorn server announces `HERMES_DASHBOARD_READY port=9119` in `docker logs hermes-gateway` when ready.

---

### J. Missing Openbox Menu Executables (`x-terminal-emulator`, `chromium --no-sandbox`, `obconf`)
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

### K. Docker BuildKit Session Deadlock (`Error while dialing: only one connection allowed`)
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

## 3. Key Findings from External Ecosystem Research

### A. LiteLLM Packaging & Homebrew Distribution
* **Homebrew Formula Status**: There is **no official Homebrew formula** for LiteLLM (`brew install litellm` does not exist).
* **Package Extras Dependency (`litellm[proxy]`)**:
  LiteLLM separates the basic SDK from the proxy server CLI. Running `pip install litellm` installs only the client library. If you invoke `litellm --config ...`, it fails with:
  ```
  ImportError: Missing dependency No module named 'apscheduler'. Run `pip install 'litellm[proxy]'`
  ```
  The `[proxy]` extra pulls in `fastapi`, `uvicorn`, `apscheduler`, `gunicorn`, and `rq`.
* **Recommended Host Alternatives**:
  1. `pipx install --python /opt/homebrew/bin/python3.12 "litellm[proxy]"`
  2. Official Docker container: `ghcr.io/berriai/litellm:main-latest`

---

### B. Chromium Shared Memory Limits in Docker (`shm_size: "1gb"`)
* **The Problem**: By default, Docker gives containers only **64 MB** of shared memory (`/dev/shm`).
* **The Failure Mode**: Chromium, Playwright, and Electron browsers rely heavily on `/dev/shm` for GPU rendering, inter-process communication (IPC), and compositing. In an AI agent environment with high-resolution screenshotting, opening heavy JavaScript pages exhausts 64MB almost immediately, causing silent browser crashes with exit code 139 (SIGSEGV) or the infamous `Aw, Snap!` page error.
* **The Fix**: Always set `shm_size: "1gb"` in `compose.yml` for any container running Chromium or Playwright.

---

### C. Alpine Linux (`musl`) vs. Debian (`glibc`) for Computer Use Agents
* **Playwright Compatibility**: Microsoft Playwright **does not officially support Alpine Linux** (`musl libc`) for its browser drivers (`chromium`, `firefox`, `webkit`). Attempting `playwright install` inside Alpine fails or requires complex community builds.
* **PyPI Wheel Support**: Foundational agent packages (`opencv-python`, `pillow`, `pyautogui`, `pydantic-core`, `tiktoken`) only publish pre-compiled `manylinux` wheels for `glibc`. On Alpine, they either fail to build or require heavy C/C++/Rust build chains (`build-base`, `rust`, `cargo`) that bloat the container image by over 1GB.
* **Conclusion**: `debian:bookworm-slim` provides native `glibc` binary wheel support while keeping the idle memory consumption at an identical **~84 MiB RAM**.

---

### D. Debian noVNC & Websockify Asset Layout
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

### E. Xvfb Color Depth & TrueColor Requirements
* **Color Depth Necessity**: `Xvfb` must be launched with `-screen 0 1280x800x24 -ac +extension GLX +render -noreset`.
* Setting color depth to 16-bit or 8-bit will cause modern Chromium builds to fail launching or render pitch-black frames. 24-bit TrueColor (`depth=24, bpp=32`) is strictly required for `scrot`, `xdotool`, and PyAutoGUI pixel inspection to work reliably.

---

### F. Handling Thinking Models in LiteLLM (`reasoning_content`)
* **Thinking Token Accounting**: Models like `gemma4:26b-mlx-code` or DeepSeek R1 that support reasoning spend output tokens on their internal thoughts before generating text.
* **Empty Content Pitfall**: If `max_tokens` is configured too low in API requests (e.g. `max_tokens: 20`), the model exhausts its quota inside the thinking trace (`reasoning_content`), returning `finish_reason: "length"` with an empty `content` field.
* **Recommendation**: When configuring Hermes agent prompts, ensure `max_tokens` (or `max_output_tokens`) is set to at least 1024–4096 so reasoning can complete and return actionable tool calls.

---

### G. Official Multi-Arch Distribution (`nousresearch/hermes-agent:latest`)
* **Image Registry**: Published officially on Docker Hub as `nousresearch/hermes-agent:latest`.
* **Architecture Support**: Multi-arch manifest (`linux/amd64`, `linux/arm64`).
* **Built-in Services**:
  * `s6-rc` supervision tree with `/init` as PID 1.
  * `main-hermes`: Core messaging and tool engine.
  * `dashboard`: Fast uvicorn REST and WebSocket server with embedded React web UI dist (`/opt/hermes/hermes_cli/web_dist`).

---

### H. Hermes Desktop macOS Remote Gateway Connection Protocol
* **Client App**: `/Applications/Hermes.app` (`com.nousresearch.hermes.setup`, built with Tauri, Rust, and WebKit).
* **Remote Gateway Endpoint**:
  * Connects to HTTP(S) REST and WebSocket on port `9119` (e.g. `http://192.168.4.19:9119`).
  * Supports path prefixes when reverse-proxied (e.g. `https://domain.com/hermes`).
* **Auth Handshake**:
  1. Probes the base URL (`/`). If redirected (`302`) to `/login`, client detects auth requirement.
  2. Submits credentials to `POST /auth/password-login` (`{"provider": "basic", "username": "...", "password": "..."}`).
  3. Receives authenticated session cookie/token and opens WebSocket at `ws://<host>:9119/api/ws`.

---

## 4. Step-by-Step Operational Runbook

### Step 1: Manage LiteLLM Proxy on Mac (Automated via LaunchAgent)
LiteLLM runs as a persistent user LaunchAgent on the Mac (`~/Library/LaunchAgents/com.litellm.proxy.plist`) configured to `RunAtLoad` and `KeepAlive` across reboots.

* **Configuration**: `files/litellm_mac_config.yaml`
* **Logs**: `~/Library/Logs/litellm.log` and `~/Library/Logs/litellm.error.log`
* **Service Management Commands**:
  ```bash
  # Check status / PID
  launchctl print gui/$(id -u)/com.litellm.proxy

  # Stop LiteLLM service
  launchctl bootout gui/$(id -u)/com.litellm.proxy

  # Start / Reload LiteLLM service
  launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.litellm.proxy.plist
  ```

---

### Step 2: Deploy / Rebuild Hermes on `192.168.4.19`
Deploy changes via the native repository tooling:
```bash
./run.sh upgrade --tags docker --limit 192.168.4.19
```

---

### Step 3: Verify Container Health
Run ad-hoc checks against both containers:
```bash
# Check running status of both containers
.venv/bin/ansible 192.168.4.19 -m command -a "docker ps --filter name=hermes"

# Check gateway logs (confirm HERMES_DASHBOARD_READY)
.venv/bin/ansible 192.168.4.19 -m command -a "docker logs hermes-gateway --tail 30"

# Check desktop sandbox logs
.venv/bin/ansible 192.168.4.19 -m command -a "docker logs hermes-desktop --tail 30"
```

---

### Step 4: Verify End-to-End LLM Connectivity
Test sending a completion from inside the container through LiteLLM to Ollama:
```bash
.venv/bin/ansible 192.168.4.19 -m command -a "docker exec hermes-gateway curl -s -X POST http://192.168.4.8:4000/v1/chat/completions -H 'Content-Type: application/json' -H 'Authorization: Bearer sk-hermes-mac-secret' -d '{\"model\": \"coding-26b\", \"messages\": [{\"role\": \"user\", \"content\": \"ping\"}], \"max_tokens\": 100}'"
```

---

### Step 5: Access Endpoints

#### A. Hermes Desktop App on Mac (Remote Gateway)
In the native Hermes Desktop macOS application:
1. When prompted for connection mode, choose **Remote gateway** (or **Connect to existing Hermes**).
2. For **Gateway URL**, enter:
   ```text
   http://192.168.4.19:9119
   ```
3. When prompted for authentication, select **Username & Password**:
   * **Username:** `admin` (or `HERMES_DASHBOARD_USERNAME` in `.env`)
   * **Password:** `hermesadmin` (or `HERMES_DASHBOARD_PASSWORD` in `.env`)
4. The desktop app will authenticate and connect to the live remote gateway.

#### B. Web Desktop Sandbox (noVNC)
Navigate in any web browser to view the X11 virtual display:
👉 **`http://192.168.4.19:6080/`**

Right-clicking the desktop displays the Openbox menu:
* **Terminal emulator**: Launches **LXTerminal** (tabbed, UTF-8, clipboard support).
* **Web browser**: Launches **Chromium** (preconfigured with `--no-sandbox` for container safety).
* **ObConf**: Launches the graphical **Openbox Configuration Manager** to manage themes, window borders, and desktop settings.

#### C. Direct In-Browser Chat Dashboard (Web UI)
You do not need the macOS native app to chat with Hermes. You can connect directly in any browser:
👉 **`http://192.168.4.19:9119/`**
* **Username**: `admin` (or `HERMES_DASHBOARD_USERNAME` in `.env`)
* **Password**: `hermesadmin` (or `HERMES_DASHBOARD_PASSWORD` in `.env`)
* Provides a full web chat interface, tool execution logs, conversation histories, and agent workspace inspection.
