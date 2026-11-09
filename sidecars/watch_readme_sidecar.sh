#!/usr/bin/env bash
set -euo pipefail

# Non-daemon keep-alive watch cycle for Antigravity Remote (/goal).
# Runs for WATCH_SECONDS (default 480s = 8m, safely under the 600s BidiExecuteUvm
# gRPC stream deadline) to keep the uVM active, then exits 0 so the agent wakes
# up and renews the watch. Exits early (code 2) if the daemon needs to be restarted.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENSURE_SCRIPT="${SCRIPT_DIR}/ensure_sidecars.sh"
WATCH_SECONDS="${WATCH_SECONDS:-480}"
STEP_SECONDS="${STEP_SECONDS:-30}"

elapsed=0
while (( elapsed < WATCH_SECONDS )); do
  if ! out="$("${ENSURE_SCRIPT}" 2>&1)"; then
    echo "[$(date -Iseconds)] Sidecar needs restart: ${out}"
    exit 2
  fi
  sleep "${STEP_SECONDS}"
  elapsed=$(( elapsed + STEP_SECONDS ))
done

out="$("${ENSURE_SCRIPT}" 2>&1)"
echo "[$(date -Iseconds)] Keep-alive watch cycle completed (${elapsed}s): ${out}"
