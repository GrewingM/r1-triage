---
name: r1-triage
description: >
  Diagnose why a Rabbit R1 cannot reach its OpenClaw gateway. Use whenever the
  operator says the R1 is stuck, spinning, "thinking" forever, "listening…"
  with no transcript, "no active openclaw sessions", "resuming…" that never
  ends, "not responding", "unable to connect", or asks to check the rabbit.
  Runs a read-only triage script and interprets the verdict: server-side fault
  vs Rabbit cloud/device fault, with the specific next action.
---

# R1 Triage

The R1 reaches this gateway through:

    R1 device → Rabbit cloud → rabbit-agent (this host) → openclaw ACP bridge → gateway

Most failures are in the first two links, but two server-side ones are silent
(a dead rabbit-agent, and a gateway that refuses the bridge's session key).
This skill proves where the break is in under a minute, so nobody debugs the
wrong layer.

## How to run

1. Ask the operator to **press PTT on the R1 and say something, right before**
   you run the script — the freshness of the session traffic is the signal.
2. Run: `bash {skill_dir}/triage.sh`
   The script makes one short prompt through the gateway (the ACP probe). If
   the operator objects to spending a model turn, run `PROBE=0 bash {skill_dir}/triage.sh`.
3. Read the VERDICT line and report it in plain language, with the one action
   that follows. Mention `[WARN]` lines briefly even when the verdict is not
   server-side; they are latent faults.

## Interpreting the verdict

**SERVER-SIDE PROBLEM** — one of the [FAIL] lines explains it:
- rabbit-agent not running → if a systemd unit exists: `systemctl --user restart rabbit-agent`;
  otherwise relaunch with `bash ~/.rabbit-agent/install.sh` and recommend the
  unit in `contrib/rabbit-agent.service` so it survives the next reboot
- openclaw CLI not resolvable → put it on the default PATH; the agent runs
  with a minimal environment and cannot see shell-specific PATHs
- gateway unhealthy → investigate the gateway; warn the operator that a
  restart interrupts every other agent before suggesting one
- ACP probe "no explicit owner" → more than one agent is configured and the
  bridge's sessions have no owner; install `contrib/openclaw-wrapper.sh` as
  `/usr/local/bin/openclaw` (regular file, remove the symlink first) so ACP
  sessions are scoped with `--session agent:<id>:<key>`
- ACP probe timeout → the gateway accepts the session but the model does not
  answer: check model/provider health (`openclaw models list`, gateway logs)

**ORPHANED SESSION** — the gateway restarted while the cloud held a session:
the R1 needs a reboot (or a new session from the notebook icon). Nothing to
fix on the server.

**RABBIT-SIDE (session idle, or no session)** — the server is fine:
1. On the R1, swipe to the OpenClaw agent page and tap *click to refresh*, then PTT
2. Reboot the R1 (fixes it most of the time)
3. rabbithole (hole.rabbit.tech) → settings → nodes: remove the node and
   register it again (the command it gives you re-registers the agent)
4. If it persists, suspect a Rabbit cloud outage — check their status/Discord

**CHAIN HEALTHY but the R1 still spins** — the failure is between the cloud and
the device display: reboot the R1.

## Rules

- **Never restart the gateway as a first move.** It is almost never the fix for
  R1 issues, it interrupts other agents and channels, and it orphans the R1's
  session (the operator then has to reboot the device anyway).
- The ACP session is long-lived: a job directory with no `exit` file is the
  *current* session. rabbit-agent 0.1.10 deletes finished jobs straight away,
  so an old directory that still exists is stale, not evidence; the script
  reads `logs/agent.log` in that case.
- `hermes-session-*` and `claude-session-*` jobs failing with exit 127 is normal
  when those CLIs aren't installed. Only `openclaw-session-*` matters.
- After any gateway restart, the R1 needs a reboot before its next use.
- The `openclaw` binary the agent runs is `/usr/local/bin/openclaw`. Never
  write to that path while it is a symlink; it points into the OpenClaw
  install and `tee`/`>` will overwrite the real entry file.
- Keep the report short: which link is broken, and the single next action.
