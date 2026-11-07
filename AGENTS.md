# Agent Instructions (`agy-scratch`)

## Background Sidecars
All sidecar daemons live in [`sidecars/`](./sidecars/) and coordinate across conversation VMs via shared leases in `/home/antigravity/.gemini/sidecars/` (`/shared/user/.gemini/sidecars/`).

When starting a new conversation VM or waking up from sleep:
1. Run `bash /home/antigravity/MichaelRHead/agy-scratch/sidecars/ensure_sidecars.sh` (or inspect `/home/antigravity/.gemini/sidecars/update_readme_daemon.lease.json`).
2. If the daemon is not running (`NEEDS_START`), start it using `run_command` with `IsDaemon: true`:
   ```bash
   bash /home/antigravity/MichaelRHead/agy-scratch/sidecars/update_readme_daemon.sh
   ```
3. Do **not** spawn persistent background daemons from `/home/antigravity/.bashrc` (`BASH_ENV`), because `exebox` evaluates `BASH_ENV` on every `/bin/bash` invocation and tracks child processes per non-daemon command.
