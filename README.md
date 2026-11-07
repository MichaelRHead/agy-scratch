# agy-scratch

A scratch space for experimenting with **Antigravity Remote** and exploring how much can be built, tested, and shipped using just the web interface backed by GitHub.

## Purpose

- **Explore Antigravity Remote**: Test agent workflows, tools, and integrations directly from the web UI.
- **GitHub-Backed Development**: Prototype projects, scripts, and experiments with version control and PR workflows without needing a local dev environment.
- **Quick Prototyping**: A sandbox for throwaway code, proof-of-concepts, and testing capabilities on the fly.

## Sidecars

Sidecar scripts are stored in [`sidecars/`](./sidecars/) and coordinate across conversation VMs via shared leases in `/home/antigravity/.gemini/sidecars/`:

- [`sidecars/update_readme_daemon.sh`](./sidecars/update_readme_daemon.sh): Daily freshness updater for `README.md` (defaults to `INTERVAL_SECONDS=86400`, `HEARTBEAT_SECONDS=30`, `LEASE_TTL_SECONDS=90`, and `PUSH_CHANGES=1`). Reclaims its lease immediately if the same VM wakes up from sleep after its old PID exited.
- [`sidecars/ensure_sidecars.sh`](./sidecars/ensure_sidecars.sh): Checks whether `update_readme_daemon.sh` is running locally or holds an active lease in another VM, returning `NEEDS_START` (exit code `1`) when the agent should relaunch it via `IsDaemon: true`.

<!-- FRESHNESS_START -->
_Last updated: `2026-11-07T02:01:49+00:00`_
<!-- FRESHNESS_END -->
