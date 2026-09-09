#!/bin/bash
# txfix_gate_heartbeat_loop.sh -- bounded sleep-and-heartbeat loop (coordinator instruction
# 2026-09-03, replacing an open-ended Monitor wait which the stall detector flagged as a
# stale task-5 heartbeat). Sleeps 840s (14 min, < the 15 min ceiling) between HEARTBEAT
# lines, listing the still-running txfix-gate-* units by name, until none remain (or a
# generous overall cap is hit so this can't run forever unattended). Host-only, no board.
set -u
cd "$(dirname "$0")"
LEDGER="/mnt/onetb/scratch/qpsk-jupiter-modem/two_jup/sdd_archive/2026-09-03-txfix/progress.md"
MAXITERS=20   # 20*14min = ~4.7h ceiling, generous vs. the ~2h matrix estimate

for i in $(seq 1 "$MAXITERS"); do
  units=$(systemctl --user list-units 'txfix-gate-*' --no-legend 2>/dev/null | awk '{print $1}')
  n=$(echo -n "$units" | grep -c . || true)
  ts=$(date -Is)
  if [ "$n" -eq 0 ]; then
    printf 'HEARTBEAT task5 %s all gate units exited (loop check %d) -- ready to rescore\n' "$ts" "$i" >> "$LEDGER"
    echo "TXFIX_GATE_HEARTBEAT_LOOP_DONE all_exited iter=$i"
    exit 0
  fi
  idlist=$(echo "$units" | tr '\n' ' ')
  printf 'HEARTBEAT task5 %s waiting on %d units: %s\n' "$ts" "$n" "$idlist" >> "$LEDGER"
  echo "TXFIX_GATE_HEARTBEAT_LOOP iter=$i waiting_on=$n"
  sleep 840
done
printf 'HEARTBEAT task5 %s heartbeat loop hit MAXITERS=%d with units still running -- needs operator attention\n' "$(date -Is)" "$MAXITERS" >> "$LEDGER"
echo "TXFIX_GATE_HEARTBEAT_LOOP_MAXITERS"
