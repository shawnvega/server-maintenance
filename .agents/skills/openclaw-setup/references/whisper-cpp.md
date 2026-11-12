# OpenClaw Local Speech-to-Text (`whisper.cpp` Integration)

OpenClaw has native support for local audio transcription (inbound Telegram, WhatsApp, or Discord voice notes) via `whisper-cli` from `whisper.cpp` and `ffmpeg`.

## Architecture & Auto-Discovery
* **Binary Detection**: OpenClaw looks for `whisper-cli` in `$PATH` (`/usr/local/bin/whisper-cli`).
* **Model Discovery Order**:
  1. `WHISPER_CPP_MODEL` environment variable (explicit file override)
  2. `/opt/homebrew/share/whisper-cpp`
  3. `/usr/local/share/whisper-cpp`
  4. `/usr/share/whisper-cpp`
  Scans for `ggml-*.bin` files and prioritizes non-tiny models.
* **Audio Transcoding Pipeline**:
  OpenClaw's `resolveCliMediaPath` converts non-WAV media via `ffmpeg`:
  ```bash
  ffmpeg -y -i <input> -ac 1 -ar 16000 -c:a pcm_s16le -f wav <output.wav>
  whisper-cli -m <model> -otxt -of <OutputBase> -nt <AttachmentPath>
  ```

## Building & Installing `whisper.cpp` on Debian 13 ARM64
```bash
# 1. Install prerequisites
sudo apt update && sudo apt install -y cmake g++ make git ffmpeg

# 2. Clone whisper.cpp
sudo mkdir -p /opt/whisper.cpp && sudo chown -R $USER:$USER /opt/whisper.cpp
git clone https://github.com/ggerganov/whisper.cpp.git /opt/whisper.cpp

# 3. Configure and compile with ARM NEON, Dot Product, and FP16 acceleration
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

## Model Benchmarks (8 vCPU Apple Silicon `aarch64`)
| Model | Size | Memory | 11s Audio | Speed | Recommendation |
|---|---|---|---|---|---|
| `ggml-base.bin` | 142 MB | ~150 MB | **~0.98s** | ~11× real-time | **Default / Best balance** |
| `ggml-small.bin` | 466 MB | ~490 MB | **~3.11s** | ~3.5× real-time | Higher accuracy for jargon/multilingual |

### Overriding the Active Model
```bash
# User shell
echo 'export WHISPER_CPP_MODEL="/usr/local/share/whisper-cpp/ggml-small.bin"' >> ~/.bashrc

# Systemd user service
systemctl --user set-environment WHISPER_CPP_MODEL="/usr/local/share/whisper-cpp/ggml-small.bin"
systemctl --user restart openclaw-gateway.service
```

## OpenClaw Audio Configuration & Verification
```bash
# Enable audio understanding
openclaw config set tools.media.audio.enabled true

# Inspect audio providers (should show id: "local/whisper-cli")
openclaw capability audio providers

# Direct audio transcription test (WAV and Opus/OGG)
openclaw infer audio transcribe --file /opt/whisper.cpp/samples/jfk.wav
ffmpeg -y -i /opt/whisper.cpp/samples/jfk.wav -c:a libopus /tmp/test.ogg
openclaw infer audio transcribe --file /tmp/test.ogg
rm -f /tmp/test.ogg

systemctl --user restart openclaw-gateway.service
```
