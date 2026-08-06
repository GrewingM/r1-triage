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

6. **The rabbit-agent is not managed by systemd** by default and auto-updates
   itself. After a version bump, a device re-pair is more likely to be needed.

## Usage

```bash
# press PTT on the R1 and say something, THEN:
bash triage.sh
```

Overrides if your layout differs:

```bash
RABBIT_DIR=~/.rabbit-agent OPENCLAW_BIN=/usr/local/bin/openclaw bash triage.sh
```

Sample output:

```
== R1 TRIAGE 09:17:50Z ==
[OK]   rabbit-agent running versions/0.1.3
[OK]   openclaw CLI resolvable at /usr/local/bin/openclaw (OpenClaw 2026.7.1)
[OK]   gateway healthy
[INFO] live ACP session: openclaw-session-…-1786007592193-1
       last traffic 276s ago

VERDICT: RABBIT-SIDE — session open but idle for 276s.
         If PTT was pressed just before running this, the cloud is not
         forwarding prompts into the session.
         1) Reboot the R1.  2) Settings > Device > OpenClaw > Reset OpenClaw, re-pair.
         3) If it persists: suspect a Rabbit cloud outage.
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

## Safety

Read-only by design: no restarts, no config changes, no network calls, nothing
sent anywhere. The skill instructions explicitly tell the assistant **not** to
restart the gateway as a first move, because that is the common wrong reflex
and it interrupts every other agent you're running.

## Tested against

OpenClaw 2026.7.1 · rabbit-agent 0.1.3 · rabbitOS 2.3 · Ubuntu

This integration is young and moves fast — if job layout or paths change,
the fix is usually one `grep` pattern in the script. PRs welcome.

## Related

- [CLAWDIA Rabbit R1 + OpenClaw Pairing Kit](https://github.com/KI-NE-TIK/CLAWDIA-Rabbit-R1-OpenClaw-Pairing-Kit) — covers the *setup* side; this covers the *diagnosis* side.

## License

MIT
