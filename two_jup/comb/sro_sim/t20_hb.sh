#!/bin/bash
# [sim] Task 20 heartbeat: append one HEARTBEAT task20 line every 4 min to the ledger.
# State text comes from t20_state.txt so the agent can update it without touching the unit.
P=/mnt/onetb/scratch/qpsk-jupiter-modem/two_jup/sdd_archive/2026-09-04-rxfix/progress.md
S=/mnt/onetb/scratch/qpsk-jupiter-modem/two_jup/comb/sro_sim/t20_state.txt
while true; do
  st=$(cat "$S" 2>/dev/null || echo "state file missing")
  u=$(systemctl --user list-units --all 't20_*' --no-legend 2>/dev/null | awk '{printf "%s ",$1}')
  [ -z "$u" ] && u="none"
  echo "HEARTBEAT task20 $(date -Is) $st | units: $u" >> "$P"
  sleep 240
done
