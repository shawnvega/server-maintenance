#!/usr/bin/env python3
"""
Lightweight OpenAI-compatible MLX Whisper Audio Transcription Server.
Runs locally on Apple Silicon using mlx_whisper.
"""

import os
import tempfile
from typing import Optional

# Ensure standard Homebrew and system paths are available for ffmpeg
for extra_path in ("/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin"):
    if extra_path not in os.environ.get("PATH", ""):
        os.environ["PATH"] = f"{extra_path}:{os.environ.get('PATH', '')}"

from fastapi import FastAPI, File, Form, UploadFile, HTTPException
from fastapi.responses import PlainTextResponse, JSONResponse
import mlx_whisper
import uvicorn

DEFAULT_MODEL = os.environ.get("MLX_WHISPER_MODEL", "mlx-community/whisper-large-v3-turbo")

app = FastAPI(title="MLX Whisper Transcription API", version="1.0.0")


@app.get("/health")
async def health():
    return {"status": "ok", "default_model": DEFAULT_MODEL}


@app.get("/v1/models")
async def list_models():
    return {
        "object": "list",
        "data": [
            {
                "id": "whisper",
                "object": "model",
                "created": 1700000000,
                "owned_by": "mlx-community",
            },
            {
                "id": "whisper-1",
                "object": "model",
                "created": 1700000000,
                "owned_by": "mlx-community",
            },
            {
                "id": DEFAULT_MODEL,
                "object": "model",
                "created": 1700000000,
                "owned_by": "mlx-community",
            },
        ],
    }


@app.post("/v1/audio/transcriptions")
async def transcribe(
    file: UploadFile = File(...),
    model: Optional[str] = Form(None),
    language: Optional[str] = Form(None),
    prompt: Optional[str] = Form(None),
    response_format: Optional[str] = Form("json"),
    temperature: Optional[float] = Form(0.0),
):
    # Map model name
    hf_model = DEFAULT_MODEL
    if model and model not in ("whisper", "whisper-1", "default"):
        hf_model = model

    suffix = os.path.splitext(file.filename or "")[1] or ".wav"
    with tempfile.NamedTemporaryFile(delete=False, suffix=suffix) as tmp:
        content = await file.read()
        tmp.write(content)
        tmp_path = tmp.name

    try:
        kwargs = {
            "path_or_hf_repo": hf_model,
            "temperature": temperature if temperature is not None else 0.0,
        }
        if language:
            kwargs["language"] = language
        if prompt:
            kwargs["initial_prompt"] = prompt

        result = mlx_whisper.transcribe(tmp_path, **kwargs)
        transcription_text = (result.get("text") or "").strip()

        if response_format == "text":
            return PlainTextResponse(transcription_text)

        return {"text": transcription_text}

    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        if os.path.exists(tmp_path):
            try:
                os.remove(tmp_path)
            except OSError:
                pass


if __name__ == "__main__":
    host = os.environ.get("HOST", "127.0.0.1")
    port = int(os.environ.get("PORT", "8080"))
    uvicorn.run(app, host=host, port=port)
