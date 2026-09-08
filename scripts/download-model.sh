#!/bin/bash
set -euo pipefail

# Download Higgs Audio v3 TTS 4B Q8 model from Hugging Face

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODELS_DIR="$ROOT/models"
MODEL_NAME="higgs-audio-v3-tts-4b-q8_0.gguf"
MODEL_PATH="$MODELS_DIR/$MODEL_NAME"

# Hugging Face model details
HF_REPO="audio-cpp/audio.cpp-gguf"
HF_FILE="Higgs-Audio-v3-TTS-4B-GGUF/higgs-audio-v3-tts-4b-q8_0.gguf"
HF_URL="https://huggingface.co/$HF_REPO/resolve/main/$HF_FILE"

# SHA-256 checksum for verification
EXPECTED_SHA256="79746822045B5BF8F9AB2BDA87B16CD3F8EA3D9E319CBCF887A87AA1B537A74A"

mkdir -p "$MODELS_DIR"

if [[ -f "$MODEL_PATH" ]]; then
  echo "Model already exists at $MODEL_PATH"
  echo "Verifying checksum..."
  ACTUAL_SHA256=$(shasum -a 256 "$MODEL_PATH" | cut -d' ' -f1)
  if [[ "${ACTUAL_SHA256^^}" == "${EXPECTED_SHA256^^}" ]]; then
    echo "✓ Checksum matches"
    exit 0
  else
    echo "✗ Checksum mismatch. Removing and re-downloading..."
    rm "$MODEL_PATH"
  fi
fi

echo "Downloading $MODEL_NAME from Hugging Face..."
echo "URL: $HF_URL"
echo "Size: ~5.1 GB"
echo ""

# Try huggingface-cli first if available
if command -v huggingface-cli >/dev/null 2>&1; then
  echo "Using huggingface-cli..."
  huggingface-cli download "$HF_REPO" "$HF_FILE" --local-dir "$MODELS_DIR" --local-dir-use-symlinks False
elif command -v curl >/dev/null 2>&1; then
  echo "Using curl..."
  curl -fL --progress-bar -o "$MODEL_PATH" "$HF_URL"
else
  echo "Error: neither huggingface-cli nor curl found" >&2
  exit 1
fi

echo ""
echo "Download complete. Verifying checksum..."
ACTUAL_SHA256=$(shasum -a 256 "$MODEL_PATH" | cut -d' ' -f1)

if [[ "${ACTUAL_SHA256^^}" == "${EXPECTED_SHA256^^}" ]]; then
  echo "✓ Model verified successfully"
  echo "Model saved to: $MODEL_PATH"
  exit 0
else
  echo "✗ Checksum mismatch!" >&2
  echo "Expected: $EXPECTED_SHA256" >&2
  echo "Got:      $ACTUAL_SHA256" >&2
  echo "File may be corrupted. Consider re-downloading." >&2
  exit 1
fi
