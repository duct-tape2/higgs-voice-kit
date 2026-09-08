#!/bin/bash
set -euo pipefail

# Convert WAV to MP4 with showwaves visualization
# Usage: wav-to-mp4.sh input.wav output.mp4 "Title Text"

if [[ $# -lt 3 ]]; then
  echo "Usage: $0 <input.wav> <output.mp4> <title>" >&2
  exit 1
fi

INPUT="$1"
OUTPUT="$2"
TITLE="$3"

if [[ ! -f "$INPUT" ]]; then
  echo "Error: input file not found: $INPUT" >&2
  exit 1
fi

# Get audio duration
DURATION=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1:noprint_wrappers=1 "$INPUT")

ffmpeg -i "$INPUT" \
  -filter_complex "[0:a]showwaves=s=1280x720:mode=cline:scale=sqrt:colors=00ff00[waves]; \
                   [waves]drawtext=fontsize=24:fontcolor=white:x=(w-text_w)/2:y=h-th-10:text='$TITLE'[out]" \
  -map "[out]" \
  -map 0:a \
  -c:v libx264 -crf 20 -preset fast \
  -c:a aac -b:a 128k \
  -pix_fmt yuv420p \
  -y "$OUTPUT"

echo "Created: $OUTPUT ($DURATION seconds)"
