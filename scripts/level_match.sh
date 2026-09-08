#!/bin/bash
# Level matching helper for higgs-voice-kit
# Usage: level_match.sh <input.wav> <target_lufs> [output.wav]
# Measures integrated loudness with ffmpeg ebur128 and applies gain.

set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <input.wav> <target_lufs> [output.wav]" >&2
  exit 1
fi

INPUT="$1"
TARGET_LUFS="$2"
OUTPUT="${3:-${INPUT%.wav}-leveled.wav}"

if [[ ! -f "$INPUT" ]]; then
  echo "Input file not found: $INPUT" >&2
  exit 1
fi

# Measure integrated loudness
LUFS=$(ffmpeg -i "$INPUT" -af ebur128=r=true -f null - 2>&1 | grep -oP 'I:\s*\K[^ ]+' | head -1)

if [[ -z "$LUFS" ]]; then
  echo "Failed to measure loudness" >&2
  exit 1
fi

# Parse LUFS value (may be negative)
LUFS_NUM=$(echo "$LUFS" | sed 's/LUFS//;s/ //g')

# Calculate gain in dB: gain = target - measured
GAIN_DB=$(echo "$TARGET_LUFS - $LUFS_NUM" | bc -l)

# Clamp gain to +-6 dB
if (( $(echo "$GAIN_DB > 6" | bc -l) )); then
  GAIN_DB=6
elif (( $(echo "$GAIN_DB < -6" | bc -l) )); then
  GAIN_DB=-6
fi

# Verify peak after gain won't clip (check with astats)
# Apply volume filter with limiter to prevent clipping
ffmpeg -y -hide_banner -loglevel error -i "$INPUT" \
  -af "volume=${GAIN_DB}dB:precision=double,alimiter=level_in=1:level_out=1:attack=5:release=50:look_ahead=20" \
  -c:a pcm_s16le "$OUTPUT"

echo "$OUTPUT $LUFS_NUM -> $GAIN_DB dB"
