#!/bin/bash
# revbase3.sh -- Task 9 Step 4: 3x reverse re-baseline (148 TX -> 146 RX),
# >=75k live frames each (-d 68 at ~1245 f/s), wedge-aware accept_analyze.py,
# drops in denominator. Per-run delivery-health gate on 146 (reverse RX) with
# up to 2 restore attempts (standing amendment style). fixctl=3 persists on
# 148's AXI bank across bring-up; re-asserted before each run regardless.
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
TS=$(date +%Y%m%d_%H%M%S)
echo "REVBASE3 start $(date -Is)"
fix3(){ $W 10.0.0.148 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
  echo enabled > /sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null
  echo "0x208 0x3" > $DRA; echo FIXCTL3' 2>/dev/null | tail -1; }
for R in 1 2 3; do
  OUT=$D/r3cap/revbase_${TS}_r$R
  ok=""
  for TRY in 1 2 3; do
    HP=$(bash $D/health_probe_reset_aware.sh 10.0.0.146 12 2>/dev/null | tail -1)
    echo "RUN$R gate try $TRY (146 RX): $HP"
    FS=$(echo "$HP" | grep -oE 'fsync=[0-9]+' | tr -dc 0-9)
    [ "${FS:-0}" -ge 1100 ] 2>/dev/null && { ok=1; break; }
    [ $TRY -lt 3 ] && bash $D/restore_known_good.sh > /tmp/revbase_rkg_r${R}_t$TRY.log 2>&1
  done
  [ -n "$ok" ] || { echo "RUN${R}_GATE_FAIL reverse RX degraded after 2 restores -- recording and continuing"; }
  echo "RUN$R fixctl: $(fix3)"
  GATE_DIR=B $D/capture_r3.sh B -d 68 -k -o "$OUT" > "$OUT.log" 2>&1
  echo "RUN$R capture rc=$? out=$OUT"
  if [ -f "$OUT/frames.bin" ]; then
    python3 $D/accept_analyze.py "$OUT/frames.bin" > "$OUT/analysis.txt" 2>&1
    echo "RUN$R ANALYSIS:"; cat "$OUT/analysis.txt"
  else
    echo "RUN${R}_NO_FRAMES (see $OUT.log tail):"; tail -5 "$OUT.log"
  fi
done
echo "--- post: restore + verify ---"
bash $D/restore_known_good.sh > /tmp/revbase_rkg_post.log 2>&1
echo "post fixctl: $(fix3)"
echo "post 148: $(bash $D/health_probe_reset_aware.sh 10.0.0.148 12 2>/dev/null | tail -1)"
echo "post 146: $(bash $D/health_probe_reset_aware.sh 10.0.0.146 12 2>/dev/null | tail -1)"
echo "REVBASE3_DONE $(date -Is)"
