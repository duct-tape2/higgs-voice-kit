# higgs-voice-kit

A minimal toolkit to run [Higgs Audio v3 TTS](https://huggingface.co/bosonai/higgs-audio-v3-tts-4b) locally using [audio.cpp](https://github.com/kigner/audio.cpp-webui) and generate consistent narration from your own reference voice.

## What is it?

This kit lets you:
- Run a local Higgs Audio v3 TTS server (CPU or GPU)
- Synthesize speech from text using a voice cloned from a reference audio clip you provide
- Batch-generate narration from plain-text scripts
- Tune generation parameters (temperature, seed, chunk size)
- Output clean 24 kHz mono PCM WAV

**What it is NOT:**
- A complete TTS application; it is a server API + launcher scripts
- A model repository (you must download the GGUF from Hugging Face)
- Pre-packaged voice clones or training data

## Requirements

### macOS (Apple Silicon)
- Xcode Command Line Tools or compatible zsh shell
- [audio.cpp](https://github.com/kigner/audio.cpp-webui/releases) binary (`audiocpp_server` and `audiocpp_cli`)
- Model: `bosonai/higgs-audio-v3-tts-4b` GGUF q8_0 from Hugging Face
- `ffmpeg` (for audio resampling)

### Windows
- PowerShell 5+ or Command Prompt
- [audio.cpp Windows build](https://github.com/kigner/audio.cpp-webui/releases/tag/v0.4.2-windows-prebuilt) (CUDA or CPU binary)
- Model: `bosonai/higgs-audio-v3-tts-4b` GGUF q8_0 from Hugging Face
- `ffmpeg` (for audio resampling)
- Optional: NVIDIA GPU + drivers for faster synthesis

## Quick Start

### 1. Download the model

```bash
bash scripts/download-model.sh
```

This fetches the q8_0 GGUF (~5 GB) into `models/`.

### 2. Prepare a reference voice

Record or extract a clean 10–20 second mono audio clip at 24 kHz, 16-bit PCM:

```bash
# Example: extract a segment from YouTube using yt-dlp and ffmpeg
yt-dlp -f bestaudio '<YOUR_YOUTUBE_URL>' -o reference_raw.%(ext)s
ffmpeg -ss 00:00:10 -to 00:00:20 -i reference_raw.* \
  -ac 1 -ar 24000 -c:a pcm_s16le voices/my_voice.wav
```

Write the exact transcript that matches the audio (every word must be correct):

```bash
cat > voices/my_voice_reference_text.txt << 'EOF'
This is the exact text spoken in my reference audio.
Every word must match perfectly.
EOF
```

Update `config/voices.json` with your voice entry.

### 3. Start the server

**macOS:**
```bash
bash runtime/start-server.command
```

**Windows:** Double-click `windows/start-server.bat` (requires admin rights for first run).

The server listens on `http://127.0.0.1:8188` and logs to `logs/server.*.log`.

### 4. Generate speech

**Command-line (via CLI):**
```bash
bash runtime/generate.command "my_voice" "Once upon a time..."
```

**Via HTTP API:**
```bash
curl -X POST http://127.0.0.1:8188/v1/audio/speech \
  -H "Content-Type: application/json" \
  -d '{
    "model": "higgs-audio-tts",
    "input": "Hello world",
    "voice": "my_voice",
    "response_format": "wav"
  }' \
  --output output.wav
```

Output files are saved to `outputs/` and timestamped.

## Reference Voice Preparation

The voice reference audio is the anchor for all synthesis. Quality matters:

- **Length:** 10–20 seconds of a single speaker, clear and isolated
- **Format:** PCM signed 16-bit, mono, 24 kHz
- **Loudness:** -20 to -16 LUFS, peak <= -1 dBFS (no clipping)
- **Transcript:** Must match word-for-word, with correct punctuation and capitalization
- **Rights:** You must have permission to use this audio (personal recording, purchased, or public domain)

Do **not** use:
- Generated or AI-cloned audio as a reference
- Background music, effects, or multiple speakers
- Compressed formats (use raw WAV)
- Files with resampling artifacts

## Configuration

### `config/server.json`
Server bind address, port, backend (CPU/CUDA), and model paths. Edit the model path and voice cache settings if needed.

### `config/voices.json`
Voice definitions: local file path, reference text, and metadata. Reference text must be exact and must match the audio precisely.

## Generation API

The server exposes OpenAI-compatible `/v1/audio/speech` endpoint:

```bash
POST /v1/audio/speech
Content-Type: application/json

{
  "model": "higgs-audio-tts",
  "input": "Text to synthesize",
  "voice": "my_voice",
  "response_format": "wav",
  "speed": 1.0
}
```

Optional parameters:
- `speed`: 0.5 to 2.0 (default 1.0)
- `response_format`: "wav" (default) or "mp3"

## Batch Generation

```bash
# Generate from a plain-text file
bash runtime/generate.command "my_voice" "$(cat script.txt)"

# Or use the CLI directly:
./runtime/audiocpp_cli \
  --backend cpu \
  --task tts \
  --family higgs_audio_tts \
  --model models/higgs-audio-v3-tts-4b-q8_0.gguf \
  --text "Your text here" \
  --voice-ref voices/my_voice.wav \
  --reference-text "$(cat voices/my_voice_reference_text.txt)" \
  --seed 12345 \
  --temperature 1.0 \
  --max-tokens 4096 \
  --text-chunk-size 200 \
  --out outputs/output.wav
```

## Tuning Parameters

When calling `audiocpp_cli`, you can adjust:

- `--seed` (int): Reproducibility seed. Same seed + same input = same output.
- `--temperature` (0.0–2.0, default 1.0): Lower = more consistent; higher = more variation.
- `--text-chunk-size` (int, default 200): Split long text into chunks. Smaller chunks fit in VRAM but may reduce speaker consistency.
- `--max-tokens` (int, default 4096): Maximum tokens per synthesis. Does not reduce model memory load.

For 8 GB VRAM (RTX 4060 Ti), keep `text-chunk-size` around 200 and avoid single requests over 1000 characters.

## Licenses

- **higgs-voice-kit** (this toolkit): MIT License, Copyright (c) 2026 duct-tape2
- **audio.cpp**: Apache License 2.0 — see https://github.com/kigner/audio.cpp-webui/blob/main/LICENSE
- **Higgs Audio v3 model**: Check the [model card](https://huggingface.co/bosonai/higgs-audio-v3-tts-4b) for the latest license terms. You must read and comply with the model's license before use.

## Not Included

This repository intentionally does not ship:
- The Higgs Audio v3 model weights (5 GB+)
- Pre-recorded reference voices
- Generated audio samples
- audio.cpp binary (you must download it yourself)

This ensures the kit stays small and legal, respecting both model licenses and your audio rights.

## Windows Installation

See [docs/HIGGS_WINDOWS_INSTALL.md](docs/HIGGS_WINDOWS_INSTALL.md) for a full Windows setup guide including CUDA runtime, model download, and smoke testing.

## Troubleshooting

### Server won't start
- Check that `audiocpp_server` is executable: `chmod +x runtime/audiocpp_server` (macOS)
- Verify the model file exists and is readable
- Check logs: `tail -f logs/server.stderr.log`

### CUDA/GPU not detected (Windows)
- Verify `nvidia-smi` runs and shows your GPU
- Check that you have the CUDA runtime version expected by your audio.cpp build
- Fallback to CPU backend in `config/server.json`

### Voice doesn't sound like the reference
- Verify reference audio is at exactly 24 kHz mono, PCM 16-bit
- Confirm the reference text matches word-for-word (including punctuation)
- Try a different seed value
- Use a longer reference (12–20 seconds) with very clear speech

### VRAM exhaustion
- Reduce `text-chunk-size` in generation calls
- Avoid synthesizing more than 1000 characters in a single request
- Use CPU backend if GPU memory is insufficient

## Contributing

This is a staging repository for distribution. Issues and PRs should be directed to the maintainer.

---

### 한글 (Korean)

**higgs-voice-kit**은 [Higgs Audio v3 TTS](https://huggingface.co/bosonai/higgs-audio-v3-tts-4b)를 로컬에서 실행하고, 당신의 참조 음성으로 일관된 내레이션을 생성하는 최소 도구 모음입니다.

- **요구사항**: macOS Apple Silicon / Windows + audio.cpp 바이너리 + Higgs Audio v3 GGUF (q8_0) + ffmpeg
- **빠른 시작**: `bash scripts/download-model.sh` → 참조 음성 준비 (10~20초, 정확한 텍스트) → `bash runtime/start-server.command` → `/v1/audio/speech` 호출 또는 `bash runtime/generate.command "voice_id" "텍스트"`
- **참조 음성**: 24 kHz mono PCM 16-bit WAV, 깨끗한 단독 화자, 음악/효과음 없음
- **라이선스**: 이 키트는 MIT; audio.cpp는 Apache-2.0; Higgs 모델은 [모델 카드](https://huggingface.co/bosonai/higgs-audio-v3-tts-4b) 참조

자세한 Windows 설치 가이드는 [docs/HIGGS_WINDOWS_INSTALL.md](docs/HIGGS_WINDOWS_INSTALL.md)를 확인하세요.
