#!/usr/bin/env bash
# r1-triage — diagnose why a Rabbit R1 is stuck talking to an OpenClaw gateway.
#
# Read-only: makes no changes, restarts nothing, sends nothing.
# Exit code is always 0 — read the VERDICT line.
#
# Usage:  bash triage.sh            (press PTT on the R1 first, then run)
#         RABBIT_DIR=... OPENCLAW_BIN=... bash triage.sh   (override defaults)
#         PROBE=0 bash triage.sh    (skip the live ACP probe; it costs one short model turn)
#         LIVE_MAX_AGE=21600        (seconds; an open job older than this is a leftover, not a session)
#
# Tested against: OpenClaw 2026.9.4, rabbit-agent 0.1.17, rabbitOS 2.3
# License: MIT
set -u
VERSION="2.1.0"
RABBIT_DIR="${RABBIT_DIR:-$HOME/.rabbit-agent}"
# The agent resolves `openclaw` through a minimal PATH; /usr/local/bin is what it sees first.
OPENCLAW_BIN="${OPENCLAW_BIN:-$( [ -x /usr/local/bin/openclaw ] && echo /usr/local/bin/openclaw || command -v openclaw || echo /usr/local/bin/openclaw)}"
IDLE_OK_SECONDS="${IDLE_OK_SECONDS:-120}"
PROBE="${PROBE:-1}"
PROBE_TIMEOUT="${PROBE_TIMEOUT:-60}"
NOW_S=$(date +%s)
FAILS=0; WARNS=0
fail() { echo "[FAIL] $*"; FAILS=$((FAILS+1)); }
warn() { echo "[WARN] $*"; WARNS=$((WARNS+1)); }
ok()   { echo "[OK]   $*"; }
info() { echo "[INFO] $*"; }

echo "== R1 TRIAGE v$VERSION $(date -u +%H:%M:%SZ) =="

# ---------------------------------------------------------------------------
# 1. rabbit-agent process, supervision and cloud link
# ---------------------------------------------------------------------------
if pgrep -f "rabbit-agent run" >/dev/null 2>&1; then
  N=$(pgrep -fc "rabbit-agent run")
  VER=$(pgrep -af "rabbit-agent run" | grep -oE 'versions/[^/ ]+' | head -1)
  [ -z "$VER" ] && VER=$(python3 -c "import json;print('v'+json.load(open('$RABBIT_DIR/current.json'))['version'])" 2>/dev/null)
  ok "rabbit-agent running ${VER:-}"
  [ "$N" -gt 1 ] && warn "$N rabbit-agent processes — a nohup copy and a systemd copy fighting? (pkill -f 'rabbit-agent run'; systemctl --user restart rabbit-agent)"
  AGENT_OK=1
else
  fail "rabbit-agent NOT running"
  AGENT_OK=0
fi

# 1b. Is it supervised? The installer starts it with nohup and relies on an @reboot crontab
#     line that is not always written — an unsupervised agent dies at the next reboot.
if systemctl --user is-enabled rabbit-agent.service >/dev/null 2>&1; then
  UNIT_STATE=$(systemctl --user is-active rabbit-agent.service 2>/dev/null)
  case "$UNIT_STATE" in
    active)
      ok "rabbit-agent is a systemd user unit (active)" ;;
    activating)
      # Restart loop. pgrep in check 1 can catch a process mid-restart and
      # report success, so correct that verdict here rather than trusting it.
      fail "rabbit-agent unit is '$UNIT_STATE' - crash-looping, not starting (NRestarts=$(systemctl --user show rabbit-agent -p NRestarts --value 2>/dev/null))"
      AGENT_OK=0 ;;
    *)
      warn "rabbit-agent unit is '${UNIT_STATE:-unknown}'" ;;
  esac
elif crontab -l 2>/dev/null | grep -q "rabbit-agent"; then
  info "rabbit-agent restarted by crontab @reboot (works, but a systemd unit with Restart=always survives self-updates too)"
else
  warn "rabbit-agent is NOT supervised (no systemd unit, no @reboot crontab): it will not come back after a reboot."
  echo "       Fix: install the user unit from this repo's contrib/rabbit-agent.service"
fi

# 1c. Cloud control link, as the agent itself reports it.
ST="$RABBIT_DIR/runtime/rabbit-agent.status.json"
if [ -r "$ST" ]; then
  STATUS=$(python3 -c "import json;d=json.load(open('$ST'));print(d.get('status','?'), d.get('version','?'), d.get('updatedAt','?'))" 2>/dev/null)
  case "$STATUS" in
    connected*) ok "control WS to Rabbit cloud: $STATUS" ;;
    *)          if [ "$AGENT_OK" = 1 ]; then warn "control WS status: ${STATUS:-unreadable} (agent running but not registered - re-register from rabbithole > settings > nodes)"; else info "control WS status: ${STATUS:-unreadable} (agent is not running - see check 1)"; fi ;;
  esac
fi

# 1d. When the agent is down, the reason is usually in its own log - but a
#     crash-looping agent never writes a status file, so check 1c sees nothing.
#     The commonest cause after a self-update is a lost pairing: the agent
#     starts, finds no connection info, exits 0, and systemd restarts it
#     forever. A process that fails by succeeding looks fine from the outside.
if [ "$AGENT_OK" = 0 ] && [ -r "$RABBIT_DIR/logs/agent.log" ]; then
  LASTERR=$(tail -200 "$RABBIT_DIR/logs/agent.log" 2>/dev/null | python3 -c "
import sys, json
last = ''
for line in sys.stdin:
    try: d = json.loads(line)
    except Exception: continue
    if d.get('level') == 'error': last = str(d.get('message', ''))
print(last)" 2>/dev/null)
  if [ -n "$LASTERR" ]; then
    echo "       last error in agent.log: $(echo "$LASTERR" | head -c 160)"
    case "$LASTERR" in
      *"No connection info"*)
        fail "agent has LOST ITS PAIRING - a self-update can wipe it"
        echo "       Fix: take a token from rabbithole > settings > nodes, then:"
        echo "            $RABBIT_DIR/bin/rabbit-agent register --token=XXXX"
        echo "            systemctl --user restart rabbit-agent"
        echo "       Note: re-registering issues a NEW nodeId - delete the stale node." ;;
    esac
  fi
fi

# ---------------------------------------------------------------------------
# 2. openclaw CLI as the agent invokes it
# ---------------------------------------------------------------------------
if "$OPENCLAW_BIN" --version >/dev/null 2>&1; then
  ok "openclaw CLI resolvable at $OPENCLAW_BIN ($("$OPENCLAW_BIN" --version 2>/dev/null | head -c 40))"
  CLI_OK=1
else
  fail "openclaw CLI not resolvable at $OPENCLAW_BIN"
  echo "       Fix: put it on the default PATH, e.g. sudo ln -s \"\$(command -v openclaw)\" /usr/local/bin/openclaw"
  CLI_OK=0
fi

# ---------------------------------------------------------------------------
# 3. Gateway health
# ---------------------------------------------------------------------------
if "$OPENCLAW_BIN" gateway health 2>/dev/null | grep -qi "OK"; then
  ok "gateway healthy"
  GW_OK=1
else
  fail "gateway not healthy"
  GW_OK=0
fi
GW_START_S=$(systemctl --user show openclaw-gateway -p ExecMainStartTimestamp --value 2>/dev/null | xargs -I{} date -d "{}" +%s 2>/dev/null || echo 0)

# ---------------------------------------------------------------------------
# 4. Multi-agent ownership. Since OpenClaw 2026.8.x the gateway refuses prompts on the
#    bridge's default, unscoped session key ("acp-bridge:<uuid>") when more than one agent
#    is configured: "session key has no explicit owner". The R1 then shows "listening…"
#    and nothing else, while every other check passes.
# ---------------------------------------------------------------------------
AGENTS=$("$OPENCLAW_BIN" agents list --json 2>/dev/null | python3 -c "import sys,json;d=json.load(sys.stdin);print(len(d) if isinstance(d,list) else len(d.get('agents',[])))" 2>/dev/null)
[ -z "$AGENTS" ] && AGENTS=$("$OPENCLAW_BIN" agents list 2>/dev/null | grep -cE '^- [a-z0-9_-]+' || echo 0)
if [ "${AGENTS:-0}" -gt 1 ]; then
  if grep -qsE -- '--session +"?agent:' "$OPENCLAW_BIN" 2>/dev/null; then
    ok "$AGENTS agents configured; $OPENCLAW_BIN scopes ACP sessions to an agent ($(grep -oE -- '--session +"?agent:[^" ]+' "$OPENCLAW_BIN" | head -1))"
  else
    warn "$AGENTS agents configured but $OPENCLAW_BIN does not add --session agent:<id>:<key> to 'acp'."
    echo "       The gateway will refuse R1 prompts with 'session key has no explicit owner'."
    echo "       Fix: contrib/openclaw-wrapper.sh → /usr/local/bin/openclaw (regular file, not a symlink)."
  fi
fi

# ---------------------------------------------------------------------------
# 5. Live ACP probe: initialize → session/new → session/prompt through the same
#    binary the agent uses. Proves the bridge+gateway+model path, independent of Rabbit.
#    Costs one short model turn; PROBE=0 to skip.
# ---------------------------------------------------------------------------
PROBE_OK=-1
if [ "$PROBE" = "1" ] && [ "$CLI_OK" = 1 ] && [ "$GW_OK" = 1 ] && command -v python3 >/dev/null 2>&1; then
  PROBE_OUT=$(OPENCLAW_BIN="$OPENCLAW_BIN" PROBE_TIMEOUT="$PROBE_TIMEOUT" python3 - <<'PYEOF' 2>&1
import json, os, subprocess, sys, time, threading, queue
p = subprocess.Popen([os.environ["OPENCLAW_BIN"], "acp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1)
q = queue.Queue()
threading.Thread(target=lambda: [q.put(l) for l in p.stdout] and q.put(None), daemon=True).start()
def send(o): p.stdin.write(json.dumps(o)+"\n"); p.stdin.flush()
def wait(i, secs):
    end=time.time()+secs
    while time.time()<end:
        try: l=q.get(timeout=0.5)
        except queue.Empty: continue
        if l is None: return None
        try: m=json.loads(l)
        except Exception: continue
        if m.get("id")==i: return m
    return None
T=int(os.environ.get("PROBE_TIMEOUT","60")); t0=time.time(); rc=2; msg="no initialize result"
try:
    send({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{}}})
    if wait(1,15):
        send({"jsonrpc":"2.0","id":2,"method":"session/new","params":{"cwd":os.path.expanduser("~"),"mcpServers":[]}})
        m=wait(2,15); msg="no session/new result"
        if m and "result" in m:
            sid=m["result"]["sessionId"]
            send({"jsonrpc":"2.0","id":3,"method":"session/prompt","params":{"sessionId":sid,"prompt":[{"type":"text","text":"Reply with the single word: pong"}]}})
            m=wait(3,T)
            if m and "result" in m: rc=0; msg=f"prompt answered in {time.time()-t0:.1f}s (stopReason={m['result'].get('stopReason')})"
            elif m and "error" in m:
                d=str(m["error"].get("data",{}).get("details") or m["error"].get("message"))
                rc=3 if "explicit owner" in d else 1; msg="prompt error: "+d[:160]
            else: msg=f"prompt timeout after {T}s"
finally:
    try: p.stdin.close(); p.terminate()
    except Exception: pass
print(msg); sys.exit(rc)
PYEOF
)
  PROBE_RC=$?
  case "$PROBE_RC" in
    0) ok "ACP probe: $PROBE_OUT"; PROBE_OK=1 ;;
    3) fail "ACP probe: $PROBE_OUT"; echo "       → multi-agent ownership: see check 4 (wrapper with --session agent:<id>:<key>)"; PROBE_OK=0 ;;
    *) fail "ACP probe: $PROBE_OUT"; PROBE_OK=0 ;;
  esac
elif [ "$PROBE" != "1" ]; then
  info "ACP probe skipped (PROBE=0)"
fi

# ---------------------------------------------------------------------------
# 6. The ACP session. The session is LONG-LIVED and reused; pressing PTT does NOT create
#    a new job. Judge by activity age on the running job. rabbit-agent ≥0.1.10 deletes
#    finished jobs on detach, so "newest directory" can be weeks old — only a job without
#    an exit file is evidence; otherwise read the agent log.
# ---------------------------------------------------------------------------
ACTIVE=0; LAST_ACT=-1; ORPHAN=0
LIVE=""; STALE=0
LIVE_MAX_AGE="${LIVE_MAX_AGE:-21600}"   # seconds; older "open" jobs are pre-0.1.10 leftovers, not sessions
for d in $(ls -t "$RABBIT_DIR/jobs" 2>/dev/null | grep '^openclaw-session'); do
  J="$RABBIT_DIR/jobs/$d"
  [ -s "$J/exit" ] && continue
  AGE=$(( NOW_S - $(stat -c %Y "$J/stdout" 2>/dev/null || echo 0) ))
  if [ "$AGE" -le "$LIVE_MAX_AGE" ]; then LIVE="$d"; break; else STALE=$((STALE+1)); fi
done
[ "$STALE" -gt 0 ] && info "$STALE stale job dir(s) without an exit file (older than $((LIVE_MAX_AGE/3600))h) ignored; safe to delete"
if [ -n "$LIVE" ]; then
  JDIR="$RABBIT_DIR/jobs/$LIVE"; ACTIVE=1
  MT=$(stat -c %Y "$JDIR/stdout" 2>/dev/null || echo 0)
  CT=$(stat -c %Y "$JDIR" 2>/dev/null || echo 0)
  LAST_ACT=$((NOW_S - MT))
  PROMPTS=$(grep -c '"agent_message_chunk"' "$JDIR/stdout" 2>/dev/null || echo 0)
  info "live ACP session: $LIVE"
  echo "       last traffic ${LAST_ACT}s ago; replies streamed so far: ${PROMPTS}"
  if [ "${GW_START_S:-0}" -gt 0 ] && [ "$GW_START_S" -gt "$CT" ]; then
    ORPHAN=1
    warn "gateway restarted AFTER this session was created → the cloud is talking into an orphaned session."
  fi
else
  LASTJOB=$(grep -E "BackgroundJob 'openclaw-session" "$RABBIT_DIR/logs/agent.log" 2>/dev/null | tail -1 \
            | python3 -c "import sys,json;d=json.loads(sys.stdin.read());print(d['timestamp'][:19], str(d.get('message') or d.get('msg'))[-60:])" 2>/dev/null)
  info "no live session; last openclaw job event: ${LASTJOB:-none in agent.log}"
fi

# ---------------------------------------------------------------------------
# VERDICT
# ---------------------------------------------------------------------------
echo ""
if [ "$AGENT_OK" = 0 ] || [ "$CLI_OK" = 0 ] || [ "$GW_OK" = 0 ] || [ "$PROBE_OK" = 0 ]; then
  echo "VERDICT: SERVER-SIDE PROBLEM — see the [FAIL] lines above."
elif [ "$ORPHAN" = 1 ]; then
  echo "VERDICT: ORPHANED SESSION — the gateway restarted under a live R1 session."
  echo "         Reboot the R1 (or start a new session from the notebook icon)."
elif [ "$ACTIVE" = 1 ] && [ "$LAST_ACT" -lt "$IDLE_OK_SECONDS" ]; then
  echo "VERDICT: CHAIN HEALTHY — session live, traffic ${LAST_ACT}s ago."
  echo "         If the R1 still spins, the response is failing between the"
  echo "         cloud and the device: reboot the R1."
elif [ "$ACTIVE" = 1 ]; then
  echo "VERDICT: RABBIT-SIDE — session open but idle for ${LAST_ACT}s."
  echo "         If PTT was pressed just before running this, the cloud is not"
  echo "         forwarding prompts into the session."
  echo "         1) Reboot the R1.  2) rabbithole > settings > nodes: remove + register node again."
  echo "         3) If it persists: suspect a Rabbit cloud outage."
else
  echo "VERDICT: RABBIT-SIDE — no live session (server checks pass${PROBE_OK:+, ACP probe OK})."
  echo "         1) On the R1: swipe to the OpenClaw page, tap 'click to refresh', then PTT."
  echo "         2) Reboot the R1.  3) rabbithole > settings > nodes: remove + register node again."
fi
[ "$WARNS" -gt 0 ] && echo "         ($WARNS warning(s) above are worth fixing even if the verdict is not server-side.)"
exit 0
