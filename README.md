# r1-triage

A read-only diagnostic for **Rabbit R1 ↔ OpenClaw** setups: tells you in ten
seconds whether a stuck R1 ("Starting OpenClaw… retrying", endless spinner,
"thinking…" forever) is your server's fault or Rabbit's.

Ships as a plain bash script and as an OpenClaw skill, so you can also just ask
your assistant *"the R1 is stuck, triage it"* from Telegram/Matrix/wherever.

---

## Why this exists

When an R1 stops responding, the failure could be in any of four places and the
device tells you nothing. Most people restart the gateway — which is almost
never the fix, and which orphans the session, making things worse.

This script checks each link and names the guilty one.

## The architecture (what took a while to work out)

```
R1 device  →  Rabbit cloud  →  rabbit-agent (your server)  →  openclaw ACP bridge  →  your agent
```

Findings that are not obvious from the outside, and that the script encodes:

1. **The ACP session is long-lived and reused.** Pressing PTT does **not** create
   a new job under `~/.rabbit-agent/jobs/`. A job directory from hours ago with
   no `exit` file is the *current* session. Judge health by the **modification
   time of its `stdout`**, not by job creation time.

2. **Three assistants are probed, not one.** Each dispatch creates
   `hermes-session-*`, `claude-session-*` and `openclaw-session-*` jobs. The
   first two failing with exit 127 is normal if you don't have those CLIs —
   look only at the `openclaw-session-*` job.

3. **"Capabilities exchanged, then silence" is the signature of a cloud-side
   stall.** If `stdout` shows the ACP handshake (`agentCapabilities`,
   `session/update`, config options) but no prompt ever arrives, your server is
   healthy and waiting: the cloud never forwarded what you said. Reboot the R1.

4. **The agent runs with a minimal environment.** If your `openclaw` binary
   lives on a shell-specific PATH (nvm, linuxbrew, asdf), jobs fail with
   `exit 127` and `stdbuf: failed to execute process`. Symlink the CLI to
   `/usr/local/bin`.

5. **Restarting the OpenClaw gateway orphans the session.** The cloud keeps
   talking into the dead one. After any `openclaw gateway restart`, expect to
   reboot the R1 before its next use.

6. **The rabbit-agent is not managed by systemd** by default. The installer
   starts it with `nohup` and relies on an `@reboot` crontab line that is not
   always written; when it is missing, the agent dies at the next reboot and
   nothing notices. It also auto-updates itself at the next start. Run it as a
   systemd user unit (`contrib/rabbit-agent.service`).

7. **More than one OpenClaw agent breaks the bridge on 2026.8.x.** The ACP
   bridge creates sessions under an unscoped key (`acp-bridge:<uuid>`); the
   gateway refuses prompts on it when several agents are configured, with
   *"session key has no explicit owner"*. Every other check passes while the
   R1 shows "listening…" and nothing else. The `acp.defaultAgent` config
   setting does not apply (it covers ACP runtime spawns). Fix: make the
   `openclaw` the agent resolves a wrapper that adds
   `--session agent:<id>:<key>` to the `acp` command
   (`contrib/openclaw-wrapper.sh`). Install it as a regular file: writing
   through the existing symlink overwrites OpenClaw's real entry file.

8. **rabbit-agent 0.1.10 deletes finished jobs on detach.** "Newest job
   directory" can be weeks old. Only a job without an `exit` file is evidence;
   otherwise read `logs/agent.log`.

9. **Rabbit's on-device flow is not a Settings menu.** Swipe to the OpenClaw
   agent page and tap *click to refresh*; nodes are managed at
   [hole.rabbit.tech](https://hole.rabbit.tech) → settings → nodes
   (remove / register node).

## Usage

```bash
# press PTT on the R1 and say something, THEN:
bash triage.sh
```

Overrides if your layout differs:

```bash
RABBIT_DIR=~/.rabbit-agent OPENCLAW_BIN=/usr/local/bin/openclaw bash triage.sh
PROBE=0 bash triage.sh            # skip the live ACP probe (it costs one short model turn)
PROBE_TIMEOUT=90 bash triage.sh   # allow a slow model more time
LIVE_MAX_AGE=3600 bash triage.sh  # treat open jobs older than 1h as leftovers (default 6h)
```

What the script checks, in order: rabbit-agent process, supervision and cloud
link (1); `openclaw` CLI as the agent resolves it (2); gateway health (3);
multi-agent session ownership (4); a live ACP probe, `initialize → session/new
→ session/prompt`, through the same binary the agent uses (5); the ACP session
and whether the gateway restarted underneath it (6).

Sample output:

```
== R1 TRIAGE v2.0.0 13:10:29Z ==
[OK]   rabbit-agent running versions/0.1.10
[OK]   rabbit-agent is a systemd user unit (active)
[OK]   control WS to Rabbit cloud: connected 0.1.10 2026-09-04T13:07:19.759Z
[OK]   openclaw CLI resolvable at /usr/local/bin/openclaw (OpenClaw 2026.8.2 (0965053))
[OK]   gateway healthy
[OK]   3 agents configured; /usr/local/bin/openclaw scopes ACP sessions to an agent (--session agent:main:rabbit-r1)
[OK]   ACP probe: prompt answered in 4.1s (stopReason=end_turn)
[INFO] live ACP session: openclaw-session-…-1788531394359-1
       last traffic 36s ago; replies streamed so far: 1

VERDICT: CHAIN HEALTHY — session live, traffic 36s ago.
         If the R1 still spins, the response is failing between the
         cloud and the device: reboot the R1.
```

## Install as an OpenClaw skill

```bash
mkdir -p ~/.openclaw/workspace/skills/r1-triage
cp SKILL.md triage.sh ~/.openclaw/workspace/skills/r1-triage/
chmod +x ~/.openclaw/workspace/skills/r1-triage/triage.sh
```

Then, from any channel your assistant listens on: *"The R1 is stuck, run the
triage — I just pressed PTT."* It runs the script and reports the verdict in
plain language.

## contrib/

- `rabbit-agent.service` — systemd user unit for the rabbit-agent
  (`Restart=always`, `/usr/local/bin` first on `PATH`, survives self-updates):
  `cp contrib/rabbit-agent.service ~/.config/systemd/user/ && systemctl --user enable --now rabbit-agent`
  (stop any `nohup` copy first: `pkill -f "rabbit-agent run"`).
- `openclaw-wrapper.sh` — the `/usr/local/bin/openclaw` wrapper for
  multi-agent gateways (finding 7). `sudo rm -f /usr/local/bin/openclaw` first,
  then `sudo install -m 755 contrib/openclaw-wrapper.sh /usr/local/bin/openclaw`;
  set `R1_AGENT` / `OPENCLAW_ENTRY` inside if your layout differs.

## Safety

Read-only by design: no restarts, no config changes, nothing sent anywhere.
The one exception is the ACP probe, which sends a single short prompt through
your own gateway to your own model (one isolated session, one turn); disable
it with `PROBE=0`. The skill instructions explicitly tell the assistant **not**
to restart the gateway as a first move, because that is the common wrong reflex
and it interrupts every other agent you're running.

## Tested against

OpenClaw 2026.8.2 · rabbit-agent 0.1.10 · rabbitOS 2.3 · Ubuntu 26.04 (v1 was tested on OpenClaw 2026.7.1 / rabbit-agent 0.1.3)

This integration is young and moves fast — if job layout or paths change,
the fix is usually one `grep` pattern in the script. PRs welcome. See
[CHANGELOG.md](CHANGELOG.md).

## Related

- [CLAWDIA Rabbit R1 + OpenClaw Pairing Kit](https://github.com/KI-NE-TIK/CLAWDIA-Rabbit-R1-OpenClaw-Pairing-Kit) — covers the *setup* side; this covers the *diagnosis* side.

## License

MIT
