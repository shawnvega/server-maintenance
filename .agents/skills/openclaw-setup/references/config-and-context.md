# OpenClaw Configuration & Context Window Guide

## Complete `~/.openclaw/openclaw.json` Structure

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

---

## Context Window & Prompt Budget Configuration

OpenClaw calculates its **Prompt Budget** on the client side:
$$\text{Prompt Budget} = \text{contextWindow} - \text{outputReservation}$$
By default, local/custom models in OpenClaw default to a conservative `contextWindow: 32768` (32k), leaving **24,576 tokens (~24.6k)** for prompt budget ($32,768 - 8,192$ output reserve).

> [!NOTE]
> Adjusting the "Context length" slider in Ollama's macOS GUI Settings **only affects Ollama's built-in desktop chat interface**, not external API clients like OpenClaw.

### Why Auto-Discovered Ollama Models Get Clamped to 32k
OpenClaw's Ollama extension (`dist/extensions/ollama/provider-discovery.js`) contains an internal hardcoded clamp:
```javascript
const OLLAMA_LOCAL_CONTEXT_TOKENS = 32768;
function capLocalOllamaModelContext(model) {
  // Clamps any auto-discovered local Ollama model to 32768
  return Math.min(OLLAMA_LOCAL_CONTEXT_TOKENS, model.contextWindow);
}
```
When models are dynamically discovered from Ollama's `/api/tags` endpoint without an explicit entry in `models.providers.ollama.models`:
1. `openclaw models list --all` displays them with clamped context (e.g. `33k/262k`).
2. The Web UI Control Dashboard model selector caps them at **32k**.

### The Triad of Context Settings
To guarantee that 128k (`131k`) is used across the Web UI, CLI, and Ollama inference:
1. **`contextWindow: 131072`**: Defines the total context window size used by OpenClaw to compute the prompt budget and manage sliding window pruning.
2. **`contextTokens: 131072`**: Controls the token limit reported in the model catalog and the Web UI model selector pill.
3. **`params.num_ctx: 131072`**: Passed directly into Ollama's API call payload (`/api/chat` or `/api/generate`), instructing Ollama's engine to allocate Unified Memory / KV cache for 128k context.

* **Always use camelCase**: OpenClaw requires `contextWindow` and `contextTokens` (`context_window` is silently ignored).
* **Provider-level defaults**: Set `"params": { "num_ctx": 131072 }` under `models.providers.ollama` so any fallback or dynamically invoked model also passes `num_ctx: 131072`.
* **Bake `num_ctx` into custom Modelfile**:
  ```dockerfile
  FROM gemma4:26b-mlx
  PARAMETER num_ctx 131072
  ```
  ```bash
  ollama create gemma4:26b-mlx-code -f Modelfile
  ```
* **Memory impact**: A 26B model at 128k context requires an additional 15–25+ GB of Unified Memory for the KV cache. 32k or 64k (`num_ctx: 65536`) is often the practical sweet spot for responsiveness.
