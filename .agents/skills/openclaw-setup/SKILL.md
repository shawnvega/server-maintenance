---
name: openclaw-setup
description: >-
  Use this skill when installing, configuring, troubleshooting, or managing OpenClaw gateways
  and autonomous agents, particularly on Debian/UTM VMs connected to Ollama instances on a host Mac.
---

# OpenClaw Setup & Management Skill

Provisioning, networking, securing, and maintaining OpenClaw on Debian 13 ARM64 UTM VMs backed by Ollama on the host Mac.

For deep configuration schemas, troubleshooting, and local STT builds, refer to:
* **[references/config-and-context.md](references/config-and-context.md)**: Complete `openclaw.json` schema, 32k clamp explanation, and 128k context triad.
* **[references/troubleshooting.md](references/troubleshooting.md)**: Detailed symptoms, root causes, and repairs (SQLite locks, `ldconfig`, Ollama sockets).
* **[references/whisper-cpp.md](references/whisper-cpp.md)**: Building and configuring `whisper.cpp` (`whisper-cli`) for local voice notes.

---

## Quick Triage Decision Matrix

| Symptom / Error | Root Cause | Instant Resolution |
|---|---|---|
| Web UI or CLI shows `32k` / `33k/262k` | Auto-discovered Ollama models clamped to `32768` | Explicitly register model with `contextWindow: 131072` & `contextTokens: 131072` in `openclaw.json`; start a new session |
| `could not verify a usable inference route` | No default route bound to `main` agent | `openclaw models set ollama/gemma4:26b-mlx-code && systemctl --user restart openclaw-gateway.service` |
| Dashboard `Connection refused` from Mac | `gateway.bind` defaults to `loopback` | `openclaw config set gateway.bind lan && systemctl --user restart openclaw-gateway.service` |
| `OpenClawAgentDatabaseLeaseActiveError` | Running `openclaw doctor` while gateway holds SQLite lock | `systemctl --user stop openclaw-gateway.service && openclaw doctor --fix && systemctl --user start openclaw-gateway.service` |
| `curl` to `192.168.64.1:11434` refused | Ollama bound to `127.0.0.1` or blocked by PF | Verify `launchctl getenv OLLAMA_HOST` is `0.0.0.0` and restart Ollama; check `/etc/pf.anchors/ollama.rules` |
| User service stops on SSH logout | Systemd user lingering disabled | `sudo loginctl enable-linger shawn` |

---

## 1. Architecture & Network Topology

* **Host Machine (Mac)**: Runs Ollama (`192.168.64.1:11434` on virtual bridge `vmnet-shared` / `bridge100`).
* **Guest Appliances (Debian 13 ARM64 in UTM)**:
  * Primary: `192.168.64.6` | Experimental: `192.168.64.9`
  * Systemd User Service: `openclaw-gateway.service` (Port `18789` WebSocket & Web Dashboard)
  * Workspace: `~/.openclaw/workspace`
  * Config: `~/.openclaw/openclaw.json`
  * Session DB: `~/.openclaw/agents/main/agent/openclaw-agent.sqlite`

---

## 2. Provisioning & Host Prerequisites

### Guest Appliance (Debian 13 ARM64)
```bash
# 1. Build tools & media utilities
sudo apt update && sudo apt install -y curl wget git make g++ cmake python3 ffmpeg

# 2. Enable systemd user lingering (prevents service stop on SSH logout)
sudo loginctl enable-linger shawn
loginctl show-user shawn -p Linger   # Expect: Linger=yes

# 3. Install OpenClaw (configures Node.js v24+ & ~/.npm-global)
curl -fsSL --proto '=https' --tlsv1.2 https://openclaw.ai/install.sh | bash -s -- --no-onboard --no-prompt --verify
sudo ln -sf /home/shawn/.npm-global/bin/openclaw /usr/local/bin/openclaw
echo 'export PATH="$HOME/.npm-global/bin:$PATH"' >> ~/.bashrc

# 4. Baseline init & gateway daemon
openclaw setup --baseline
openclaw gateway install --port 18789
```

### Host Mac Ollama & PF Firewall
1. **Persist `OLLAMA_HOST=0.0.0.0`** via `~/Library/LaunchAgents/setenv.OLLAMA_HOST.plist` (`launchctl bootstrap gui/$(id -u) ...`), restart `Ollama.app`, and verify `lsof -nP -iTCP:11434 -sTCP:LISTEN` shows `*:11434`.
2. **Isolate port `11434`** to `127.0.0.1` and `192.168.64.0/24` via `/etc/pf.anchors/ollama.rules`:
   ```bash
   sudo pfctl -vnf /etc/pf.anchors/ollama.rules
   sudo pfctl -a ollama -f /etc/pf.anchors/ollama.rules
   sudo pfctl -a ollama -sr
   ```

---

## 3. Operational Runbook & CLI

### Service Lifecycle & Dashboard Token
```bash
# Non-interactive dashboard URL + auth token
openclaw dashboard --json   # http://<vm-ip>:18789/#token=<token>

# Status & logs
openclaw status
openclaw gateway status
systemctl --user status openclaw-gateway.service
journalctl --user -u openclaw-gateway.service -f --no-pager

# Restart gateway
systemctl --user restart openclaw-gateway.service
```

### Configuration & Model Management
Prefer `openclaw config` over hand-editing `~/.openclaw/openclaw.json`:
```bash
openclaw config get gateway.bind
openclaw config set tools.media.audio.enabled true
openclaw config validate

openclaw models set ollama/gemma4:26b-mlx-code
openclaw models list --all
openclaw models status
```

### End-to-End Verification
```bash
# One-shot inference test
openclaw infer model run --prompt "Respond with PONG only"

# Full agent test
openclaw agent --message "Reply with ONE word: SUCCESS"
```

---

## 4. Documentation Router

| Document | Purpose |
|---|---|
| [references/config-and-context.md](references/config-and-context.md) | Full `openclaw.json` template & 128k context-window setup |
| [references/troubleshooting.md](references/troubleshooting.md) | Error diagnosis, SQLite inspection, and recovery |
| [references/whisper-cpp.md](references/whisper-cpp.md) | Local `whisper.cpp` compilation & voice note transcription |
| [docs/architecture.md](../../../docs/architecture.md) | Cluster topology & UTM VM overview |
