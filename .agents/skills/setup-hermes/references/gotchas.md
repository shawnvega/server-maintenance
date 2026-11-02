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
| `Syntax error in template: unexpected '.'` on ad-hoc commands | `-a` string evaluates Jinja expressions on `{{.Name}}` | [5. Ansible Ad-hoc Jinja Templating Conflicts](#5-ansible-ad-hoc-jinja-templating-conflicts) |
| Container logs `Warning: Input is not a terminal (fd=0)` & exits 0 | Default entrypoint starts interactive CLI without daemon flag | [6. Headless Container Exit on Non-TTY Stdin](#6-headless-container-exit-on-non-tty-stdin-fd0) |
| `HERMES_DASHBOARD_INSECURE no longer disables the auth gate` | Upstream June 2026 hardening requires basic auth or OAuth | [7. Dashboard Authentication Hardening](#7-june-2026-dashboard-authentication-hardening) |
| `Conflict. The container name "/hermes-desktop" is already in use` | Service renamed in compose before removing old container | [8. Docker Compose Service Renaming Conflicts](#8-docker-compose-service-renaming-conflicts) |
| `curl: (56) Recv failure` immediately after container start | s6-overlay init stages require 10–15s for migrations & uvicorn | [9. Cold-Boot Dashboard Readiness Delay](#9-cold-boot-dashboard-readiness-delay) |
| `Failed to execute child process "x-terminal-emulator"` or Chromium fails | Missing package / Chromium requires `--no-sandbox` in Docker | [10. Missing Openbox Menu Executables](#10-missing-openbox-menu-executables) |
| `healthcheck failed fatally: only one connection allowed` | BuildKit session deadlocked after abnormal termination | [11. Docker BuildKit Session Deadlock](#11-docker-buildkit-session-deadlock) |
| Countdown banner `"─ retrying in 30s"` & `unsafe_control_permissions` | `/opt/data` is world-writable (`0777`); must be `0755` | [12. TUI Gateway Reconnect Loop](#12-tui-gateway-reconnect-loop-on-world-writable-workspace) |

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
  Running commands like `.venv/bin/ansible ... -m command -a "docker stats --format '{{.Name}}'"` crashes before execution:
  ```text
  [ERROR]: Task failed: Syntax error in template: unexpected '.'
  ```
* **Root Cause**:
  Ansible automatically runs Jinja2 evaluation on arguments passed via `-a`. Double curly braces `{{ ... }}` are parsed as Ansible template expressions rather than Docker format strings.
* **The Fix**:
  Avoid double curly braces in `-a` ad-hoc strings. Use standard command output (`docker stats --no-stream`, `docker ps`) or wrap the command inside a single-quoted shell script or playbook task with `{% raw %} ... {% endraw %}`.

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
