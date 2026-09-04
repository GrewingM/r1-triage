# Changelog

All notable changes to r1-triage. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow SemVer.

## [2.0.0] — 2026-09-04

Tested against OpenClaw 2026.8.2, rabbit-agent 0.1.10, rabbitOS 2.3.

### Added
- **Live ACP probe** (check 5): `initialize → session/new → session/prompt` through the same binary the rabbit-agent uses. Proves bridge + gateway + model end to end, independently of Rabbit's cloud. Costs one short model turn; `PROBE=0` skips it, `PROBE_TIMEOUT` (default 60 s) bounds it.
- **Multi-agent ownership check** (check 4). OpenClaw 2026.8.x refuses prompts on the bridge's default unscoped session key (`acp-bridge:<uuid>`) when more than one agent is configured — *"session key has no explicit owner"*. Every previous check passed in that state while the R1 showed "listening…" and nothing else. The script now detects >1 agent without an agent-scoped `--session` in the wrapper, and the probe maps that exact error to the fix.
- **Supervision check** (check 1b): warns when rabbit-agent is neither a systemd user unit nor restarted by an `@reboot` crontab line. The installer starts the agent with `nohup` and does not always write the crontab entry; an unsupervised agent silently dies at the next reboot.
- **Cloud link check** (check 1c) from `runtime/rabbit-agent.status.json` (`status`, `version`).
- **Orphaned-session detection**: if the gateway's start time is newer than the live session's creation, the verdict is "ORPHANED SESSION — reboot the R1" (README item 5, now automated).
- Duplicate-process warning when a `nohup` copy and a systemd copy are both running.
- `contrib/rabbit-agent.service` — systemd user unit (`Restart=always`, `/usr/local/bin` first on `PATH`, survives the agent's self-updates).
- `contrib/openclaw-wrapper.sh` — the `/usr/local/bin/openclaw` wrapper that scopes R1 sessions to one agent by calling the OpenClaw entry file directly (no name-based re-entry).
- On-device recovery steps in the verdicts updated to Rabbit's documented flow: swipe to the OpenClaw page → *click to refresh*; rabbithole → settings → nodes → remove / register node.

### Changed
- **Job discovery**: rabbit-agent ≥ 0.1.10 deletes finished jobs on detach, so "newest job directory" can be weeks old. Only a job without an `exit` file counts as live; otherwise the last `BackgroundJob 'openclaw-session…'` event from `logs/agent.log` is reported with its timestamp.
- `OPENCLAW_BIN` now defaults to `/usr/local/bin/openclaw` when present — that is what the agent's minimal `PATH` resolves — falling back to `command -v openclaw`.
- Version no longer read only from the process command line; falls back to `current.json`.
- Verdict line adds a count of warnings so a "RABBIT-SIDE" verdict still surfaces server hygiene issues.

### Fixed
- "no live session" false negatives on 0.1.10 (stale directories from weeks earlier were reported as the newest job).
- Pre-0.1.10 job directories with an empty `exit` file were treated as live sessions and could trigger a false ORPHANED verdict; a job is now live only with recent stdout activity (`LIVE_MAX_AGE`, default 6 h). Stale ones are counted and reported as safe to delete.
- Agent count read from `openclaw agents list --json` (the text listing was over-counted).

### Notes for operators
- After **any** `openclaw gateway restart`, reboot the R1 before its next use; the cloud keeps the orphaned session and forwards nothing into the new one.
- Never write through `/usr/local/bin/openclaw` with `tee`/`>` while it is a **symlink**: it writes into OpenClaw's real entry file. Remove the link, then create the wrapper as a regular file. (Restore, if it happens: `npm pack openclaw@<version>` and copy `package/openclaw.mjs` back.)
- `acp.defaultAgent` in OpenClaw's config applies to ACP *runtime* spawns, not to the bridge; it does not fix the ownership refusal.

## [1.0.0] — 2026-08-06

Initial release. Checks: rabbit-agent process, `openclaw` CLI resolvable from a minimal `PATH`, gateway health, live ACP session age; verdicts SERVER-SIDE / CHAIN HEALTHY / RABBIT-SIDE. Tested against OpenClaw 2026.7.1, rabbit-agent 0.1.3, rabbitOS 2.3.
