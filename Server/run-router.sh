#!/usr/bin/env bash
set -euo pipefail

BASE="$HOME/dggs-ai"
BINARY="$BASE/llama.cpp/build-mi100-rocm641/bin/llama-server"
PRESETS="$HOME/.config/dggs-ai/models.ini"

if [[ ! -x "$BINARY" ]]; then
  echo "llama-server not found: $BINARY" >&2
  exit 1
fi
if [[ ! -s "$PRESETS" ]]; then
  echo "Model preset file missing: $PRESETS" >&2
  exit 1
fi

export HIP_VISIBLE_DEVICES=0,1,2,3
export ROCM_PATH=/opt/rocm-6.4.1
export HIP_PATH=/opt/rocm-6.4.1

exec "$BINARY" \
  --models-preset "$PRESETS" \
  --models-max 1 \
  --models-autoload \
  --gpu-layers auto \
  --split-mode layer \
  --fit on \
  --fit-target 3072 \
  --ctx-size 32768 \
  --parallel 1 \
  --threads 16 \
  --batch-size 256 \
  --ubatch-size 64 \
  --sleep-idle-seconds 900 \
  --jinja \
  --host 127.0.0.1 \
  --port 8080
