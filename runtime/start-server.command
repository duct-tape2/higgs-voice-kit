#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SERVER="$ROOT/runtime/audiocpp_server"
CONFIG="$ROOT/config/server.json"
MODEL="$ROOT/models/higgs-audio-v3-tts-4b-q8_0.gguf"

if [[ ! -x "$SERVER" ]]; then
  osascript -e 'display alert "Higgs Audio v3" message "Runtime binary not found. Please check the installation guide." as critical'
  exit 1
fi

if [[ ! -f "$MODEL" ]]; then
  osascript -e 'display alert "Higgs Audio v3" message "Model file not found. Run scripts/download-model.sh first." as warning'
  exit 1
fi

if curl -fsS --max-time 2 http://127.0.0.1:8188/health >/dev/null 2>&1; then
  open "$ROOT/outputs"
  osascript -e 'display notification "Local server already running (127.0.0.1:8188)" with title "Higgs Audio v3"'
  exit 0
fi

mkdir -p "$ROOT/logs"
nohup "$SERVER" --config "$CONFIG" --backend cpu \
  >>"$ROOT/logs/server.stdout.log" \
  2>>"$ROOT/logs/server.stderr.log" &

for _ in {1..30}; do
  if curl -fsS --max-time 2 http://127.0.0.1:8188/health >/dev/null 2>&1; then
    open "$ROOT/outputs"
    osascript -e 'display notification "Local server ready (CPU safe mode)" with title "Higgs Audio v3"'
    exit 0
  fi
  sleep 1
done

open "$ROOT/logs"
osascript -e 'display alert "Higgs Audio v3" message "Server did not start within 30 seconds. Check logs folder." as warning'
exit 1
