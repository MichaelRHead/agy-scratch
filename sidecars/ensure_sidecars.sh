#!/usr/bin/env bash
set -euo pipefail

# Checks whether the README freshness sidecar daemon is currently active
# (via VM-local kernel flock in /tmp and shared cross-VM lease in ~/.gemini/sidecars/).
# Exits 0 if already running/active, or exits 1 if it needs to be started
# via run_command with IsDaemon: true.

LEASE_FILE="/home/antigravity/.gemini/sidecars/update_readme_daemon.lease.json"
LOCAL_LOCK_FILE="/tmp/update_readme_daemon.lock"
CONVERSATION_ID="${ANTIGRAVITY_CONVERSATION_ID:-vm-$(hostname)}"

python3 - "${LEASE_FILE}" "${LOCAL_LOCK_FILE}" "${CONVERSATION_ID}" <<'PY'
import fcntl, json, os, pathlib, sys, time

lease_path = pathlib.Path(sys.argv[1])
lock_path = pathlib.Path(sys.argv[2])
conv_id = sys.argv[3]
now = time.time()

def is_local_daemon_alive(path: pathlib.Path) -> bool:
    if not path.exists():
        return False
    try:
        fd = os.open(str(path), os.O_RDWR)
    except OSError:
        return False
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        fcntl.flock(fd, fcntl.LOCK_UN)
        return False
    except BlockingIOError:
        return True
    finally:
        os.close(fd)

local_alive = is_local_daemon_alive(lock_path)

if not lease_path.exists():
    if local_alive:
        print("RUNNING_LOCALLY (awaiting lease write)")
        sys.exit(0)
    print("NEEDS_START: no lease file")
    sys.exit(1)

try:
    data = json.loads(lease_path.read_text(encoding="utf-8"))
except Exception as e:
    print(f"NEEDS_START: invalid lease ({e})")
    sys.exit(1)

expires_at = float(data.get("expires_at", 0))
holder_conv = data.get("conversation_id", "")

if expires_at <= now:
    print("NEEDS_START: lease expired")
    sys.exit(1)

if holder_conv == conv_id:
    if local_alive:
        print(f"RUNNING_LOCALLY: {data.get('holder')} (expires in {int(expires_at - now)}s)")
        sys.exit(0)
    else:
        print("NEEDS_START: same-VM daemon died after sleep/wake")
        sys.exit(1)

if local_alive:
    print(f"RUNNING_LOCALLY (standby; leader is {data.get('holder')}, expires in {int(expires_at - now)}s)")
else:
    print(f"ACTIVE_IN_OTHER_VM: {data.get('holder')} (expires in {int(expires_at - now)}s)")
sys.exit(0)
PY
