#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$ROOT/runtime/audiocpp_cli"
MODEL="$ROOT/models/higgs-audio-v3-tts-4b-q8_0.gguf"
CONFIG="$ROOT/config/voices.json"

VOICE_ID="${1:-}"
if [[ -z "$VOICE_ID" ]]; then
  echo "Usage: $0 <voice_id> [text_file]" >&2
  echo "Example: $0 my_voice script.txt" >&2
  exit 1
fi

# Extract voice file and reference text from config
VOICE_FILE=$(jq -r ".voices[] | select(.id == \"$VOICE_ID\") | .path" "$CONFIG" 2>/dev/null || true)
REF_TEXT=$(jq -r ".voices[] | select(.id == \"$VOICE_ID\") | .reference_text" "$CONFIG" 2>/dev/null || true)

if [[ -z "$VOICE_FILE" || -z "$REF_TEXT" ]]; then
  echo "Voice '$VOICE_ID' not found in $CONFIG" >&2
  exit 1
fi

if [[ ! -f "$VOICE_FILE" || ! -f "$MODEL" ]]; then
  osascript -e "display alert \"Higgs Audio v3\" message \"Voice or model file not found.\" as warning" 2>/dev/null || true
  exit 1
fi

TEXT_FILE="${2:-}"
if [[ -z "$TEXT_FILE" || ! -f "$TEXT_FILE" ]]; then
  TEXT_FILE=$(osascript -e 'POSIX path of (choose file with prompt "Select text file to synthesize:")' 2>/dev/null || true)
  if [[ -z "$TEXT_FILE" ]]; then
    echo "No input file provided" >&2
    exit 1
  fi
fi

TEXT=$(sed -e '/^[[:space:]]*#/d' -e 's/[[:space:]]\+/ /g' "$TEXT_FILE" | tr '\n' ' ')
STAMP=$(date +%Y%m%d-%H%M%S)
RAW="$ROOT/outputs/higgs-$STAMP.raw.wav"
OUT="$ROOT/outputs/higgs-$STAMP.wav"

mkdir -p "$ROOT/outputs"

"$CLI" \
  --backend cpu \
  --task tts \
  --family higgs_audio_tts \
  --model "$MODEL" \
  --text "$TEXT" \
  --voice-ref "$VOICE_FILE" \
  --reference-text "$REF_TEXT" \
  --seed 12345 \
  --temperature 1.0 \
  --max-tokens 4096 \
  --text-chunk-size 200 \
  --out "$RAW" \
  --log \
  --log-file "$ROOT/logs/generate-$STAMP.log"

ffmpeg -y -hide_banner -loglevel error -i "$RAW" -ac 1 -ar 24000 -c:a pcm_s16le "$OUT"
rm "$RAW"
open -R "$OUT"
open "$OUT"
