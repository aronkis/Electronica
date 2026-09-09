#!/bin/bash
# agent_digest.sh -- one line per active agent in the newest campaign ledger,
# for the controller's 5-minute Monitor (T0d, plan happy-bubbling-owl.md).
# Format: task<N> hb_age=<min> unit=<running unit or -> last=<state text <=80 chars> flag=<ON-TASK|STALE>
#
# Thin wrapper around agent_watch.py --digest (the shared parser: same ledger/
# heartbeat/unit logic used by render_pipeline.py's Agents block and the tests).
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STALE_MIN="${STALL_STALE_MIN:-5}"
exec python3 "$HERE/agent_watch.py" --root "${1:-$HERE/../..}" --stale-min "$STALE_MIN" --digest
