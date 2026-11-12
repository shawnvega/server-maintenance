---
name: termux-hermes
description: >-
  Use this skill when connecting to, managing, or troubleshooting Hermes Agent,
  local faster-whisper STT, SSH (port 8022), or termux-services (runit) on the
  Android Pixel 5 Termux host (192.168.4.55) running proot-distro Debian without Docker.
---

# Termux Hermes & Local faster-whisper (`192.168.4.55`)

Guide for operating the non-Docker **Hermes Agent** and local **`faster-whisper`** speech-to-text server on `192.168.4.55` (`pixel-5.localdomain`).

---

## 1. Host & Architecture Quick Reference

* **Host**: Android (`aarch64` Qualcomm Kryo-4XX, ~7.3 GiB RAM), native Termux (`u0_a287`).
* **Not a VM / Not Docker**: Workloads run in **`proot-distro` `debian`** (user-space rootfs translation), supervised by Termux **`termux-services` (`runit`)**.
* **SSH Access**: Port **`8022`** (port `22` is closed):
  ```bash
  ssh -p 8022 shawn@192.168.4.55
  ```
* **Key Paths**:
  * Hermes CLI wrapper: `/data/data/com.termux/files/usr/bin/hermes` (`proot-distro login debian -- /opt/hermes-agent/bin/hermes`)
  * Hermes data/config: `~/.hermes` -> `.../proot-distro/containers/debian/rootfs/root/.hermes`
  * Isolated Whisper venv & server: `/opt/faster-whisper` & `/opt/faster-whisper/server.py` (inside `proot-distro` `debian`)
  * Service definitions: `/data/data/com.termux/files/usr/var/service/{sshd,hermes-dashboard,faster-whisper}`
  * Service logs: `/data/data/com.termux/files/usr/var/log/sv/<service>/current`

---

## 2. Active Services & Ports

| Service | Port | Bind | Role |
|---|---|---|---|
| `sshd` | `8022` | `0.0.0.0` | Termux OpenSSH daemon (`sshd -D -e`) |
| `hermes-dashboard` | `9119` | `0.0.0.0` | Hermes Web UI (`hermes dashboard --host 0.0.0.0 --port 9119 --skip-build --no-open`) |
| `faster-whisper` | `8081` | `127.0.0.1` | OpenAI-compatible `/v1/audio/transcriptions` API (`base.en`, `int8`, 4 threads, Silero VAD) |

* **Port `8080` Note**: Reserved by Termux's `busybox-httpd` service (`down` by default); keep `faster-whisper` on `8081`.

---

## 3. Critical Invariants & Gotchas

1. **`sv` Commands Over Non-Interactive SSH Require Login Shell**:
   * `$SVDIR` and `$LOGDIR` are exported in `$PREFIX/etc/profile.d/start-services.sh` only for login shells.
   * Over `ssh -p 8022 ... '<cmd>'`, wrap commands in `bash -lc`:
     ```bash
     ssh -p 8022 shawn@192.168.4.55 'bash -lc "sv status sshd hermes-dashboard faster-whisper"'
     ```
2. **Restarting `proot`-Wrapped Services (`sv force-restart`)**:
   * `proot` ignores `SIGTERM` during the 7-second `sv restart` window (`timeout: run: ... got TERM`).
   * Always use **`sv force-restart`** or **`sv force-stop`** for `hermes-dashboard` and `faster-whisper`:
     ```bash
     ssh -p 8022 shawn@192.168.4.55 'bash -lc "sv force-restart faster-whisper"'
     ```
3. **`faster-whisper` PyAV Pin (`av>=13,<16`)**:
   * `faster-whisper==1.2.1` passes `metadata_errors="ignore"` to `av.open()`, which was removed in PyAV `19.x` (`open() got an unexpected keyword argument 'metadata_errors'`).
   * Keep `/opt/faster-whisper` separate from `/opt/hermes-agent` and pin `av>=13,<16` (verified working with `av==15.1.0` on `aarch64` Python 3.13).
4. **Auto-Start Scope (Termux Launch vs. Android Boot)**:
   * All three services (`sshd`, `hermes-dashboard`, `faster-whisper`) auto-start when Termux opens via `$PREFIX/etc/profile.d/start-services.sh`.
   * They do **not** auto-start after a full Android reboot until Termux is opened once (unless Termux:Boot is installed with `~/.termux/boot/`).
5. **STT Routing (`local` vs. LAN LiteLLM)**:
   * Local on-device STT (`base.en`): `stt.openai.base_url: http://127.0.0.1:8081/v1`, `stt.openai.model: base.en`
   * LAN Apple Silicon STT (`whisper-large-v3-turbo`): `stt.openai.base_url: http://192.168.4.5:4000/v1`, `stt.openai.model: whisper`
   * Force-restart `hermes-dashboard` after changing `~/.hermes/config.yaml` so the running dashboard reloads settings.

---

## 4. Verification Commands

```bash
# Check service status
ssh -p 8022 shawn@192.168.4.55 'bash -lc "sv status sshd hermes-dashboard faster-whisper"'

# Health & endpoints
ssh -p 8022 shawn@192.168.4.55 'curl -fsS http://127.0.0.1:8081/health && echo "" && curl -s -o /dev/null -w "dashboard HTTP %{http_code}\n" http://127.0.0.1:9119/'

# Inspect recent logs
ssh -p 8022 shawn@192.168.4.55 'tail -n 30 $PREFIX/var/log/sv/faster-whisper/current $PREFIX/var/log/sv/hermes-dashboard/current'
```
