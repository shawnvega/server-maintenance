# Homelab Troubleshooting & Failure Mitigation Runbooks

This document provides mitigation procedures, diagnostics, and recovery steps for common operational issues across the homelab infrastructure.

---

## 1. High System Load Halts Upgrade Pipeline

### Symptoms
Stage 1 (`load_check`) in `upgrade.yml` or `upgrade_all.yml` times out waiting for load average to drop below the threshold (`load_threshold`).

### Investigation
Inspect top CPU-consuming processes across the cluster or on the blocked host:
```bash
./run.sh raw 'ps aux --sort=-%cpu | head -n 10'
```
* On `192.168.4.19`: Check Frigate camera ingestion or Hermes model inference.
* On `192.168.4.4` / `.5`: Check Immich machine learning transcode or indexing jobs.

### Mitigation & Overrides
If high load is due to expected batch background processing and it is safe to proceed:
```bash
# Temporarily override load threshold for the run
./run.sh upgrade -K -e "load_threshold=8.0"

# Or skip the load check entirely
./run.sh upgrade -K --skip-tags load_check
```

---

## 2. `rpi-clone` Backup Failures

### Symptoms
Stage 2 (`backup`) halts with an error executing `rpi-clone`.

### Investigation
Check whether the target block device disconnected, went read-only, or shifted device names:
```bash
./run.sh raw 'lsblk'
```
* Compare the actual disk device with `backup_device` configured in `inventory.ini` (e.g. `/dev/mmcblk0` vs `/dev/sda`).
* Check kernel ring buffer for USB reset or I/O errors:
  ```bash
  ssh shawn@192.168.4.4 'sudo dmesg -T | grep -E "(mmc|sd|error)" | tail -n 20'
  ```

### Mitigation
1. If the device node changed (e.g. from `/dev/sda` to `/dev/sdb`), update `inventory.ini`.
2. If the destination card is full or corrupted, format or replace the target SD/USB card.
3. To proceed with OS updates without backing up:
   ```bash
   ./run.sh upgrade -K --skip-tags backup
   ```

---

## 3. Btrfs RAID 1 Drive Degradation or Failure (`192.168.4.18`)

### Symptoms
Btrfs health check (`./run.sh check-btrfs`) reports non-zero `io_errs`, `write_errs`, or `corruption_errs` on `/var`.

### Investigation
Inspect drive mirror allocations and error counters:
```bash
ssh shawn@192.168.4.18 'sudo btrfs filesystem usage -T /var'
ssh shawn@192.168.4.18 'sudo btrfs device stats /var'
```
Check disk presence and partition layout:
```bash
ssh shawn@192.168.4.18 'sudo btrfs filesystem show /var'
```

### Drive Replacement Procedure
Btrfs allows online live replacement of a failing drive without taking the filesystem offline:
1. Attach replacement storage device (e.g. `/dev/sdd`).
2. Start live replacement:
   ```bash
   # Syntax: btrfs replace start <failing_dev_or_devid> <new_dev> <mountpoint>
   ssh shawn@192.168.4.18 'sudo btrfs replace start /dev/sda /dev/sdd /var'
   ```
3. Check replacement progress:
   ```bash
   ssh shawn@192.168.4.18 'sudo btrfs replace status /var'
   ```
4. Once replacement reports `100% finished`, reset device error statistics:
   ```bash
   ssh shawn@192.168.4.18 'sudo btrfs device stats -z /var'
   ```

---

## 4. OverlayFS Pi Fails to Return to Read-Only (`192.168.4.11`)

### Symptoms
Post-upgrade assertion fails with `get_overlay_now != 0`, or manual inspection shows the filesystem is writable.

### Investigation
Check active and configured status:
```bash
ssh shawn@192.168.4.11 'sudo raspi-config nonint get_overlay_now'
ssh shawn@192.168.4.11 'sudo raspi-config nonint get_bootro_now'
```
* Output `0` = Read-Only (Expected normal state)
* Output `1` = Read-Write (Abnormal if maintenance is complete)

### Recovery
Force boot write protection, enable overlay, and reboot:
```bash
ssh shawn@192.168.4.11 'sudo raspi-config nonint enable_bootro && sudo raspi-config nonint do_overlayfs 0 && sudo reboot'
```
Wait 30 seconds, reconnect, and verify:
```bash
ssh shawn@192.168.4.11 'sudo raspi-config nonint get_overlay_now' # Should return 0
```

---

## 5. PiKVM Fails to Return to Read-Only or KVMD Errors (`192.168.4.66`)

### Symptoms
Filesystem remains read-write after update, or `kvmd -m` service verification fails.

### Investigation
Check mount status:
```bash
ssh root@192.168.4.66 'findmnt -n -o OPTIONS /; findmnt -n -o OPTIONS /boot'
```

### Recovery: Read-Only Remount
If filesystems remain read-write (`rw`):
```bash
ssh root@192.168.4.66 '/usr/bin/ro'
```
If `/usr/bin/ro` fails due to open write locks, reboot the device (PiKVM kernel parameters boot directly into `ro` mode):
```bash
ssh root@192.168.4.66 'reboot'
```

### Recovery: KVMD Service Integrity (`kvmd -m`)
> [!CAUTION]
> Do NOT reboot PiKVM if `kvmd -m` integrity verification fails, as it may render remote KVM access inaccessible.

Inspect validation errors:
```bash
ssh root@192.168.4.66 'kvmd -m'
```
* Check for syntax errors in `/etc/kvmd/override.yaml`.
* Check service logs: `journalctl -u kvmd -n 50 --no-pager`.
* Re-run `/usr/bin/pikvm-update --no-reboot` to resolve interrupted package upgrades.

---

## 6. VLC RTSP Video Stream Issues (`192.168.4.18`)

### Symptoms
Fullscreen camera monitor stream on the Chromebook display is frozen or closed.

### Investigation & Restart
Check whether VLC is running:
```bash
ssh shawn@192.168.4.18 'pgrep -x vlc'
```
Restart stream using the dedicated shortcut:
```bash
./run.sh restart-vlc
```
If display errors occur, ensure X11 display session `:0` is active:
```bash
ssh shawn@192.168.4.18 'DISPLAY=:0 xrandr'
```

---

## 7. Hermes Agent Reconnect Loops & LLM Diagnostics (`192.168.4.19`)

### Symptoms
When accessing Hermes via web browser or native desktop app (`http://192.168.4.19:9119`), a banner counts down above the prompt:
```text
─ retrying in 30s (attempt 9)
```
or logs show repeated backoffs in `/home/shawn/docker/hermes/data/logs/tui_gateway_crash.log`:
```text
[tui-parent] [lifecycle] scheduling gateway reconnect in 30000ms (attempt X)
```

### Root Causes
1. **Unsafe Workspace Permissions (`unsafe_control_permissions`)**:
   Hermes strictly validates POSIX permissions on `/opt/data`. If the data directory is world-writable (`mode: 0777`), `gateway_bootstrap.py` refuses to connect to protect the control channel:
   ```text
   gateway inaccessible: unsafe_control_permissions: /opt/data has mode 0777, writable by another user; chmod go-w /opt/data
   ```
2. **UID Mismatch**:
   Inside the container, `gateway_bootstrap.py` must run as the `hermes` user (UID 1000). Running ad-hoc commands as `root` (UID 0) falsely expects UID 0 directory ownership.
3. **Misinterpreting LiteLLM `/health`**:
   Calling `GET /health` on LiteLLM returns `HTTP 500` with `ModuleNotFoundError: No module named 'prisma'` when no database is configured. This is a harmless upstream bug; LiteLLM's inference endpoints (`/v1/models`, `/v1/chat/completions`) work properly.

### Investigation & Verification

1. **Verify Internal Gateway Bootstrap**:
   ```bash
   ssh shawn@192.168.4.19 "docker exec -u hermes hermes-gateway /opt/hermes/.venv/bin/python /opt/hermes/ui-tui/scripts/gateway_bootstrap.py"
   ```
   * Succeeded if it returns a JSON grant: `{"url": "ws://...", "protocols": [...]}`.
   * Failed if it returns `unsafe_control_permissions` or `unsafe_control_path`.

2. **Verify LiteLLM Connectivity from Container to Mac**:
   ```bash
   ssh shawn@192.168.4.19 "docker exec hermes-gateway curl -s -H 'Authorization: Bearer sk-hermes-mac-secret' http://192.168.4.8:4000/v1/models"
   ```

3. **Verify LLM Inference Completion**:
   ```bash
   ssh shawn@192.168.4.19 "docker exec hermes-gateway curl -s -X POST http://192.168.4.8:4000/v1/chat/completions -H 'Content-Type: application/json' -H 'Authorization: Bearer sk-hermes-mac-secret' -d '{\"model\": \"coding-26b\", \"messages\": [{\"role\": \"user\", \"content\": \"ping\"}], \"max_tokens\": 100}'"
   ```

4. **Verify & Configure Active Model in Hermes**:
   If the web UI or chat status bar displays an unexpected model (e.g. `opus 4.6`) despite `MODEL_NAME` or `OPENAI_BASE_URL` in `compose.yml`, Hermes is reading its default from persistent `/opt/data/config.yaml`:
   ```bash
   # Check resolved model config
   ssh shawn@192.168.4.19 "docker exec hermes-gateway /opt/hermes/.venv/bin/hermes config get model"

   # Configure custom local endpoint
   ssh shawn@192.168.4.19 "docker exec hermes-gateway /opt/hermes/.venv/bin/hermes config set model.default coding-26b"
   ssh shawn@192.168.4.19 "docker exec hermes-gateway /opt/hermes/.venv/bin/hermes config set model.provider custom"
   ssh shawn@192.168.4.19 "docker exec hermes-gateway /opt/hermes/.venv/bin/hermes config set model.base_url http://192.168.4.8:4000/v1"
   ssh shawn@192.168.4.19 "docker exec hermes-gateway /opt/hermes/.venv/bin/hermes config set model.api_key sk-hermes-mac-secret"
   ssh shawn@192.168.4.19 "docker restart hermes-gateway"
   ```

5. **Context Window Mismatch (e.g. 256k instead of 128k)**:
   If Hermes displays `coding 26b │ ... / 256k` despite configuring Ollama with `num_ctx: 131072`:
   * Ollama reports both runtime `num_ctx: 131072` and architectural `context_length: 262144`.
   * LiteLLM defaults to advertising the architectural limit unless overridden.
   * Add explicit `model_info` (`max_input_tokens: 131072`, `max_output_tokens: 8192`) in `files/litellm_mac_config.yaml`.
   * Reload LiteLLM via `launchctl` and restart `hermes-gateway`.

6. **`hermes: command not found` in Virtual Desktop LXTerminal**:
   * **Root Cause**: The web desktop (`http://192.168.4.19:6080`) runs inside `hermes-desktop`, an unprivileged sandbox for UI automation. The agent runtime and `hermes` CLI exist exclusively inside `hermes-gateway`.
   * **Fix**: Run commands targeting `hermes-gateway` via `docker exec`:
     ```bash
     ssh shawn@192.168.4.19 'docker exec -u hermes hermes-gateway /opt/hermes/.venv/bin/hermes <command>'
     ```
     See [docs/workflows.md](workflows.md#8-executing-commands-inside-docker-containers) for details.

### Recovery
Fix host directory permissions to `0755` (`chmod go-w`):
```bash
ssh shawn@192.168.4.19 'chmod 755 /home/shawn/docker/hermes/data'
```
The TUI client will immediately attach on the next tick:
```text
[tui-parent] [lifecycle] attached shared gateway recover url=ws://127.0.0.1:...
```
and the countdown banner will disappear. Ensure `tasks/restart_docker_stack.yml` keeps `mode: '0755'`.

---

## 9. Homepage Dashboard Common Errors (`192.168.4.5`)

### 1. Host Validation Failed (`400 Bad Request`)
* **Symptom**: Accessing `http://192.168.4.5:3001` or `http://192.168.4.5` returns HTTP 400 with `{"error":"Host validation failed. See logs for more details."}`.
* **Root Cause**: Modern Next.js 16 host header protection requires authorized hosts/ports.
* **Fix**: Ensure `HOMEPAGE_ALLOWED_HOSTS` environment variable is defined in `compose/192.168.4.5/homepage/docker-compose.yml`:
  ```yaml
  environment:
    - HOMEPAGE_ALLOWED_HOSTS=192.168.4.5,192.168.4.5:3001,localhost,localhost:3001,127.0.0.1,127.0.0.1:3001,*.vvvega.com,*.local,*.home,*.lan,*
  ```

### 2. Glances Widget: `TypeError: Cannot read properties of undefined (reading 'match')`
* **Symptom**: Monitoring cards for Glances crash on the frontend with `TypeError: Cannot read properties of undefined (reading 'match')`.
* **Root Cause**: Homepage's Glances component evaluates `widget.metric.match(...)`. If `metric:` is omitted in `services.yaml`, `widget.metric` is `undefined`, crashing the client runtime.
* **Fix**: Always specify `metric: cpu` (or `memory`, `containers`, `process`) in `services.yaml`:
  ```yaml
  widget:
    type: glances
    url: http://192.168.4.5:61208
    version: 4
    metric: cpu
  ```

### 3. Bookmarks: `TypeError: Failed to construct 'URL': Invalid URL`
* **Symptom**: Quicklinks section crashes with `TypeError: Failed to construct 'URL': Invalid URL`.
* **Root Cause**: In YAML, putting `- icon:` and `- href:` on separate dashed lines creates two distinct list items; the first item has no `href`, resulting in `new URL(undefined)`.
* **Fix**: Group all properties under a single dictionary item per bookmark:
  ```yaml
  - Homelab Quicklinks:
      - GitHub:
          - abbr: GH
            href: https://github.com/
            icon: github.png
  ```

### 4. Docker Socket Permission Denied: `EACCES /var/run/docker.sock`
* **Symptom**: Homepage logs report `error: <dockerStatuses> Error: connect EACCES /var/run/docker.sock`.
* **Root Cause**: On Debian/Pi OS, `/var/run/docker.sock` has group ownership `docker` (GID `990`). If Homepage runs with `PGID=1000`, it cannot read the socket.
* **Fix**: Set `PGID=990` in `compose/192.168.4.5/homepage/docker-compose.yml`.

### 5. Frigate NVR Connection Refused (`http://...:5000`)
* **Symptom**: Clicking the Frigate tile in Homepage fails with `ERR_CONNECTION_REFUSED` or curl returns `Failed to connect port 5000: Connection refused`.
* **Root Cause**: Frigate 0.14+ deprecates unauthenticated port 5000 ingress. The host container compose configuration maps host port `8971` with HTTPS TLS (`0.0.0.0:8971->8971/tcp`), leaving internal container port `5000` unexposed.
* **Fix**: Configure `href: https://192.168.4.19:8971` and `ping: 192.168.4.19` in `services.yaml`.

### 6. Container Failed to Start: `RWLayer of container ... is unexpectedly nil`
* **Symptom**: Starting or restarting an existing Docker container (e.g. `glances` on Chromebook `192.168.4.18`) fails with `Error response from daemon: RWLayer of container ... is unexpectedly nil`.
* **Root Cause**: Occurs when Docker daemon restarts, root or storage paths migrate (such as `/var` Btrfs RAID 1 migration), or overlay2/btrfs mount graph driver cache desynchronizes from container metadata.
* **Fix**: Force recreate the container stack cleanly:
  ```bash
  docker compose -f /home/shawn/docker/<service>/compose.yml up -d --force-recreate
  ```
