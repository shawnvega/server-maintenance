# OpenClaw Troubleshooting & Repair

## Web UI or CLI Displays 32k or "33k/262k" Despite 128k Modelfile
* **Symptom**: The Web UI Control Dashboard model selector shows **32k**, and `openclaw models list --all` shows `33k/262k` instead of `131k`.
* **Cause**: OpenClaw's Ollama discovery extension (`dist/extensions/ollama/provider-discovery.js`) clamps auto-discovered `/api/tags` models via `OLLAMA_LOCAL_CONTEXT_TOKENS = 32768`.
* **Resolution**:
  1. Explicitly register each model in `~/.openclaw/openclaw.json` under `models.providers.ollama.models` with `contextWindow: 131072`, `contextTokens: 131072`, `maxTokens: 8192`, and `params: { "num_ctx": 131072 }`.
  2. Restart the gateway: `systemctl --user restart openclaw-gateway.service`.
  3. Verify with `openclaw models list` (should display `Ctx: 131k`) and hard-refresh the browser (`Cmd+Shift+R`).
  4. Active sessions store context limits in SQLite at creation time—start a new chat or run `openclaw agent --message "..."` to get the full 128k window.

## "OpenClaw could not verify a usable inference route"
* **Cause**: Models are defined in `openclaw.json`, but no default route or agent binding exists for `main`.
* **Resolution**:
  ```bash
  openclaw models set ollama/gemma4:26b-mlx-code
  systemctl --user restart openclaw-gateway.service
  ```
  Or ensure `agents.defaults.model` and `agents.entries.main.model` are explicitly set in `~/.openclaw/openclaw.json`.

## Prompt Budget Capped at 24.6k Despite 128k in Ollama GUI
* **Cause**: The Ollama desktop GUI slider only affects Ollama's built-in chat window, not external API clients. OpenClaw defaults unconfigured local models to `contextWindow: 32768` ($32,768 - 8,192 = 24,576$).
* **Resolution**: Update `~/.openclaw/openclaw.json` with explicit `contextWindow: 131072`, `contextTokens: 131072`, and `params: { "num_ctx": 131072 }`, ensure the Ollama `Modelfile` has `PARAMETER num_ctx 131072`, and restart `openclaw-gateway.service`.

## Inspecting SQLite Session Store When `sqlite3` CLI is Missing
Use Python's built-in `sqlite3` module:
```bash
python3 -c "import sqlite3; conn = sqlite3.connect('/home/shawn/.openclaw/agents/main/agent/openclaw-agent.sqlite'); c = conn.cursor(); print(c.execute('SELECT session_id, model, max_tokens, updated_at FROM sessions ORDER BY updated_at DESC LIMIT 5').fetchall())"
```

## Dashboard Inaccessible from Host Mac (`Connection refused`)
* **Cause**: `gateway.bind` defaults to `loopback` (`127.0.0.1`).
* **Resolution**: Set `"bind": "lan"` under `"gateway"` in `~/.openclaw/openclaw.json` and restart `openclaw-gateway.service`.

## Missing OpenAI API Key Warning during Doctor or Memory Indexing
* **Symptom**: `openclaw doctor` warns `Memory search provider is set to "openai" but no API key was found`.
* **Resolution**: Set `"memory": { "search": { "provider": "none" } }` in `~/.openclaw/openclaw.json` to use local keyword recall.

## Systemd User Service Terminates on SSH Logout
* **Cause**: Systemd terminates user session cgroups on logout when lingering is disabled.
* **Resolution**:
  ```bash
  sudo loginctl enable-linger $USER
  loginctl show-user $USER -p Linger
  ```

## Host Connection Refused (`curl: (7) Failed to connect`)
1. From the VM, ping the host bridge: `ping -c 2 192.168.64.1`
2. Test Ollama API response from VM: `curl -s -m 5 http://192.168.64.1:11434/api/tags`
3. On the host Mac, verify `lsof -nP -iTCP:11434 -sTCP:LISTEN` shows `*:11434` and `launchctl getenv OLLAMA_HOST` returns `0.0.0.0`. Restart Ollama if bound to `127.0.0.1`.

## Database Integrity or `OpenClawAgentDatabaseLeaseActiveError`
* **Symptom**: `invalid persisted session row requires repair` or `openclaw doctor` fails because `openclaw-gateway.service` holds SQLite locks.
* **Resolution**:
  ```bash
  systemctl --user stop openclaw-gateway.service
  openclaw doctor --fix
  systemctl --user start openclaw-gateway.service
  ```

## `whisper-cli: error while loading shared libraries: libwhisper.so`
* **Cause**: Dynamic linker cache (`/etc/ld.so.cache`) was not refreshed after `cmake --install`.
* **Resolution**: Run `sudo ldconfig`.
