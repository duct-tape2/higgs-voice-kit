#!/bin/zsh
# higgs-voice-kit: generate narration from a text file with a reference voice.
#
# Default mode "anchor" reproduces the desktop app pipeline that this kit was
# extracted from:
#   1) synthesize one fixed anchor sentence from your raw reference (cached)
#   2) generate every text chunk with that anchor as the voice reference
# The anchor keeps the speaker identical across chunks and across seeds.
# Set HIGGS_MODE=raw to clone straight from the raw reference instead.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$ROOT/runtime/audiocpp_cli"
MODEL="$ROOT/models/higgs-audio-v3-tts-4b-q8_0.gguf"
CONFIG="$ROOT/config/voices.json"

MODE="${HIGGS_MODE:-anchor}"          # anchor | raw
BACKEND="${HIGGS_BACKEND:-cpu}"       # cpu | metal | cuda | vulkan | best
THREADS="${HIGGS_THREADS:-8}"
SEED="${HIGGS_SEED:-42}"
TEMPERATURE="${HIGGS_TEMPERATURE:-0.66}"
TOP_K="${HIGGS_TOP_K:-24}"
TOP_P="${HIGGS_TOP_P:-0.8}"
MAX_TOKENS="${HIGGS_MAX_TOKENS:-4096}"
CHUNK="${HIGGS_CHUNK:-200}"
# The anchor sentence lives in config/anchor.<lang>.txt (ko and en ship with the kit).
# Seed offsets tried when the model stops before end-of-content.
LADDER=(0 1000 7777)

VOICE_ID="${1:-}"
if [[ -z "$VOICE_ID" ]]; then
  echo "Usage: $0 <voice_id> [text_file]" >&2
  echo "Example: $0 my_voice script.txt" >&2
  exit 1
fi

VOICE_FILE=$(jq -r ".voices[] | select(.id == \"$VOICE_ID\") | .path" "$CONFIG" 2>/dev/null || true)
REF_TEXT=$(jq -r ".voices[] | select(.id == \"$VOICE_ID\") | .reference_text" "$CONFIG" 2>/dev/null || true)
LANGUAGE=$(jq -r ".voices[] | select(.id == \"$VOICE_ID\") | .language // empty" "$CONFIG" 2>/dev/null || true)

if [[ -z "$VOICE_FILE" || -z "$REF_TEXT" ]]; then
  echo "Voice '$VOICE_ID' not found in $CONFIG" >&2
  exit 1
fi
[[ "$VOICE_FILE" != /* ]] && VOICE_FILE="$ROOT/$VOICE_FILE"
ANCHOR_LANG="${LANGUAGE:-ko}"
ANCHOR_FILE="$ROOT/config/anchor.$ANCHOR_LANG.txt"
if [[ ! -f "$ANCHOR_FILE" ]]; then
  echo "Anchor sentence file not found: $ANCHOR_FILE (copy config/anchor.en.txt and translate it)" >&2
  exit 1
fi
ANCHOR_TEXT="$(tr -d '\n' < "$ANCHOR_FILE")"

if [[ ! -f "$VOICE_FILE" || ! -f "$MODEL" ]]; then
  osascript -e "display alert \"Higgs Audio v3\" message \"Voice or model file not found.\" as warning" 2>/dev/null || true
  echo "Missing voice ($VOICE_FILE) or model ($MODEL)" >&2
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

TEXT=$(sed -e '/^[[:space:]]*#/d' -e 's/[[:space:]]\+/ /g' "$TEXT_FILE" | tr '\n' ' ' | sed -e 's/^ *//' -e 's/ *$//')
STAMP=$(date +%Y%m%d-%H%M%S)
mkdir -p "$ROOT/outputs" "$ROOT/logs" "$ROOT/cache/anchors"

run_tts() {
  # $1 text  $2 voice_ref  $3 reference_text  $4 seed  $5 max_tokens  $6 out  $7 log
  local lang_args=()
  [[ -n "$LANGUAGE" ]] && lang_args=(--language "$LANGUAGE")
  "$CLI" \
    --backend "$BACKEND" --threads "$THREADS" \
    --task tts --family higgs_audio_tts --model "$MODEL" \
    "${lang_args[@]}" \
    --text "$1" --voice-ref "$2" --reference-text "$3" \
    --seed "$4" --temperature "$TEMPERATURE" --top-k "$TOP_K" --top-p "$TOP_P" \
    --max-tokens "$5" --text-chunk-size "$CHUNK" \
    --out "$6" > "$7" 2>&1
}

generate_with_ladder() {
  # $1 text  $2 voice_ref  $3 reference_text  $4 out  $5 log_base
  local off seed log
  for off in "${LADDER[@]}"; do
    seed=$((SEED + off))
    log="$5-seed$seed.log"
    if run_tts "$1" "$2" "$3" "$seed" "$MAX_TOKENS" "$4" "$log"; then
      echo "generated with seed $seed"
      return 0
    fi
    if grep -q "max_tokens before EOC" "$log"; then
      echo "seed $seed stopped before end of content, trying another seed" >&2
      continue
    fi
    echo "generation failed, see $log" >&2
    return 1
  done
  echo "all seeds stopped before end of content; shorten the text or lower HIGGS_CHUNK" >&2
  return 1
}

REF_FILE="$VOICE_FILE"
REF_TEXT_USED="$REF_TEXT"
if [[ "$MODE" == "anchor" ]]; then
  ANCHOR="$ROOT/cache/anchors/anchor_${VOICE_ID}_seed${SEED}.wav"
  if [[ ! -f "$ANCHOR" ]]; then
    echo "building voice anchor for '$VOICE_ID' (one time)"
    ANCHOR_RAW="$ANCHOR.raw.wav"
    generate_with_ladder "$ANCHOR_TEXT" "$VOICE_FILE" "$REF_TEXT" "$ANCHOR_RAW" "$ROOT/logs/anchor-$VOICE_ID-$STAMP"
    ffmpeg -y -hide_banner -loglevel error -i "$ANCHOR_RAW" -ac 1 -ar 24000 -c:a pcm_s16le "$ANCHOR"
    rm -f "$ANCHOR_RAW"
  fi
  REF_FILE="$ANCHOR"
  REF_TEXT_USED="$ANCHOR_TEXT"
fi

RAW="$ROOT/outputs/higgs-$STAMP.raw.wav"
OUT="$ROOT/outputs/higgs-$STAMP.wav"
generate_with_ladder "$TEXT" "$REF_FILE" "$REF_TEXT_USED" "$RAW" "$ROOT/logs/generate-$STAMP"
ffmpeg -y -hide_banner -loglevel error -i "$RAW" -ac 1 -ar 24000 -c:a pcm_s16le "$OUT"
rm -f "$RAW"
echo "$OUT"
open -R "$OUT" 2>/dev/null || true
open "$OUT" 2>/dev/null || true
