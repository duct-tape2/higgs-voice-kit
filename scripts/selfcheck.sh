#!/bin/bash
set -euo pipefail

# Verify that required binaries and files are present and readable

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MISSING=()
WARNINGS=()

echo "Self-check: Higgs Audio v3 Kit"
echo "==============================="
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

# Check for ffmpeg
if command -v ffmpeg >/dev/null 2>&1; then
  echo "✓ ffmpeg found: $(ffmpeg -version | head -1)"
else
  MISSING+=("ffmpeg (not in PATH)")
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
