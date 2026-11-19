#!/usr/bin/env bash
set -euo pipefail

BASE="$HOME/dggs-ai"
RUNNER="$BASE/launcher/run-router.sh"
BINARY="$BASE/llama.cpp/build-mi100-rocm641/bin/llama-server"
MAIN="$BASE/models/flashnext/Qwen3.8-Flash-Next-IQ4_XS/Qwen3.8-Flash-Next-IQ4_XS-00001-of-00003.gguf"
ALT="$BASE/models/qwen35-uncensored/Qwen3.5-122B-A10B-Uncensored-HauhauCS-Aggressive-Q5_K_M.gguf"
PRESETS="$HOME/.config/dggs-ai/models.ini"
UNIT="$HOME/.config/systemd/user/dggs-llama.service"

if [[ ! -x "$BINARY" ]]; then
  echo "ERROR: Missing compiled llama-server: $BINARY" >&2
  exit 1
fi
if [[ ! -f "$MAIN" ]]; then
  echo "ERROR: Main GGUF first shard not found: $MAIN" >&2
  exit 1
fi
for shard in 00002-of-00003 00003-of-00003; do
  file="${MAIN/00001-of-00003/$shard}"
  if [[ ! -f "$file" ]]; then
    echo "ERROR: Missing shard: $file" >&2
    exit 1
  fi
done
if [[ ! -x "$RUNNER" ]]; then
  chmod 700 "$RUNNER"
fi
if ! command -v systemctl >/dev/null 2>&1; then
  echo "ERROR: systemctl is not available on this server." >&2
  exit 1
fi
if ! systemctl --user show-environment >/dev/null 2>&1; then
  echo "ERROR: Your systemd user manager is unavailable." >&2
  echo "Check login sessions before continuing; do not enable linger automatically on a shared server." >&2
  exit 1
fi

mkdir -p "$(dirname "$PRESETS")" "$(dirname "$UNIT")"
stamp="$(date +%Y%m%d-%H%M%S)"
if [[ -f "$PRESETS" ]]; then
  cp "$PRESETS" "${PRESETS}.bak.${stamp}"
fi
if [[ -f "$UNIT" ]]; then
  cp "$UNIT" "${UNIT}.bak.${stamp}"
fi

{
  printf 'version = 1\n\n'
  printf '[dggs-main]\nmodel = %s\n\n' "$MAIN"
  if [[ -f "$ALT" ]]; then
    printf '[dggs-uncensored]\nmodel = %s\n\n' "$ALT"
  fi
} > "$PRESETS"

cat > "$UNIT" <<'UNIT_FILE'
[Unit]
Description=DGGS llama.cpp model router (one GPU model at a time)
StartLimitIntervalSec=120
StartLimitBurst=3

[Service]
Type=simple
WorkingDirectory=%h/dggs-ai/llama.cpp
ExecStart=%h/dggs-ai/launcher/run-router.sh
Restart=on-failure
RestartSec=15
KillMode=control-group

[Install]
WantedBy=default.target
UNIT_FILE

systemctl --user daemon-reload
printf '\nInstalled: %s\n' "$UNIT"
printf 'Model presets: %s\n' "$PRESETS"
printf 'Available models:\n'
if [[ -f "$ALT" ]]; then
  printf '  dggs-main\n  dggs-uncensored\n'
else
  printf '  dggs-main\n'
  printf '  (The optional uncensored GGUF was not found; no download was attempted.)\n'
fi
printf '\nThe router is installed but NOT enabled at login or started automatically.\n'
printf 'Use the Windows DGGS Start launcher to start it on demand.\n'
printf 'Do not use apt autoremove or kill other users\047 GPU jobs.\n'
