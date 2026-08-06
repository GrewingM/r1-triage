---
name: r1-triage
description: >
  Diagnose why a Rabbit R1 cannot reach its OpenClaw gateway. Use whenever the
  operator says the R1 is stuck, spinning, "thinking" forever, "not
  responding", "unable to connect", or asks to check the rabbit. Runs a
  read-only triage script and interprets the verdict: server-side fault vs
  Rabbit cloud/device fault, with the specific next action.
---

# R1 Triage

The R1 reaches this gateway through:

    R1 device → Rabbit cloud → rabbit-agent (this host) → openclaw ACP bridge

Most failures are in the first two links. This skill proves where the break is
in under a minute, so nobody debugs the server for nothing.

## How to run

1. Ask the operator to **press PTT on the R1 and say something, right before**
   you run the script — the freshness of the session traffic is the signal.
2. Run: `bash {skill_dir}/triage.sh`
3. Read the VERDICT line and report it in plain language, with the one action
   that follows.

## Interpreting the verdict

**SERVER-SIDE PROBLEM** — one of the [FAIL] lines explains it:
- rabbit-agent not running → relaunch: `nohup ~/.rabbit-agent/versions/*/rabbit-agent run >/dev/null 2>&1 &`
- openclaw CLI not resolvable → symlink it onto the default PATH; the agent
  runs with a minimal environment and cannot see shell-specific PATHs
- gateway unhealthy → investigate the gateway; warn the operator that a
  restart interrupts every other agent before suggesting one

**RABBIT-SIDE (session idle, or no session)** — the server is fine:
1. Reboot the R1 (fixes it most of the time)
2. R1: Settings → Device → OpenClaw → Reset OpenClaw, then re-pair
3. If it persists, suspect a Rabbit cloud outage — check their status/Discord

**CHAIN HEALTHY but the R1 still spins** — the failure is between the cloud and
the device display: reboot the R1.

## Rules

- **Never restart the gateway as a first move.** It is almost never the fix for
  R1 issues and it interrupts other agents and channels.
- The ACP session is long-lived: an old job directory with no `exit` file is the
  *current* session, not a stale one. Judge by last activity, not creation time.
- `hermes-session-*` and `claude-session-*` jobs failing with exit 127 is normal
  when those CLIs aren't installed. Only `openclaw-session-*` matters.
- After any gateway restart, the R1 usually needs a reboot: the restart orphans
  the session the cloud is still talking into.
- Keep the report short: which link is broken, and the single next action.
