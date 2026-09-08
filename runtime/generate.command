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
GAP_MS="${HIGGS_GAP_MS:-250}"
CHUNKING="${HIGGS_CHUNKING:-smart}"   # smart (sentence-aware) | cli (single call)
# The anchor sentence lives in config/anchor.<lang>.txt (ko and en ship with the kit).
# Seed offsets tried when the model stops before end-of-content.
LADDER=(0 1000 7777)

VOICE_ID="${1:-}"
if [[ -z "$VOICE_ID" ]]; then
  echo "Usage: $0 <voice_id> [text_file]" >&2
  echo "Example: $0 my_voice script.txt" >&2
  exit 1
fi

# Parse voices.json: try jq first, fall back to python3
if command -v jq >/dev/null 2>&1; then
  VOICE_FILE=$(jq -r ".voices[] | select(.id == \"$VOICE_ID\") | .path" "$CONFIG" 2>/dev/null || true)
  REF_TEXT=$(jq -r ".voices[] | select(.id == \"$VOICE_ID\") | .reference_text" "$CONFIG" 2>/dev/null || true)
  LANGUAGE=$(jq -r ".voices[] | select(.id == \"$VOICE_ID\") | .language // empty" "$CONFIG" 2>/dev/null || true)
else
  # Fallback to python3 if jq is not available
  python3 << PYEOF
import json, sys
try:
  with open('$CONFIG') as f:
    data = json.load(f)
    for v in data.get('voices', []):
      if v.get('id') == '$VOICE_ID':
        print(v.get('path', ''))
        sys.stdout.flush()
        break
except Exception as e:
  pass
PYEOF
  VOICE_FILE=$(python3 << PYEOF 2>/dev/null || true
import json
try:
  with open('$CONFIG') as f:
    data = json.load(f)
    for v in data.get('voices', []):
      if v.get('id') == '$VOICE_ID':
        print(v.get('path', ''))
        break
except:
  pass
PYEOF
)
  REF_TEXT=$(python3 << PYEOF 2>/dev/null || true
import json
try:
  with open('$CONFIG') as f:
    data = json.load(f)
    for v in data.get('voices', []):
      if v.get('id') == '$VOICE_ID':
        print(v.get('reference_text', ''))
        break
except:
  pass
PYEOF
)
  LANGUAGE=$(python3 << PYEOF 2>/dev/null || true
import json
try:
  with open('$CONFIG') as f:
    data = json.load(f)
    for v in data.get('voices', []):
      if v.get('id') == '$VOICE_ID':
        print(v.get('language', ''))
        break
except:
  pass
PYEOF
)
fi

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
    --max-tokens "$5" --text-chunk-size 9999 \
    --out "$6" > "$7" 2>&1
}

wav_seconds() {
  ffprobe -v error -show_entries format=duration -of csv=p=0 "$1" 2>/dev/null | awk -F. '{printf "%.1f\n", $1 + ($2 ? ("0." substr($2, 1, 1)) : 0)}'
}

generate_with_ladder() {
  # $1 text  $2 voice_ref  $3 reference_text  $4 out  $5 log_base  [$6 max_tokens] [$7 max_seconds]
  local off seed log max_tokens="${6:-$MAX_TOKENS}" max_seconds="${7:-0}" secs
  for off in "${LADDER[@]}"; do
    seed=$((SEED + off))
    log="$5-seed$seed.log"
    if run_tts "$1" "$2" "$3" "$seed" "$max_tokens" "$4" "$log"; then
      if [[ "$max_seconds" -gt 0 ]]; then
        secs=$(wav_seconds "$4")
        if [[ -z "$secs" || "$secs" -lt 2 || "$secs" -gt "$max_seconds" ]]; then
          echo "seed $seed produced ${secs:-?}s for a ~5s sentence (babble), trying another seed" >&2
          rm -f "$4"
          continue
        fi
      fi
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
    # Same cap as the desktop app (1024 tokens) plus a length check: a good anchor is 2-3 s.
    generate_with_ladder "$ANCHOR_TEXT" "$VOICE_FILE" "$REF_TEXT" "$ANCHOR_RAW" "$ROOT/logs/anchor-$VOICE_ID-$STAMP" 1024 12
    if [[ ! -f "$ANCHOR_RAW" ]]; then
      echo "Failed to generate anchor audio file" >&2
      exit 1
    fi
    ffmpeg -y -hide_banner -loglevel error -i "$ANCHOR_RAW" -ac 1 -ar 24000 -c:a pcm_s16le "$ANCHOR"
    if [[ ! -f "$ANCHOR" ]]; then
      echo "Failed to convert anchor to 24 kHz: ffmpeg failed or ffmpeg not installed" >&2
      exit 1
    fi
    rm -f "$ANCHOR_RAW"
  fi
  if [[ ! -f "$ANCHOR" ]]; then
    echo "Anchor file missing: $ANCHOR" >&2
    exit 1
  fi
  REF_FILE="$ANCHOR"
  REF_TEXT_USED="$ANCHOR_TEXT"
fi

OUT="$ROOT/outputs/higgs-$STAMP.wav"

lufs_of() {
  # Integrated loudness (LUFS) of a wav via ffmpeg ebur128; prints e.g. -28.1
  ffmpeg -nostats -i "$1" -af ebur128 -f null - 2>&1 | awk '/ I:/{v=$0} END{sub(/.* I:[ ]*/,"",v); sub(/ LUFS.*/,"",v); print v}'
}

if [[ "$CHUNKING" == "smart" ]] && command -v python3 >/dev/null 2>&1 && [[ -f "$ROOT/scripts/chunk_text.py" ]]; then
  echo "sentence-aware chunking (max $CHUNK chars per chunk, ${GAP_MS} ms gap)"
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/higgs-chunks.XXXXXX")"
  trap 'rm -rf "$WORK"' EXIT
  print -rn -- "$TEXT" > "$WORK/input.txt"
  typeset -a CHUNKS WAVS LUFS_LIST
  CHUNKS=("${(@f)$(python3 "$ROOT/scripts/chunk_text.py" "$WORK/input.txt" "$CHUNK")}")
  i=0
  for c in "${CHUNKS[@]}"; do
    [[ -z "${c//[[:space:]]/}" ]] && continue
    i=$((i + 1))
    w="$WORK/chunk$i.wav"
    generate_with_ladder "$c" "$REF_FILE" "$REF_TEXT_USED" "$w" "$ROOT/logs/generate-$STAMP-chunk$i" || { echo "chunk $i failed" >&2; exit 1; }
    l="$(lufs_of "$w")"
    WAVS+=("$w"); LUFS_LIST+=("$l")
    echo "  chunk $i: ${#c} chars, $(wav_seconds "$w") s, ${l} LUFS: ${c[1,40]}..."
  done
  [[ ${#WAVS[@]} -eq 0 ]] && { echo "no chunks generated" >&2; exit 1; }
  MEDIAN="$(python3 -c 'import sys,statistics; print(round(statistics.median([float(x) for x in sys.argv[1:]]),1))' "${LUFS_LIST[@]}")"
  echo "  level target (median): ${MEDIAN} LUFS"
  ffmpeg -y -hide_banner -loglevel error -f lavfi -i "anullsrc=r=24000:cl=mono" -t "$(python3 -c "print($GAP_MS/1000)")" -c:a pcm_s16le "$WORK/gap.wav"
  : > "$WORK/concat.txt"
  i=0
  for w in "${WAVS[@]}"; do
    i=$((i + 1))
    GAIN="$(python3 -c 'import sys; g=float(sys.argv[1])-float(sys.argv[2]); print(round(max(-6.0,min(6.0,g)),2))' "$MEDIAN" "${LUFS_LIST[$i]}")"
    lv="$WORK/level$i.wav"
    # gain to the shared level, brick-wall limiter, 5 ms fade in/out (areverse trick avoids needing the duration)
    ffmpeg -y -hide_banner -loglevel error -i "$w" \
      -af "volume=${GAIN}dB,alimiter=limit=0.95:attack=5:release=50,afade=t=in:d=0.005,areverse,afade=t=in:d=0.005,areverse" \
      -ac 1 -ar 24000 -c:a pcm_s16le "$lv"
    echo "  chunk $i: gain ${GAIN} dB -> $(lufs_of "$lv") LUFS"
    print -r -- "file '$lv'" >> "$WORK/concat.txt"
    [[ $i -lt ${#WAVS[@]} ]] && print -r -- "file '$WORK/gap.wav'" >> "$WORK/concat.txt"
  done
  ffmpeg -y -hide_banner -loglevel error -f concat -safe 0 -i "$WORK/concat.txt" -af "apad=pad_dur=0.15" -ac 1 -ar 24000 -c:a pcm_s16le "$OUT"
  echo "joined ${#WAVS[@]} chunks -> $OUT"
else
  [[ "$CHUNKING" == "smart" ]] && echo "python3 or scripts/chunk_text.py not found: using the CLI chunker (--text-chunk-size $CHUNK)"
  RAW="$ROOT/outputs/higgs-$STAMP.raw.wav"
  generate_with_ladder "$TEXT" "$REF_FILE" "$REF_TEXT_USED" "$RAW" "$ROOT/logs/generate-$STAMP"
  ffmpeg -y -hide_banner -loglevel error -i "$RAW" -af "apad=pad_dur=0.15" -ac 1 -ar 24000 -c:a pcm_s16le "$OUT"
  rm -f "$RAW"
  echo "$OUT"
fi
open -R "$OUT" 2>/dev/null || true
open "$OUT" 2>/dev/null || true
