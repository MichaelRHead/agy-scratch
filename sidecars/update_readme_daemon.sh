#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
README_FILE="${REPO_DIR}/README.md"

INTERVAL_SECONDS="${INTERVAL_SECONDS:-86400}"
HEARTBEAT_SECONDS="${HEARTBEAT_SECONDS:-30}"
LEASE_TTL_SECONDS="${LEASE_TTL_SECONDS:-90}"
PUSH_CHANGES="${PUSH_CHANGES:-1}"

SHARED_STATE_DIR="/home/antigravity/.gemini/sidecars"
LEASE_FILE="${SHARED_STATE_DIR}/update_readme_daemon.lease.json"
INSTANCE_ID="${ANTIGRAVITY_CONVERSATION_ID:-vm-$(hostname)}:${BASHPID:-$$}"

mkdir -p "${SHARED_STATE_DIR}"

# Ensure git remote origin has standard fetch refspec in fresh VM clones
if ! git -C "${REPO_DIR}" config --get remote.origin.fetch >/dev/null 2>&1; then
  git -C "${REPO_DIR}" config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*"
fi

acquire_or_renew_lease() {
  python3 - "${LEASE_FILE}" "${INSTANCE_ID}" "${LEASE_TTL_SECONDS}" <<'PY'
import json, os, pathlib, sys, tempfile, time

lease_path = pathlib.Path(sys.argv[1])
instance_id = sys.argv[2]
ttl = int(sys.argv[3])
now = time.time()

current = None
if lease_path.exists():
    try:
        current = json.loads(lease_path.read_text(encoding="utf-8"))
    except Exception:
        current = None

if current and current.get("holder") != instance_id and current.get("expires_at", 0) > now:
    sys.exit(1)

payload = {
    "holder": instance_id,
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

sync_and_update_if_due() {
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
  echo "[$(date -Iseconds)] [${INSTANCE_ID}] Updated freshness stamp -> ${ts}"

  if [[ "${PUSH_CHANGES}" == "1" ]]; then
    if ! git -C "${REPO_DIR}" diff --quiet -- "${README_FILE}"; then
      git -C "${REPO_DIR}" add "${README_FILE}"
      git -C "${REPO_DIR}" commit -m "chore: update README freshness stamp (${ts})" || true
      for attempt in 1 2 3; do
        if git -C "${REPO_DIR}" push -u origin HEAD:main; then
          break
        fi
        echo "[$(date -Iseconds)] Push conflict on attempt ${attempt}; fetching & rebasing..."
        git -C "${REPO_DIR}" fetch origin main || true
        git -C "${REPO_DIR}" rebase origin/main || true
        sleep 2
      done
    fi
  fi
}

echo "[$(date -Iseconds)] Starting coordinated README freshness sidecar (instance=${INSTANCE_ID}, interval=${INTERVAL_SECONDS}s)"
was_leader=0
while true; do
  if acquire_or_renew_lease; then
    if (( was_leader == 0 )); then
      echo "[$(date -Iseconds)] Acquired cross-VM lease (${LEASE_FILE})"
      was_leader=1
    fi
    sync_and_update_if_due
  else
    if (( was_leader == 1 )); then
      echo "[$(date -Iseconds)] Lost cross-VM lease; entering standby"
      was_leader=0
    fi
  fi
  sleep "${HEARTBEAT_SECONDS}"
done
