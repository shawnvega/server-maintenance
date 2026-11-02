---
name: openclaw-setup
description: >-
  Use this skill when installing, configuring, troubleshooting, or managing OpenClaw gateways
  and autonomous agents, particularly on Debian/UTM VMs connected to Ollama instances on a host Mac.
---

# OpenClaw Setup & Management Skill

This skill provides step-by-step procedures for provisioning, networking, securing, and maintaining OpenClaw on virtual machines backed by local host LLM providers (Ollama).

---

## 1. Architecture & Network Topology

* **Host Machine (Mac)**: Runs Ollama (`192.168.64.1:11434` on virtual bridge `vmnet-shared` / `bridge100`).
* **Guest Appliances (Debian 13 ARM64 in UTM)**:
  * Primary: `192.168.64.6`
  * Experimental: `192.168.64.9`
  * Systemd User Service: `openclaw-gateway.service`
  * Listening Port: `18789` (WebSocket & Web Dashboard)
  * Default Workspace: `~/.openclaw/workspace`
  * Configuration: `~/.openclaw/openclaw.json`
  * Session Database: `~/.openclaw/agents/main/agent/openclaw-agent.sqlite`

---

## 2. Guest Appliance Provisioning from Scratch (Debian 13 ARM64)

When deploying a fresh Debian 13 VM for OpenClaw:

### A. System Packages & Build Tools
Debian 13 minimal installs may lack `curl`, media tools, and native build headers required for native Node addons and whisper.cpp:
```bash
sudo apt update && sudo apt install -y curl wget git make g++ cmake python3 ffmpeg
```

### B. User Lingering for Systemd (Critical)
On systemd-based Linux systems, user systemd services (`systemctl --user`) terminate when the user disconnects from SSH unless lingering is enabled:
```bash
sudo loginctl enable-linger shawn
loginctl show-user shawn -p Linger   # Verify: Linger=yes
```

### C. Install OpenClaw via Official Installer
Debian's default Node.js (v20.x) does not meet OpenClaw's latest requirements. The official installer automatically configures NodeSource for Node.js v24+ and configures user-local npm prefixes (`~/.npm-global`):
```bash
curl -fsSL --proto '=https' --tlsv1.2 https://openclaw.ai/install.sh | bash -s -- --no-onboard --no-prompt --verify
```

### D. PATH & Global Binary Symlink
The installer places the binary at `~/.npm-global/bin/openclaw`. Ensure it is accessible in all environments (interactive shells, non-interactive SSH, and service managers):
```bash
# Symlink into system path
sudo ln -sf /home/shawn/.npm-global/bin/openclaw /usr/local/bin/openclaw

# Persist in user shell
echo 'export PATH="$HOME/.npm-global/bin:$PATH"' >> ~/.bashrc
```

### E. Baseline Initialization
Create standard baseline folders and default workspace:
```bash
openclaw setup --baseline
```

---

## 3. Host Mac Ollama Prerequisites & Persistence

On macOS, Ollama runs as a GUI application (`/Applications/Ollama.app`) that binds strictly to `127.0.0.1:11434` by default. Requests from the VM to `192.168.64.1:11434` will fail with `Connection refused` unless configured.

### A. Persistent Environment Variable via LaunchAgent
`launchctl setenv` by itself is **temporary** and clears on macOS reboot. To ensure Ollama binds to all interfaces across reboots, use a persistent user LaunchAgent:

**File**: `~/Library/LaunchAgents/setenv.OLLAMA_HOST.plist`
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>setenv.OLLAMA_HOST</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/launchctl</string>
    <string>setenv</string>
    <string>OLLAMA_HOST</string>
    <string>0.0.0.0</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
</dict>
</plist>
```

* **Register & bootstrap the LaunchAgent**:
  ```bash
  launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/setenv.OLLAMA_HOST.plist
  ```
* **Verify active status**:
  ```bash
  launchctl print gui/$(id -u)/setenv.OLLAMA_HOST
  ```
* **Restart Ollama App**:
  Quit Ollama from the macOS menu bar icon and reopen it to apply the new host binding.
* **Verify listening socket**:
  ```bash
  lsof -nP -iTCP:11434 -sTCP:LISTEN
  # Should show: TCP *:11434 (LISTEN)
  ```



---

## 4. Host Network Isolation (macOS PF Firewall)

When `OLLAMA_HOST` is set to `0.0.0.0`, other devices on your home Wi-Fi/LAN (`192.168.4.x`) could theoretically reach Ollama. Use macOS's built-in Packet Filter (`pf`) to isolate port 11434 to the local Mac and the VM only.

### A. Dedicated Anchor File
**File**: `/etc/pf.anchors/ollama.rules`
```text
# Block incoming traffic to Ollama by default
block in proto tcp to any port 11434

# Allow Mac localhost
pass in quick proto tcp from 127.0.0.1 to any port 11434

# Allow the VM virtual bridge subnet
pass in quick proto tcp from 192.168.64.0/24 to any port 11434
```

### B. Validation & Reload Commands
```bash
# Test syntax
sudo pfctl -vnf /etc/pf.anchors/ollama.rules

# Load into the running pf firewall
sudo pfctl -a ollama -f /etc/pf.anchors/ollama.rules

# Inspect active rules
sudo pfctl -a ollama -sr

# Remove/flush rules if needed
sudo pfctl -a ollama -F all
```

---

## 5. OpenClaw Configuration & Gateway Management

Execute commands on the VM via SSH (`ssh shawn@<vm-ip>`):

### A. Complete `~/.openclaw/openclaw.json` Structure
Configure model routing, memory recall, agents default model, and LAN gateway binding:
```json
{
  "models": {
    "providers": {
      "ollama": {
        "baseUrl": "http://192.168.64.1:11434",
        "api": "ollama",
        "apiKey": "ollama:manual",
        "params": {
          "num_ctx": 131072
        },
        "models": [
          {
            "id": "gemma4:26b-mlx-code",
            "name": "gemma4:26b-mlx-code",
            "contextWindow": 131072,
            "contextTokens": 131072,
            "maxTokens": 8192,
            "params": {
              "num_ctx": 131072
            }
          },
          {
            "id": "gemma4:31b-mlx-code",
            "name": "gemma4:31b-mlx-code",
            "contextWindow": 131072,
            "contextTokens": 131072,
            "maxTokens": 8192,
            "params": {
              "num_ctx": 131072
            }
          }
        ]
      }
    }
  },
  "agents": {
    "defaults": {
      "model": "ollama/gemma4:26b-mlx-code"
    },
    "entries": {
      "main": {
        "model": "ollama/gemma4:26b-mlx-code"
      }
    }
  },
  "gateway": {
    "mode": "local",
    "bind": "lan",
    "port": 18789
  },
  "memory": {
    "search": {
      "provider": "none"
    }
  }
}
```

> [!IMPORTANT]
> * **`gateway.bind: "lan"`**: By default OpenClaw binds strictly to `loopback` (`127.0.0.1`). Setting `"lan"` binds to `0.0.0.0`, allowing the web dashboard and WebSocket to be reached from the host Mac browser.
> * **`memory.search.provider: "none"`**: Prevents startup warnings/errors regarding missing `OPENAI_API_KEY` for vector embeddings; switches memory to local keyword-based indexing.
> * **`agents.defaults.model` & `agents.entries.main.model`**: Explicitly defines the inference route for the main agent, preventing `"OpenClaw could not verify a usable inference route"` errors during agent execution.

### B. Context Window & Prompt Budget Configuration
OpenClaw calculates its **Prompt Budget** on the client side:
$$\text{Prompt Budget} = \text{contextWindow} - \text{outputReservation}$$
By default, local/custom models in OpenClaw default to a conservative `contextWindow: 32768` (32k), leaving **24,576 tokens (~24.6k)** for prompt budget ($32,768 - 8,192$ output reserve).

> [!NOTE]
> Adjusting the "Context length" slider in Ollama's macOS GUI Settings **only affects Ollama's built-in desktop chat interface**, not external API clients like OpenClaw.

#### Why Auto-Discovered Ollama Models Get Clamped to 32k
OpenClaw's Ollama extension (`dist/extensions/ollama/provider-discovery.js`) contains an internal hardcoded clamp:
```javascript
const OLLAMA_LOCAL_CONTEXT_TOKENS = 32768;
function capLocalOllamaModelContext(model) {
  // Clamps any auto-discovered local Ollama model to 32768
  return Math.min(OLLAMA_LOCAL_CONTEXT_TOKENS, model.contextWindow);
}
```
When models are dynamically discovered from Ollama's `/api/tags` endpoint without an explicit entry in `models.providers.ollama.models`:
1. `openclaw models list --all` will display them with clamped context (e.g. `33k/262k`).
2. The Web UI Control Dashboard model selector will cap them at **32k**.

#### The Triad of Context Settings:
To guarantee that 128k (`131k`) is used across the Web UI, CLI, and Ollama inference:
1. **`contextWindow: 131072`**: Defines the total context window size used by OpenClaw to compute the prompt budget and manage sliding window pruning.
2. **`contextTokens: 131072`**: Controls the token limit reported in the model catalog and the Web UI model selector pill.
3. **`params.num_ctx: 131072`**: Passed directly into Ollama's API call payload (`/api/chat` or `/api/generate`), instructing Ollama's engine to allocate Unified Memory / KV cache for 128k context.

* **Always use camelCase**: OpenClaw requires `contextWindow` and `contextTokens` (snake_case like `context_window` is silently ignored).
* **Provider-level defaults**: Set `"params": { "num_ctx": 131072 }` under `models.providers.ollama` so any fallback or dynamically invoked model also passes `num_ctx: 131072`.
* **Bake `num_ctx` into custom Modelfile**: In Ollama, ensure your custom model template specifies the context parameter:
  ```dockerfile
  FROM gemma4:26b-mlx
  PARAMETER num_ctx 131072
  ```
  ```bash
  ollama create gemma4:26b-mlx-code -f Modelfile
  ```
* **Memory impact**: A 26B model at 128k context requires an additional 15–25+ GB of Unified Memory for the KV cache. 32k or 64k (`num_ctx: 65536`) is often the practical sweet spot for responsiveness.

### C. Gateway Service Installation & Token Management
* **Install and register systemd user daemon**:
  ```bash
  openclaw gateway install --port 18789
  ```
  *(This automatically generates a cryptographic gateway auth token if none is present).*
* **Retrieve the auth token & dashboard URL**:
  Because `openclaw gateway auth-token --show` blocks outside an interactive TTY, retrieve connection JSON non-interactively:
  ```bash
  openclaw dashboard --json
  # Access URL: http://<vm-ip>:18789/#token=<token>
  ```

### D. Model CLI Operations & Verification
* **Set default model**:
  ```bash
  openclaw models set ollama/gemma4:26b-mlx-code
  ```
* **Inspect model catalog & auth**:
  ```bash
  openclaw models list          # Lists active/configured models
  openclaw models list --all    # Lists all candidate models and effective token limits (e.g. 131k vs 33k/262k)
  openclaw models status        # Verifies provider reachability and authentication
  ```
* **Direct one-shot CLI inference test** (bypasses full agent loop for quick testing):
  ```bash
  openclaw infer model run --prompt "Respond with PONG only"
  ```
* **Agent end-to-end test message**:
  ```bash
  openclaw agent --message "Reply with ONE word: SUCCESS"
  ```

### E. Service Lifecycle & Health
* **Check service status**:
  ```bash
  openclaw status               # Displays active sessions, memory, and context utilization (e.g. 17k/131k)
  openclaw gateway status
  systemctl --user status openclaw-gateway.service
  ```
* **Inspect real-time logs**:
  ```bash
  journalctl --user -u openclaw-gateway.service -f --no-pager
  ```
* **Restart the Gateway**:
  ```bash
  systemctl --user restart openclaw-gateway.service
  ```

> [!NOTE]
> Active sessions in OpenClaw store the model and context window limits in SQLite at the moment of session creation. If an existing session shows a clamped context limit (e.g. 32k), run a fresh query via `openclaw agent --message "..."` or start a new chat in the Web UI to instantiate a session with the full 128k (`131k`) window.

### F. Non-Interactive Configuration Helpers (`openclaw config`)
Instead of hand-editing `~/.openclaw/openclaw.json` (which risks JSON syntax errors or invalid paths), use OpenClaw's schema-validated config subcommands:
* **Read a config section or value**:
  ```bash
  openclaw config get tools.media.audio
  openclaw config get gateway.bind
  ```
* **Set or update a configuration key**:
  ```bash
  openclaw config set tools.media.audio.enabled true
  ```
* **Validate configuration against the current schema**:
  ```bash
  openclaw config validate
  ```

---

## 6. Troubleshooting & Repair

### Web UI or CLI Displays 32k or "33k/262k" Despite 128k Modelfile
1. **Symptom**:
   - The Web UI Control Dashboard model selector shows **32k**.
   - `openclaw models list --all` shows `33k/262k` instead of `131k`.
2. **Cause**:
   - OpenClaw's Ollama discovery extension (`dist/extensions/ollama/provider-discovery.js`) enforces a hardcoded default cap:
     ```javascript
     const OLLAMA_LOCAL_CONTEXT_TOKENS = 32768;
     ```
   - Auto-discovered models from `/api/tags` are automatically clamped by `capLocalOllamaModelContext()` to `Math.min(32768, model.contextWindow)`.
3. **Resolution**:
   - Explicitly register each model in `~/.openclaw/openclaw.json` under `models.providers.ollama.models` with both `contextWindow: 131072` and `contextTokens: 131072`:
     ```json
     {
       "id": "gemma4:26b-mlx-code",
       "name": "gemma4:26b-mlx-code",
       "contextWindow": 131072,
       "contextTokens": 131072,
       "maxTokens": 8192,
       "params": {
         "num_ctx": 131072
       }
     }
     ```
   - Restart the gateway: `systemctl --user restart openclaw-gateway.service`.
   - Verify with `openclaw models list` (should display `Ctx: 131k`).
   - Hard-refresh the browser (`Cmd+Shift+R` or `Ctrl+F5`) on `http://<vm-ip>:18789/` to update the web model selector.

### "OpenClaw could not verify a usable inference route"
1. **Symptom**:
   - When sending a message via `openclaw agent` or the Web UI, an error states `OpenClaw could not verify a usable inference route`.
2. **Cause**:
   - Models are defined in `openclaw.json`, but no default route or agent binding exists for `main`.
3. **Resolution**:
   - Bind the default model via CLI:
     ```bash
     openclaw models set ollama/gemma4:26b-mlx-code
     ```
   - Or ensure `agents` block is explicitly present in `~/.openclaw/openclaw.json`:
     ```json
     "agents": {
       "defaults": { "model": "ollama/gemma4:26b-mlx-code" },
       "entries": { "main": { "model": "ollama/gemma4:26b-mlx-code" } }
     }
     ```
   - Restart the gateway service: `systemctl --user restart openclaw-gateway.service`.

### Prompt Budget Capped at 24.6k Despite 128k in Ollama GUI
1. **Symptom**: OpenClaw status displays `PROMPT BUDGET 14.1k / 24.6k` while Ollama desktop slider is set to 128k.
2. **Cause**:
   - The Ollama desktop GUI slider only affects Ollama's built-in chat window; it does not set API context parameters.
   - OpenClaw defaults unconfigured local models to `contextWindow: 32768`. With an 8k output token reserve ($32,768 - 8,192$), the prompt budget is clamped to $24,576$ tokens ($24.6\text{k}$).
3. **Resolution**:
   - Update `~/.openclaw/openclaw.json` with explicit `contextWindow: 131072`, `contextTokens: 131072`, and `params: { "num_ctx": 131072 }`.
   - Rebuild the custom Ollama model with `PARAMETER num_ctx 131072` in its `Modelfile`.
   - Restart the OpenClaw gateway service (`systemctl --user restart openclaw-gateway.service`).

### Inspecting SQLite Session Store When `sqlite3` CLI is Missing
1. **Symptom**:
   - Need to inspect session metadata, token counts, or schema, but `sqlite3: command not found` on a minimal Debian VM.
2. **Resolution**:
   - Use Python's built-in `sqlite3` module via one-liner:
     ```bash
     # List active sessions and their recorded model / token counts
     python3 -c "import sqlite3; conn = sqlite3.connect('/home/shawn/.openclaw/agents/main/agent/openclaw-agent.sqlite'); c = conn.cursor(); print(c.execute('SELECT session_id, model, max_tokens, updated_at FROM sessions ORDER BY updated_at DESC LIMIT 5').fetchall())"
     ```

### Dashboard Inaccessible from Host Mac (`Connection refused`)
1. **Cause**: `gateway.bind` defaults to `loopback` (`127.0.0.1`).
2. **Resolution**: Set `"bind": "lan"` under `"gateway"` in `~/.openclaw/openclaw.json` and restart the gateway service.

### Missing OpenAI API Key Warning during Doctor or Memory Indexing
1. **Symptom**: `openclaw doctor` warns `Memory search provider is set to "openai" but no API key was found`.
2. **Resolution**: Set `"memory": { "search": { "provider": "none" } }` in `~/.openclaw/openclaw.json` to enable keyword-only recall without an external embedding provider.

### Systemd User Service Terminates on SSH Logout
1. **Cause**: Systemd terminates user session cgroups on logout if lingering is disabled.
2. **Resolution**: Run `sudo loginctl enable-linger $USER` and verify with `loginctl show-user $USER -p Linger`.

### Host Connection Refused (`curl: (7) Failed to connect`)
1. From the VM, ping the host bridge:
   ```bash
   ping -c 2 192.168.64.1
   ```
2. Test Ollama API response from VM:
   ```bash
   curl -s -m 5 http://192.168.64.1:11434/api/tags
   ```
3. If connection refused, check listening socket on the host Mac (`lsof -nP -iTCP:11434 -sTCP:LISTEN`). If listening on `127.0.0.1`, restart Ollama app after verifying `launchctl getenv OLLAMA_HOST` returns `0.0.0.0`.

### Database Integrity or `invalid persisted session row requires repair`
If `openclaw-gateway.service` fails during startup with session row verification errors:
1. Stop the gateway service:
   ```bash
   systemctl --user stop openclaw-gateway.service
   ```
2. Run automated diagnostic repair:
   ```bash
   openclaw doctor --fix
   ```
   * This verifies SQLite integrity, recalculates canonical receipts, ensures model plugin compatibility, and safely restarts the service.

### `openclaw doctor` Fails with `OpenClawAgentDatabaseLeaseActiveError`
1. **Symptom**: Running `openclaw doctor` or `openclaw doctor --fix` reports:
   ```text
   Skipped historical transcript directive migration: OpenClawAgentDatabaseLeaseActiveError: Agent main database is still open in another process; stop that process and rerun openclaw doctor --fix.
   ```
2. **Cause**:
   - The background systemd user service `openclaw-gateway.service` is actively holding SQLite database locks for the agent.
3. **Resolution**:
   - Stop the service before running migrations or diagnostics:
     ```bash
     systemctl --user stop openclaw-gateway.service
     openclaw doctor --fix
     systemctl --user start openclaw-gateway.service
     ```

### `whisper-cli: error while loading shared libraries: libwhisper.so`
1. **Symptom**: Executing `whisper-cli` fails with:
   ```text
   whisper-cli: error while loading shared libraries: libwhisper.so.1: cannot open shared object file: No such file or directory
   ```
2. **Cause**:
   - On Debian systems, `/usr/local/lib` is in `/etc/ld.so.conf.d/libc.conf`, but the dynamic linker cache (`/etc/ld.so.cache`) is not automatically refreshed after `cmake --install`.
3. **Resolution**:
   - Update the dynamic linker cache:
     ```bash
     sudo ldconfig
     ```

---

## 7. Local Speech-to-Text & Voice Notes (`whisper.cpp` Integration)

OpenClaw has native first-class support for local audio transcription (e.g. for inbound Telegram, WhatsApp, or Discord voice notes and audio attachments) via `whisper-cli` from `whisper.cpp` and `ffmpeg`.

### A. Architecture & Auto-Discovery
* **Binary Detection**: OpenClaw looks for `whisper-cli` in the system `$PATH` (`/usr/local/bin/whisper-cli`).
* **Model Discovery Order**:
  1. `WHISPER_CPP_MODEL` environment variable (explicit file override).
  2. `/opt/homebrew/share/whisper-cpp`
  3. `/usr/local/share/whisper-cpp`
  4. `/usr/share/whisper-cpp`
  It scans for `ggml-*.bin` files and prioritizes non-tiny models (`(a.includes("tiny") ? 1 : 0) - (b.includes("tiny") ? 1 : 0) || a.localeCompare(b)`).
* **Audio Transcoding Pipeline**:
  - Inbound voice notes and audio attachments from chat channels typically arrive as Ogg Opus (`.oga` / `.ogg`), MP3, M4A, or FLAC.
  - OpenClaw's internal helper (`resolveCliMediaPath`) detects non-WAV media and automatically invokes `ffmpeg` with:
    ```bash
    ffmpeg -y -i <input> -ac 1 -ar 16000 -c:a pcm_s16le -f wav <output.wav>
    ```
  - It then executes:
    ```bash
    whisper-cli -m <model> -otxt -of <OutputBase> -nt <AttachmentPath>
    ```
    and reads `<OutputBase>.txt` into the agent's turn context.

### B. Building & Installing `whisper.cpp` on Debian 13 ARM64
```bash
# 1. Install prerequisites (build tools + ffmpeg)
sudo apt update && sudo apt install -y cmake g++ make git ffmpeg

# 2. Clone whisper.cpp
sudo mkdir -p /opt/whisper.cpp && sudo chown -R $USER:$USER /opt/whisper.cpp
git clone https://github.com/ggerganov/whisper.cpp.git /opt/whisper.cpp

# 3. Configure and compile with ARM NEON, Dot Product, and FP16 vector acceleration
cd /opt/whisper.cpp
cmake -B build -DCMAKE_BUILD_TYPE=Release -DWHISPER_BUILD_TESTS=OFF
cmake --build build --config Release -j 4

# 4. Install binaries and shared libraries into /usr/local
sudo cmake --install build --prefix /usr/local
sudo ldconfig

# 5. Download GGML models to /usr/local/share/whisper-cpp
sudo mkdir -p /usr/local/share/whisper-cpp
sudo /opt/whisper.cpp/models/download-ggml-model.sh base /usr/local/share/whisper-cpp
sudo /opt/whisper.cpp/models/download-ggml-model.sh small /usr/local/share/whisper-cpp
sudo chmod 644 /usr/local/share/whisper-cpp/*.bin
```

### C. Performance & Model Selection Benchmarks
Tested on 8 vCPU Apple Silicon aarch64 cores:
| Model | Size | Memory | 11s Audio Processing Time | Speed Factor | Recommendation |
|---|---|---|---|---|---|
| `ggml-base.bin` | 142 MB | ~150 MB | **~0.98s** | ~11× real-time | **Default / Best balance** for instant voice note replies |
| `ggml-small.bin` | 466 MB | ~490 MB | **~3.11s** | ~3.5× real-time | Higher accuracy for complex jargon or multiple languages |

#### Overriding the Active Model
If you want OpenClaw to specifically use `small` instead of `base`:
* **User Shell**:
  ```bash
  echo 'export WHISPER_CPP_MODEL="/usr/local/share/whisper-cpp/ggml-small.bin"' >> ~/.bashrc
  ```
* **Systemd User Service**:
  ```bash
  systemctl --user set-environment WHISPER_CPP_MODEL="/usr/local/share/whisper-cpp/ggml-small.bin"
  systemctl --user restart openclaw-gateway.service
  ```

### D. OpenClaw Audio Configuration
Enable audio understanding via OpenClaw config:
```bash
openclaw config set tools.media.audio.enabled true
```
This updates `~/.openclaw/openclaw.json`:
```json
{
  "tools": {
    "media": {
      "audio": {
        "enabled": true
      }
    }
  }
}
```

### E. Verification & Testing
* **Inspect audio providers in OpenClaw**:
  ```bash
  openclaw capability audio providers
  # Shows: id: "local/whisper-cli", transport: "local-cli", configured: true, localFallbackSelected: true
  ```
* **Direct audio transcription test**:
  ```bash
  # Test with WAV
  openclaw infer audio transcribe --file /opt/whisper.cpp/samples/jfk.wav

  # Test compressed audio (verifies ffmpeg transcoding)
  ffmpeg -y -i /opt/whisper.cpp/samples/jfk.wav -c:a libopus /tmp/test.ogg
  openclaw infer audio transcribe --file /tmp/test.ogg
  rm -f /tmp/test.ogg
  ```
* **Restart the Gateway Service**:
  ```bash
  systemctl --user restart openclaw-gateway.service
  ```

