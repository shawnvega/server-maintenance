---
name: mlx-whisper
description: >-
  Use this skill when installing, configuring, troubleshooting, or upgrading the local
  Apple Silicon MLX Whisper audio transcription server, LiteLLM audio proxy routes,
  or integrating speech-to-text (STT) and voice dictation with client agents (such as Hermes on 192.168.4.19).
---

# MLX Whisper & Voice Dictation Setup

This skill guides the provisioning, lifecycle management, verification, and troubleshooting of the **local Apple Silicon MLX Whisper server** on the host Mac (`192.168.4.8`), its integration into **LiteLLM Proxy** (port `4000`), and speech-to-text (STT) dictation routing for **Hermes Agent** on Fedora (`192.168.4.19`).

---

## Quick Architecture Overview

```mermaid
flowchart LR
    Browser["Hermes Web Composer / Mic"] -->|"Web Audio (JSON/Base64)"| Gateway["Hermes Gateway (.19:9119)"]
    Gateway -->|"POST /v1/audio/transcriptions (Bearer auth)"| LiteLLM["LiteLLM Proxy (.5:4000)"]
    LiteLLM -->|"Forward (model: whisper)"| MLX["MLX Whisper Server (.8:8080)"]
    MLX -->|"Metal / ANE GPU Inference"| Model[("whisper-large-v3-turbo")]
```

* **Local Inference**: Uses Apple's `mlx-whisper` running natively on Apple Silicon with unified memory and GPU/ANE acceleration.
* **OpenAI-Compatible Wire API**: Exposes `POST /v1/audio/transcriptions` via a FastAPI daemon running under macOS LaunchAgent `com.mlx.whisper`.
* **Zero Host CPU Burden**: Fedora node `.19` (Intel Core i5-8200Y) delegates all audio processing to the Mac, preserving CPU and RAM for Frigate NVR and agent execution.
* **Unified Security & Ports**: Hermes talks only to LiteLLM on port `4000` using the existing Bearer token `sk-hermes-mac-secret`.

---

## 1. Quick Reproduction & Automated Setup

To provision or repair the local MLX Whisper service, run:
```bash
./run.sh setup-whisper
```

This automated provisioning script ([`scripts/setup_mlx_whisper.sh`](file:///Users/shawn/StudioProjects/server-maintenance/scripts/setup_mlx_whisper.sh)):
1. Locates or creates the `mlx-whisper` Python virtual environment.
2. Ensures dependencies: `mlx-whisper`, `fastapi`, `uvicorn`, `python-multipart`.
3. Verifies `ffmpeg` in `/opt/homebrew/bin/ffmpeg`.
4. Writes and installs `~/Library/LaunchAgents/com.mlx.whisper.plist`.
5. Starts/reloads the LaunchAgent and verifies `GET http://127.0.0.1:8080/health`.
6. Updates [`files/litellm_mac_config.yaml`](file:///Users/shawn/StudioProjects/server-maintenance/files/litellm_mac_config.yaml) to declare `model_name: whisper` and reloads LiteLLM.
7. Executes a live self-test transcription.

---

## 2. Server Script & LaunchAgent Details

### A. Server Implementation
Located at [`files/mlx_whisper_server.py`](file:///Users/shawn/StudioProjects/server-maintenance/files/mlx_whisper_server.py):
* Handles `POST /v1/audio/transcriptions` accepting multipart form audio uploads.
* Injects `/opt/homebrew/bin` into `PATH` for `ffmpeg` audio container transcoding.
* Defaults to model `mlx-community/whisper-large-v3-turbo` (cached in `~/.cache/huggingface/hub/`).
* Supports `GET /v1/models` and `GET /health` for proxy readiness probes.

### B. macOS LaunchAgent Plist (`~/Library/LaunchAgents/com.mlx.whisper.plist`)
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.mlx.whisper</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Users/shawn/Library/Application Support/pipx/venvs/mlx-whisper/bin/python3</string>
        <string>/Users/shawn/StudioProjects/server-maintenance/files/mlx_whisper_server.py</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
        <key>PORT</key>
        <string>8080</string>
        <key>HOST</key>
        <string>127.0.0.1</string>
        <key>MLX_WHISPER_MODEL</key>
        <string>mlx-community/whisper-large-v3-turbo</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/Users/shawn/Library/Logs/mlx-whisper.log</string>
    <key>StandardErrorPath</key>
    <string>/Users/shawn/Library/Logs/mlx-whisper.error.log</string>
</dict>
</plist>
```

### C. Lifecycle Commands
```bash
# Check service health
curl -s http://127.0.0.1:8080/health

# Inspect launchd logs
tail -n 30 ~/Library/Logs/mlx-whisper.log
tail -n 30 ~/Library/Logs/mlx-whisper.error.log

# Reload LaunchAgent manually
launchctl unload ~/Library/LaunchAgents/com.mlx.whisper.plist
launchctl load ~/Library/LaunchAgents/com.mlx.whisper.plist
```

---

## 3. LiteLLM Proxy Route Configuration

In [`compose/192.168.4.5/litellm/config/litellm_config.yaml`](file:///Users/shawn/StudioProjects/server-maintenance/compose/192.168.4.5/litellm/config/litellm_config.yaml):
```yaml
model_list:
  - model_name: coding-26b
    litellm_params:
      model: ollama_chat/gemma4:26b-mlx-code
      api_base: http://192.168.4.8:11434
    model_info:
      max_input_tokens: 131072
      max_output_tokens: 8192

  - model_name: whisper
    litellm_params:
      model: openai/whisper
      api_base: http://192.168.4.8:8080/v1
      api_key: "none"
    model_info:
      mode: audio_transcription

  - model_name: whisper-1
    litellm_params:
      model: openai/whisper
      api_base: http://192.168.4.8:8080/v1
      api_key: "none"
    model_info:
      mode: audio_transcription

general_settings:
  master_key: "sk-hermes-mac-secret"
```

Deploy and restart LiteLLM on Pi 5:
```bash
./run.sh litellm
```

---

## 4. Hermes Client Configuration (`192.168.4.19`)

In [`compose/192.168.4.19/hermes/config.yaml.j2`](file:///Users/shawn/StudioProjects/server-maintenance/compose/192.168.4.19/hermes/config.yaml.j2):
```yaml
model:
  default: {{ hermes_model_name | default('coding-26b') }}
  provider: custom
  base_url: http://192.168.4.5:4000/v1
  api_key: {{ hermes_litellm_api_key | default('sk-hermes-mac-secret') }}

stt:
  enabled: true
  provider: openai
  openai:
    base_url: http://192.168.4.5:4000/v1
    api_key: {{ hermes_litellm_api_key | default('sk-hermes-mac-secret') }}
    model: whisper
```

To update or verify live in the running container:
```bash
ssh shawn@192.168.4.19 "
docker exec hermes-gateway /opt/hermes/.venv/bin/hermes config set stt.provider openai
docker exec hermes-gateway /opt/hermes/.venv/bin/hermes config set stt.openai.base_url http://192.168.4.5:4000/v1
docker exec hermes-gateway /opt/hermes/.venv/bin/hermes config set stt.openai.api_key sk-hermes-mac-secret
docker exec hermes-gateway /opt/hermes/.venv/bin/hermes config set stt.openai.model whisper
docker restart hermes-gateway
"
```

---

## 5. Verification & Testing

### A. Full Stack Verification
Run the integrated Hermes verification test:
```bash
./run.sh test-hermes
```
*(Check #11 verifies the MLX Whisper health endpoint, LiteLLM model catalog, and Hermes STT configuration).*

### B. Direct Audio Transcription Probe
Test transcription through LiteLLM from the command line:
```bash
curl -s -X POST http://192.168.4.8:4000/v1/audio/transcriptions \
  -H "Authorization: Bearer sk-hermes-mac-secret" \
  -F "file=@/path/to/audio.wav" \
  -F "model=whisper"
```

---

## 6. Common Gotchas & Troubleshooting

| Gotcha / Issue | Root Cause | Solution |
|---|---|---|
| Browser mic button greyed out or fails | Insecure HTTP origin (`http://192.168.4.19:9119`) | In Chrome/Edge, navigate to `chrome://flags/#unsafely-treat-insecure-origin-as-secure`, enable and add `http://192.168.4.19:9119`, and restart browser. |
| `[Errno 2] No such file or directory: 'ffmpeg'` | launchd environment lacks `/opt/homebrew/bin` | Ensure `PATH` in `com.mlx.whisper.plist` and `os.environ["PATH"]` in `mlx_whisper_server.py` prepend `/opt/homebrew/bin`. |
| Silent audio returns `{"transcript": ""}` | Hermes anti-hallucination filter removes default "Thank you" | Expected behavior: Whisper frequently outputs "Thank you" on pure silence; Hermes Silero VAD / hallucination filter cleans it. |
| LiteLLM returns `401 Unauthorized` | Missing or mismatched Bearer token | Pass `-H "Authorization: Bearer sk-hermes-mac-secret"` matching `master_key`. |
