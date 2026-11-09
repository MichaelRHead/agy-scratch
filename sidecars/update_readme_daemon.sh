#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="/home/antigravity/MichaelRHead/agy-scratch"
REPO_URL="https://github.com/MichaelRHead/agy-scratch.git"
README_FILE="${REPO_DIR}/README.md"

INTERVAL_SECONDS="${INTERVAL_SECONDS:-86400}"
HEARTBEAT_SECONDS="${HEARTBEAT_SECONDS:-30}"
LEASE_TTL_SECONDS="${LEASE_TTL_SECONDS:-90}"
PUSH_CHANGES="${PUSH_CHANGES:-1}"

SHARED_STATE_DIR="/home/antigravity/.gemini/sidecars"
LEASE_FILE="${SHARED_STATE_DIR}/update_readme_daemon.lease.json"
LOG_FILE="${SHARED_STATE_DIR}/update_readme_daemon.log"
LOCAL_LOCK_FILE="/tmp/update_readme_daemon.lock"
CONVERSATION_ID="${ANTIGRAVITY_CONVERSATION_ID:-vm-$(hostname)}"
MY_PID="${BASHPID:-$$}"
INSTANCE_ID="${CONVERSATION_ID}:${MY_PID}"

mkdir -p "${SHARED_STATE_DIR}"

# Acquire VM-local kernel flock so at most one daemon runs per VM even across isolated exebox PID namespaces
exec 9>"${LOCAL_LOCK_FILE}"
if ! flock -n 9; then
  echo "[$(date -Iseconds)] [${INSTANCE_ID}] Another update_readme_daemon.sh is already running in this VM; exiting."
  exit 0
fi

ensure_repo() {
  if [[ ! -d "${REPO_DIR}/.git" ]]; then
    mkdir -p "$(dirname "${REPO_DIR}")"
    git clone "${REPO_URL}" "${REPO_DIR}" >/dev/null 2>&1 || return 1
  fi
  if ! git -C "${REPO_DIR}" config --get remote.origin.fetch >/dev/null 2>&1; then
    git -C "${REPO_DIR}" config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*"
  fi
  return 0
}

acquire_or_renew_lease() {
  python3 - "${LEASE_FILE}" "${CONVERSATION_ID}" "${MY_PID}" "${LEASE_TTL_SECONDS}" <<'PY'
import json, os, pathlib, sys, tempfile, time

lease_path = pathlib.Path(sys.argv[1])
conv_id = sys.argv[2]
my_pid = int(sys.argv[3])
ttl = int(sys.argv[4])
instance_id = f"{conv_id}:{my_pid}"
now = time.time()

current = None
if lease_path.exists():
    try:
        current = json.loads(lease_path.read_text(encoding="utf-8"))
    except Exception:
        current = None

if current:
    holder = current.get("holder", "")
    holder_conv = current.get("conversation_id", "")
    expires_at = float(current.get("expires_at", 0))

    if holder != instance_id and expires_at > now:
        # Since this process holds the VM-local flock (/tmp/update_readme_daemon.lock),
        # any previous holder with the same conversation_id is guaranteed to be dead.
        if holder_conv == conv_id:
            pass  # Reclaim immediately after VM wake-up / previous daemon exit
        else:
            sys.exit(1)

payload = {
    "holder": instance_id,
    "conversation_id": conv_id,
    "pid": my_pid,
    "updated_at": now,
    "expires_at": now + ttl,
}
fd, tmp_path = tempfile.mkstemp(dir=str(lease_path.parent), prefix=".lease-", suffix=".tmp")
with os.fdopen(fd, "w", encoding="utf-8") as f:
    json.dump(payload, f)
os.replace(tmp_path, lease_path)
sys.exit(0)
PY
}

release_lease() {
  python3 - "${LEASE_FILE}" "${INSTANCE_ID}" <<'PY' || true
import json, pathlib, sys
lease_path = pathlib.Path(sys.argv[1])
instance_id = sys.argv[2]
if lease_path.exists():
    try:
        data = json.loads(lease_path.read_text(encoding="utf-8"))
        if data.get("holder") == instance_id:
            lease_path.unlink(missing_ok=True)
    except Exception:
        pass
PY
}
trap release_lease EXIT INT TERM

seconds_until_due() {
  python3 - "${README_FILE}" "${INTERVAL_SECONDS}" <<'PY'
import datetime, pathlib, re, sys

readme_path = pathlib.Path(sys.argv[1])
interval = int(sys.argv[2])

if not readme_path.exists():
    print(0)
    sys.exit(0)

content = readme_path.read_text(encoding="utf-8")
m = re.search(r"<!-- FRESHNESS_START -->.*?`([^`]+)`.*?<!-- FRESHNESS_END -->", content, re.DOTALL)
if not m:
    print(0)
    sys.exit(0)

try:
    last_dt = datetime.datetime.fromisoformat(m.group(1))
    now_dt = datetime.datetime.now(datetime.timezone.utc)
    elapsed = (now_dt - last_dt).total_seconds()
    remaining = int(max(0, interval - elapsed))
    print(remaining)
except Exception:
    print(0)
PY
}

log_msg() {
  local msg="[$(date -Iseconds)] [${INSTANCE_ID}] $*"
  echo "${msg}"
  echo "${msg}" >> "${LOG_FILE}" 2>/dev/null || true
}

sync_and_update_if_due() {
  ensure_repo || return 0
  git -C "${REPO_DIR}" fetch origin main >/dev/null 2>&1 || true
  git -C "${REPO_DIR}" rebase --autostash origin/main >/dev/null 2>&1 || true

  local rem
  rem="$(seconds_until_due)"
  if (( rem > 0 )); then
    return 0
  fi

  local ts
  ts="$(date -Iseconds)"
  python3 - "$README_FILE" "$ts" <<'PY'
import pathlib, re, sys

readme_path = pathlib.Path(sys.argv[1])
ts = sys.argv[2]
block = f"<!-- FRESHNESS_START -->\n_Last updated: `{ts}`_\n<!-- FRESHNESS_END -->"

if readme_path.exists():
    content = readme_path.read_text(encoding="utf-8")
    pattern = re.compile(r"<!-- FRESHNESS_START -->.*?<!-- FRESHNESS_END -->", re.DOTALL)
    if pattern.search(content):
        content = pattern.sub(block, content)
    else:
        content = content.rstrip() + "\n\n" + block + "\n"
else:
    content = f"# agy-scratch\n\n{block}\n"

readme_path.write_text(content, encoding="utf-8")
PY
  log_msg "Updated freshness stamp -> ${ts}"

  if [[ "${PUSH_CHANGES}" == "1" ]]; then
    if ! git -C "${REPO_DIR}" diff --quiet -- "${README_FILE}"; then
      git -C "${REPO_DIR}" add "${README_FILE}"
      git -C "${REPO_DIR}" commit -m "chore: update README freshness stamp (${ts})" || true
      for attempt in 1 2 3; do
        if git -C "${REPO_DIR}" push -u origin HEAD:main; then
          break
        fi
        log_msg "Push conflict on attempt ${attempt}; fetching & rebasing..."
        git -C "${REPO_DIR}" fetch origin main || true
        git -C "${REPO_DIR}" rebase origin/main || true
        sleep 2
      done
    fi
  fi
}

log_msg "Starting coordinated README freshness sidecar (interval=${INTERVAL_SECONDS}s)"
was_leader=0
while true; do
  if acquire_or_renew_lease; then
    if (( was_leader == 0 )); then
      log_msg "Acquired cross-VM lease (${LEASE_FILE})"
      was_leader=1
    fi
    sync_and_update_if_due
  else
    if (( was_leader == 1 )); then
      log_msg "Lost cross-VM lease; entering standby"
      was_leader=0
    fi
  fi
  sleep "${HEARTBEAT_SECONDS}"
done
