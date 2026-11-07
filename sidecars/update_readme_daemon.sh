#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
README_FILE="${REPO_DIR}/README.md"
INTERVAL_SECONDS="${INTERVAL_SECONDS:-86400}"
PUSH_CHANGES="${PUSH_CHANGES:-1}"

update_freshness() {
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
  echo "[$(date -Iseconds)] Updated freshness stamp in ${README_FILE} -> ${ts}"

  if [[ "${PUSH_CHANGES}" == "1" ]]; then
    if ! git -C "${REPO_DIR}" diff --quiet -- "${README_FILE}"; then
      git -C "${REPO_DIR}" add "${README_FILE}"
      git -C "${REPO_DIR}" commit -m "chore: update README freshness stamp (${ts})" || true
      git -C "${REPO_DIR}" push -u origin HEAD || echo "[$(date -Iseconds)] Warning: git push failed"
    fi
  fi
}

echo "[$(date -Iseconds)] Starting README freshness sidecar daemon (interval=${INTERVAL_SECONDS}s)"
while true; do
  update_freshness
  sleep "${INTERVAL_SECONDS}"
done
