#!/bin/bash
set -euo pipefail

# Verify that required binaries and files are present and readable

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MISSING=()
WARNINGS=()

echo "Self-check: Higgs Audio v3 Kit"
echo "==============================="
echo ""

# Check for jq (optional, as we have python3 fallback)
if command -v jq >/dev/null 2>&1; then
  echo "✓ jq found"
else
  echo "⚠ jq not found (python3 will be used as fallback for config parsing)"
fi

# Check for python3 (required as fallback for config parsing)
if command -v python3 >/dev/null 2>&1; then
  echo "✓ python3 found"
else
  MISSING+=("python3 (required for config parsing if jq is not available)")
fi

echo ""

# Check for audio.cpp binary
SERVER="$ROOT/runtime/audiocpp_server"
CLI="$ROOT/runtime/audiocpp_cli"

if [[ ! -x "$SERVER" ]]; then
  MISSING+=("$SERVER (not executable)")
else
  echo "✓ audiocpp_server found"
fi

if [[ ! -x "$CLI" ]]; then
  MISSING+=("$CLI (not executable)")
else
  echo "✓ audiocpp_cli found"
fi

# Check for ffmpeg and ffprobe
if command -v ffmpeg >/dev/null 2>&1; then
  echo "✓ ffmpeg found: $(ffmpeg -version | head -1)"
else
  MISSING+=("ffmpeg (not in PATH)")
fi

if command -v ffprobe >/dev/null 2>&1; then
  echo "✓ ffprobe found"
else
  MISSING+=("ffprobe (not in PATH, required for audio validation)")
fi

# Check for model (warning only, not fatal)
MODEL="$ROOT/models/higgs-audio-v3-tts-4b-q8_0.gguf"
if [[ ! -f "$MODEL" ]]; then
  WARNINGS+=("Model not found: $MODEL (run scripts/download-model.sh)")
else
  SIZE=$(du -Lh "$MODEL" | cut -f1)
  echo "✓ Model file found: $SIZE"
fi

# Check for config files
if [[ ! -f "$ROOT/config/server.json" ]]; then
  echo "! Note: config/server.json not found (copy from server.example.json)"
else
  echo "✓ config/server.json exists"
fi

if [[ ! -f "$ROOT/config/voices.json" ]]; then
  echo "! Note: config/voices.json not found (copy from voices.example.json)"
else
  echo "✓ config/voices.json exists"

  # Check voice files referenced in config (if python3 or jq available)
  if command -v python3 >/dev/null 2>&1; then
    while IFS= read -r voice_path; do
      if [[ -n "$voice_path" ]]; then
        full_path="$voice_path"
        [[ "$voice_path" != /* ]] && full_path="$ROOT/$voice_path"
        if [[ ! -f "$full_path" ]]; then
          WARNINGS+=("Voice file not found: $voice_path")
        elif command -v ffprobe >/dev/null 2>&1; then
          # Validate voice format: should be 24 kHz mono 16-bit PCM
          rate=$(ffprobe -v error -select_streams a:0 -show_entries stream=sample_rate -of csv=p=0 "$full_path" 2>/dev/null || echo "")
          channels=$(ffprobe -v error -select_streams a:0 -show_entries stream=channels -of csv=p=0 "$full_path" 2>/dev/null || echo "")
          if [[ "$rate" != "24000" ]]; then
            WARNINGS+=("Voice $voice_path has sample rate $rate, expected 24000 Hz")
          fi
          if [[ "$channels" != "1" ]]; then
            WARNINGS+=("Voice $voice_path has $channels channels, expected 1 (mono)")
          fi
        fi
      fi
    done < <(python3 -c "import json; f=open('$ROOT/config/voices.json'); print('\n'.join([v.get('path','') for v in json.load(f).get('voices',[])]))" 2>/dev/null || true)
  fi
fi

echo ""

if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo "ERRORS (must be fixed):"
  for item in "${MISSING[@]}"; do
    echo "  ✗ $item"
  done
  echo ""
fi

if [[ ${#WARNINGS[@]} -gt 0 ]]; then
  echo "WARNINGS (optional):"
  for item in "${WARNINGS[@]}"; do
    echo "  ⚠ $item"
  done
  echo ""
fi

if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo "Setup incomplete. Fix errors above and try again."
  exit 1
else
  echo "All required files are present."
  exit 0
fi
