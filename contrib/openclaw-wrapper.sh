#!/bin/bash
# /usr/local/bin/openclaw — install as a REGULAR FILE (remove any symlink first: sudo rm -f /usr/local/bin/openclaw).
# The rabbit-agent resolves `openclaw` through a minimal PATH; this is what it finds. With more than one
# OpenClaw agent configured, the gateway (2026.8.x) refuses the ACP bridge's default unscoped session key,
# so we scope R1 sessions to one agent. Calls the entry file directly — never re-enters itself by name.
# Adjust NODE/ENTRY to your install (npm -g root: `npm root -g`), and AGENT to the agent id the R1 should talk to.
NODE="${NODE:-$(command -v node)}"
ENTRY="${OPENCLAW_ENTRY:-$(npm root -g 2>/dev/null)/openclaw/openclaw.mjs}"
AGENT="${R1_AGENT:-main}"
if [ "${1:-}" = "acp" ]; then shift; exec "$NODE" "$ENTRY" acp --session "agent:${AGENT}:rabbit-r1" "$@"; fi
exec "$NODE" "$ENTRY" "$@"
