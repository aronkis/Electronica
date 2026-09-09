#!/bin/bash
# txfix_gate_launch.sh -- launch the TXFIX sim gate matrix runs from txfix_gate_runs.txt
# as systemd-run --user units, capped at MAXCONC concurrent, each registered in
# two_jup/agents/lanes.json with a watch_unit.sh --spawn watcher. Host-only, no board.
set -u
cd "$(dirname "$0")"
RTLDIR="$(pwd)"
TWOJUP="$RTLDIR/../../two_jup"
LEDGER="$TWOJUP/sdd_archive/2026-09-03-txfix/progress.md"
LANES="$TWOJUP/agents/lanes.json"
MAXCONC=10
TS=$(date +%s)

active_count() {
  systemctl --user list-units 'txfix-gate-*' --no-legend 2>/dev/null | grep -c running
}

append_lane() {
  local name="$1" unit="$2" log="$3"
  python3 - "$LANES" "$name" "$unit" "$log" <<'PYEOF'
import json, sys
path, name, unit, log = sys.argv[1:5]
try:
    with open(path) as f:
        data = json.load(f)
except Exception:
    data = []
data = [d for d in data if d.get('name') != name]
data.append({"name": name, "unit": unit, "log": log, "max_age_min": 20})
with open(path, 'w') as f:
    json.dump(data, f, indent=2)
PYEOF
}

launch_one() {
  local id="$1" variant="$2" bin="$3" nf="$4" k="$5" sel="$6" pfx="$7" kk="$8" selarg="$9"
  local unit="txfix-gate-${id,,}-${variant,,}-${TS}-$$-${RANDOM}"
  local logname="txfix_gate_${id}_$(basename "$pfx").log"
  local log="$RTLDIR/beat_runs/$logname"
  : > "$log"
  systemd-run --user --collect --unit="$unit" \
    --working-directory="$RTLDIR" \
    -p StandardOutput=append:"$log" -p StandardError=append:"$log" \
    /bin/bash -c "echo TXFIX_GATE_LAUNCH id=$id variant=$variant bin=$bin args='$nf $k $sel $pfx $kk $selarg'; ./$bin $nf $k $sel $pfx $kk $selarg; echo TXFIX_GATE_RUN_EXIT=\$?"
  echo "LAUNCHED $unit -> $log"
  # Lane liveness must track the harness's growing .bin output, not $log: the harness
  # only prints to stdout/$log at exit (SUMMARY/READBACK lines), so a stall detector
  # polling $log's mtime false-positives on every run still in flight (coordinator
  # 2026-09-03 addendum, task5). $pfx.bin is written incrementally via fwrite() every
  # ddrcap_valid tick for every sel we use (none of our sels are the census/no-bin case).
  local binlog="$RTLDIR/${pfx}.bin"
  append_lane "$unit" "$unit" "$binlog"
  bash "$TWOJUP/agents/watch_unit.sh" --spawn "$unit" "$LEDGER"
}

n=0
while IFS='|' read -r id variant bin nf k sel pfx kk selarg; do
  [[ "$id" == \#* || -z "$id" ]] && continue
  while [ "$(active_count)" -ge "$MAXCONC" ]; do
    sleep 5
  done
  launch_one "$id" "$variant" "$bin" "$nf" "$k" "$sel" "$pfx" "$kk" "$selarg"
  n=$((n+1))
  sleep 1
done < txfix_gate_runs.txt

echo "TXFIX_GATE_LAUNCH_DONE n=$n"
