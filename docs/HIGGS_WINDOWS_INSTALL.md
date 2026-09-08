# Higgs Audio v3 Installation Guide — Windows

Complete setup and validation for running Higgs Audio v3 TTS on Windows with RTX GPU support (CPU fallback).

## 1. System Requirements

- Windows 10/11 x64
- 32 GB RAM (16 GB minimum for CPU fallback)
- NVIDIA GPU with 8+ GB VRAM (optional; CPU-only is supported)
- Python 3.8+ (if using HuggingFace CLI)
- Administrator access (for first-time setup)

## 2. Installation Order

### 2.1 Verify GPU (Optional)

If you have an NVIDIA GPU and want GPU acceleration:

```powershell
nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader
```

If this fails, install the latest NVIDIA drivers from https://www.nvidia.com/Download/driverDetails.aspx.

### 2.2 Download audio.cpp Runtime

Download the prebuilt binaries from:
https://github.com/kigner/audio.cpp-webui/releases/tag/v0.4.2-windows-prebuilt

You need:
- `audiocpp-core-cuda-win-x64-v0.4.2.zip` (GPU version, optional)
- `audiocpp-core-cpu-win-x64-v0.4.2.zip` (required)

Extract both to: `%USERPROFILE%\Documents\Codex\HiggsAudioV3RuntimeData\`

Verify:
```powershell
Test-Path "$env:USERPROFILE\Documents\Codex\HiggsAudioV3RuntimeData\gpu\audiocpp_server.exe"
Test-Path "$env:USERPROFILE\Documents\Codex\HiggsAudioV3RuntimeData\cpu\audiocpp_server.exe"
```

### 2.3 Download the Model

The model is ~5.1 GB. Download from:
```
https://huggingface.co/audio-cpp/audio.cpp-gguf/resolve/main/Higgs-Audio-v3-TTS-4B-GGUF/higgs-audio-v3-tts-4b-q8_0.gguf
```

Place in: `%USERPROFILE%\Documents\Codex\HiggsAudioV3RuntimeData\models\Higgs-Audio-v3-TTS-4B-GGUF\`

Verify checksum (should be `79746822045B5BF8F9AB2BDA87B16CD3F8EA3D9E319CBCF887A87AA1B537A74A`):

```powershell
$Model = "$env:USERPROFILE\Documents\Codex\HiggsAudioV3RuntimeData\models\Higgs-Audio-v3-TTS-4B-GGUF\higgs-audio-v3-tts-4b-q8_0.gguf"
(Get-FileHash -Algorithm SHA256 -LiteralPath $Model).Hash
```

### 2.4 Page File Configuration

If using CPU fallback or long synthesis, increase page file to 16–32 GB:

1. Right-click **This PC** → **Properties**
2. Click **Advanced system settings**
3. Under **Performance**, click **Settings**
4. Click **Advanced** tab, then **Change**
5. Uncheck "Automatically manage paging file size"
6. Select your drive and set **Initial size: 16384 MB**, **Maximum size: 32768 MB**
7. Click **Set** then **OK** and restart

### 2.5 Install ffmpeg (Optional, for batch processing)

```powershell
winget install --id Gyan.FFmpeg --exact
```

## 3. Configuration

Copy config templates to actual files:

```powershell
$Kit = "C:\path\to\higgs-voice-kit"
Copy-Item "$Kit\config\server.example.json" "$Kit\config\server.json"
Copy-Item "$Kit\config\voices.example.json" "$Kit\config\voices.json"
```

Edit `config\server.json`:
- Set `"backend": "cuda"` if you have a GPU (or leave as `"cpu"`)
- Adjust `"port"` if 8188 is already in use

Edit `config\voices.json`:
- Add your reference voice entries (see **Voice Preparation** below)

## 4. Voice Preparation

A voice is defined by:
- A reference WAV file: 10–20 seconds, 24 kHz mono, PCM 16-bit
- A transcript: exact text matching every word in the audio

### 4.1 Extract from YouTube (Optional)

```powershell
# Install tools
winget install --id yt-dlp.yt-dlp --exact

# Download audio and extract a segment
$URL = "https://www.youtube.com/watch?v=XXXXX"
yt-dlp -f bestaudio -o "source.%(ext)s" $URL

# Use ffmpeg to extract a clean segment
ffmpeg -ss 00:01:30 -to 00:01:45 -i source.* ^
  -ac 1 -ar 24000 -c:a pcm_s16le voice_reference.wav
```

### 4.2 Prepare Transcript

Listen to your reference WAV and write the exact transcript:

```powershell
@"
This is the exact words spoken in my reference audio file.
Every single word must match perfectly, including punctuation.
"@ | Out-File voice_reference_text.txt -Encoding UTF8
```

### 4.3 Add to Config

Edit `config\voices.json`:

```json
{
  "voices": [
    {
      "id": "my_voice",
      "path": "voices/my_voice.wav",
      "reference_text": "This is the exact words spoken..."
    }
  ]
}
```

## 5. Smoke Test (Optional)

Before using the kit, verify the server with a manual test:

```powershell
$Runtime = "$env:USERPROFILE\Documents\Codex\HiggsAudioV3RuntimeData"
$Server  = "$Runtime\gpu\audiocpp_server.exe"
$Config  = "$Runtime\server_higgs_manual.json"

# Create test config (change <USER> to your Windows username)
@"
{
  "host": "127.0.0.1",
  "port": 8088,
  "backend": "cuda",
  "device": 0,
  "threads": 8,
  "lazy_load": true,
  "models": [
    {
      "id": "higgs-audio-tts",
      "family": "higgs_audio_tts",
      "path": "C:\\Users\\<USER>\\Documents\\Codex\\HiggsAudioV3RuntimeData\\models\\Higgs-Audio-v3-TTS-4B-GGUF\\higgs-audio-v3-tts-4b-q8_0.gguf",
      "task": "tts",
      "mode": "offline",
      "lazy": true
    }
  ]
}
"@ | Out-File -Encoding UTF8 -LiteralPath $Config

# Start server
& $Server --config $Config

# In another PowerShell window:
Invoke-RestMethod "http://127.0.0.1:8088/health"
Invoke-RestMethod "http://127.0.0.1:8088/v1/models"
```

If the model is listed, the server is working. Stop it before starting the main kit.

## 6. Running the Kit

### 6.1 Start the Server

Double-click `windows\start-server.bat` (or `windows\start-server-gpu.bat` if available).

The server listens at `http://127.0.0.1:8188`.

### 6.2 Generate Speech

#### Via Command Line

```powershell
# Copy a script to a file
"Hello, this is a test of Higgs Audio v3" | Out-File script.txt

# Run generation
bash runtime/generate.command my_voice script.txt
```

#### Via API

```powershell
$Body = @{
  model = "higgs-audio-tts"
  input = "Hello, world"
  voice = "my_voice"
  response_format = "wav"
} | ConvertTo-Json

Invoke-WebRequest `
  -Uri "http://127.0.0.1:8188/v1/audio/speech" `
  -Method POST `
  -ContentType "application/json" `
  -Body $Body `
  -OutFile output.wav
```

Output files are saved to `outputs/`.

## 7. Troubleshooting

### Server won't start
- Check that `audiocpp_server.exe` is present and not blocked by Windows Defender
- Check `config\server.json` for syntax errors
- Review logs in `logs\` folder

### CUDA not detected
- Verify `nvidia-smi` works and shows your GPU
- Check NVIDIA driver version matches audio.cpp requirements
- Switch `config\server.json` to `"backend": "cpu"`

### Voice generation fails
- Verify reference WAV is exactly 24 kHz mono PCM 16-bit: `ffprobe voice.wav`
- Ensure transcript matches the audio word-for-word
- Check `logs\higgs_server_integrated.log`
- Try a shorter input text (under 500 characters)

### VRAM exhaustion
- Reduce `text-chunk-size` in generation calls
- Use CPU backend
- Close other GPU applications

## 8. Reference Documentation

- **Higgs Audio v3 Model**: https://huggingface.co/bosonai/higgs-audio-v3-tts-4b
- **audio.cpp GitHub**: https://github.com/kigner/audio.cpp-webui
- **API Documentation**: Check audio.cpp releases for OpenAI-compatible endpoint docs

## 9. Notes

- The kit does not ship with models or voice files
- All voice cloning is done locally; no data is sent to the cloud
- Reference voices must have correct permissions (personal recording, licensed, or public domain)
- Generated audio is saved locally in `outputs/`

## Generating with the anchor pipeline

After the model and `runtime\audiocpp_cli.exe` are in place:

```powershell
powershell -ExecutionPolicy Bypass -File runtime\generate-anchor.ps1 -VoiceId my_voice -TextFile script.txt
```

The first run builds a 5-second voice anchor and caches it under `cache\anchors\`; later runs reuse it. Output goes to `outputs\higgs-<timestamp>.wav` (24 kHz mono). See "Anchor mode" in README.md for the parameters.
