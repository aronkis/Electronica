#!/bin/bash
# txfix_phase_witness.sh -- fresh mode-1 arm of 148, then two 512 MB sel6 captures timed at the beat's
# arm-locked burst phase (baseline 2026-09-03: first burst 79 s after ARM_OK, then every 120.2 s).
# Captures start at ARM_OK+OFF1 and ARM_OK+OFF2 (4.4 s windows). 148 only. No retry. [silicon]
set -u
D=$(cd "$(dirname "$0")" && pwd); OFF1=${OFF1:-76}; OFF2=${OFF2:-196}; VAR=${VAR:-F3}
OUT=${OUT:-$D/txfixwit/$(date +%Y%m%d_%H%M%S)_${VAR}_phase}; mkdir -p "$OUT"
log(){ echo "$(date +%T) $*" | tee -a "$OUT/run.log"; }
log "=== phase witness $VAR OFF1=$OFF1 OFF2=$OFF2"
bash "$D/baseline_arm148.sh"; A=$(ls -t "$D"/baseline_arm148_*.log | head -1)
grep -q '^ARM_OK' "$A" || { log "PHASE_ABORT arm failed ($A)"; exit 4; }
T0=$(date +%s.%N); log "ARM_OK at $(date -Is) (arm log $A)"
for i in 1 2; do
  off=$([ $i = 1 ] && echo $OFF1 || echo $OFF2)
  while awk -v t0="$T0" -v o="$off" 'BEGIN{exit !( systime() < t0+o )}'; do sleep 1; done
  log "capture $i at ARM_OK+${off}s"; OUT="$OUT" bash "$D/ddrcap2_capture.sh" 6 "${VAR}p$i" 2>&1 | tee -a "$OUT/run.log" | tail -n 2
done
for i in 1 2; do
  B="$OUT/${VAR}p$i.bin"; [ -s "$B" ] || { log "PHASE_WITNESS ${VAR}p$i MISSING"; continue; }
  python3 "$D/sel6_stall_geometry.py" "$B" "$OUT/${VAR}p${i}_stalls.json" > /dev/null 2>&1
  python3 - "$B" <<'PY' | tee -a "$OUT/run.log"
import sys, collections, json, numpy as np
sys.path.insert(0, sys.argv[1].rsplit('/two_jup/',1)[0] + '/two_jup')
from ddrcap2_decode import load, decode
from ddrcap2_beat_analysis import per_frame_offsets, load_map
a=load(sys.argv[1]); d=decode(a); fr=per_frame_offsets(a,d,load_map()); offs=[o for _,o in fr]
c=collections.Counter(offs); tr=sum(1 for i in range(1,len(offs)) if offs[i]!=offs[i-1])
sym=((a[:,0]<0).astype(np.int8)*2+(a[:,1]<0).astype(np.int8)); ch=np.flatnonzero(np.diff(sym)!=0); runs=np.diff(np.concatenate(([0],ch+1,[len(sym)])))
print(f"PHASE_WITNESS {sys.argv[1].split('/')[-1]} frames={len(fr)} census={c.most_common(3)} transitions={tr} max_run={int(runs.max())} stall_runs={int((runs>50).sum())}")
PY
done
log "=== done"
