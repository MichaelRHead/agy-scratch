#!/usr/bin/env bash
set -euo pipefail

# Checks whether the README freshness sidecar daemon is currently active
# (via local process check and shared cross-VM lease in ~/.gemini/sidecars/).
# Exits 0 if already running/active, or exits 1 if it needs to be started
# via run_command with IsDaemon: true.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DAEMON_SCRIPT="${SCRIPT_DIR}/update_readme_daemon.sh"
LEASE_FILE="/home/antigravity/.gemini/sidecars/update_readme_daemon.lease.json"
CONVERSATION_ID="${ANTIGRAVITY_CONVERSATION_ID:-vm-$(hostname)}"

if pgrep -f "${DAEMON_SCRIPT}" >/dev/null 2>&1; then
  echo "RUNNING_LOCALLY"
  exit 0
fi

python3 - "${LEASE_FILE}" "${CONVERSATION_ID}" <<'PY'
import json, os, pathlib, sys, time

lease_path = pathlib.Path(sys.argv[1])
conv_id = sys.argv[2]
now = time.time()

if not lease_path.exists():
    print("NEEDS_START: no lease file")
    sys.exit(1)

try:
    data = json.loads(lease_path.read_text(encoding="utf-8"))
except Exception as e:
    print(f"NEEDS_START: invalid lease ({e})")
    sys.exit(1)

expires_at = float(data.get("expires_at", 0))
holder_conv = data.get("conversation_id", "")
holder_pid = int(data.get("pid", -1))

if expires_at <= now:
    print("NEEDS_START: lease expired")
    sys.exit(1)

if holder_conv == conv_id and holder_pid > 0:
    try:
        os.kill(holder_pid, 0)
    except OSError:
        print("NEEDS_START: same-VM PID died after sleep/wake")
        sys.exit(1)

print(f"ACTIVE_IN_OTHER_VM: {data.get('holder')} (expires in {int(expires_at - now)}s)")
sys.exit(0)
PY
