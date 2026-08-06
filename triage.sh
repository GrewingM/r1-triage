#!/usr/bin/env bash
# r1-triage — diagnose why a Rabbit R1 is stuck talking to an OpenClaw gateway.
#
# Read-only: makes no changes, restarts nothing, sends nothing.
# Exit code is always 0 — read the VERDICT line.
#
# Usage:  bash triage.sh            (press PTT on the R1 first, then run)
#         RABBIT_DIR=... OPENCLAW_BIN=... bash triage.sh   (override defaults)
#
# Tested against: OpenClaw 2026.7.1, rabbit-agent 0.1.3, rabbitOS 2.3
# License: MIT

set -u

RABBIT_DIR="${RABBIT_DIR:-$HOME/.rabbit-agent}"
OPENCLAW_BIN="${OPENCLAW_BIN:-$(command -v openclaw || echo /usr/local/bin/openclaw)}"
IDLE_OK_SECONDS="${IDLE_OK_SECONDS:-120}"

NOW_S=$(date +%s)
echo "== R1 TRIAGE $(date -u +%H:%M:%SZ) =="

# 1. Is the rabbit-agent process alive? (it is NOT managed by systemd by default)
if pgrep -f "rabbit-agent run" >/dev/null 2>&1; then
  VER=$(pgrep -af "rabbit-agent run" | grep -o 'versions/[^/]*' | head -1)
  echo "[OK]   rabbit-agent running ${VER:-}"
  AGENT_OK=1
else
  echo "[FAIL] rabbit-agent NOT running"
  AGENT_OK=0
fi

# 2. Can the openclaw CLI be resolved the way the agent invokes it?
#    The agent runs with a minimal environment: a CLI only on a shell-specific
#    PATH (nvm, linuxbrew, asdf...) will fail with exit 127.
if "$OPENCLAW_BIN" --version >/dev/null 2>&1; then
  echo "[OK]   openclaw CLI resolvable at $OPENCLAW_BIN ($("$OPENCLAW_BIN" --version 2>/dev/null | head -c 40))"
  CLI_OK=1
else
  echo "[FAIL] openclaw CLI not resolvable at $OPENCLAW_BIN"
  echo "       Fix: symlink it onto the default PATH, e.g."
  echo "       sudo ln -s \"\$(command -v openclaw)\" /usr/local/bin/openclaw"
  CLI_OK=0
fi

# 3. Gateway health
if "$OPENCLAW_BIN" gateway health 2>/dev/null | grep -qi "OK"; then
  echo "[OK]   gateway healthy"
  GW_OK=1
else
  echo "[FAIL] gateway not healthy"
  GW_OK=0
fi

# 4. The ACP session. NOTE: the session is LONG-LIVED and reused; pressing PTT
#    does NOT create a new job. Judge by activity age on the running job.
ACTIVE=0
LAST_ACT=-1
LATEST=$(ls -t "$RABBIT_DIR/jobs" 2>/dev/null | grep '^openclaw-session' | head -1)
if [ -n "${LATEST:-}" ]; then
  JDIR="$RABBIT_DIR/jobs/$LATEST"
  if [ ! -s "$JDIR/exit" ]; then
    ACTIVE=1
    MT=$(stat -c %Y "$JDIR/stdout" 2>/dev/null || echo 0)
    LAST_ACT=$((NOW_S - MT))
    echo "[INFO] live ACP session: $LATEST"
    echo "       last traffic ${LAST_ACT}s ago"
  else
    echo "[INFO] no live session; newest job exited: $(cat "$JDIR/exit" 2>/dev/null)"
  fi
else
  echo "[WARN] no openclaw-session jobs found in $RABBIT_DIR/jobs"
fi

echo ""
if [ "$AGENT_OK" = 0 ] || [ "$CLI_OK" = 0 ] || [ "$GW_OK" = 0 ]; then
  echo "VERDICT: SERVER-SIDE PROBLEM — see the [FAIL] lines above."
elif [ "$ACTIVE" = 1 ] && [ "$LAST_ACT" -lt "$IDLE_OK_SECONDS" ]; then
  echo "VERDICT: CHAIN HEALTHY — session live, traffic ${LAST_ACT}s ago."
  echo "         If the R1 still spins, the response is failing between the"
  echo "         cloud and the device: reboot the R1."
elif [ "$ACTIVE" = 1 ]; then
  echo "VERDICT: RABBIT-SIDE — session open but idle for ${LAST_ACT}s."
  echo "         If PTT was pressed just before running this, the cloud is not"
  echo "         forwarding prompts into the session."
  echo "         1) Reboot the R1.  2) Settings > Device > OpenClaw > Reset OpenClaw, re-pair."
  echo "         3) If it persists: suspect a Rabbit cloud outage."
else
  echo "VERDICT: RABBIT-SIDE — no live session."
  echo "         1) Reboot the R1.  2) Reset OpenClaw on the device and re-pair."
fi
