#!/bin/bash
# beatfix_accept.sh -- LIVE-LINK PER acceptance A/B for the BEATFIX phase
# contract (BEATFIX_DESIGN.md item 4). Alternating forward acceptance runs
# (146 TX -> 148 RX, ARQ off, capture_r3.sh SIDE=A) with fixctl toggled at
# runtime: runs 1,3 = fixctl=0 (legacy), runs 2,4 = fixctl=3 (contract +
# serializer anchor). Because bring-up AND mid-run re-arms soft-reset the DUT
# (clearing fixctl), the fix arm re-asserts 0x208 every 5 s from traffic start
# to capture end (idempotent DRA write; every write logged).
# Analysis: accept_analyze on each run's frames.bin (host_seq gaps, steady
# window, dropped frames in denominator) -- paired per-run reporting.
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
A_IP=10.0.0.148
STAMP=$(date +%Y%m%d_%H%M%S)
ARMS=(0 3 0 3)
for i in 1 2 3 4; do
  V=${ARMS[$((i-1))]}
  OUT=$D/r3cap/beatfix_accept_${STAMP}_r${i}_ctl${V}
  echo "=== run $i/4 fixctl=$V -> $OUT ==="
  ( SIDE=A GATE_TRIES=12 "$D/capture_r3.sh" A -n 8000000 -o "$OUT" ) > "$OUT.log" 2>&1 &
  CPID=$!
  # fix-arm keeper: from traffic start until capture_r3 exits, re-assert every 5s
  if [ "$V" != "0" ]; then
    ( until grep -q "traffic:" "$OUT.log" 2>/dev/null; do sleep 2; kill -0 $CPID 2>/dev/null || exit 0; done
      echo "  [keeper] traffic started; asserting fixctl=$V every 5s"
      N=0
      while kill -0 $CPID 2>/dev/null; do
        $W $A_IP "DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled>/sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null; echo '0x208 0x$V'>\$DRA" >/dev/null 2>&1
        N=$((N+1)); sleep 5
      done
      echo "  [keeper] done ($N asserts)" ) >> "$OUT.log" 2>&1 &
    KPID=$!
  fi
  wait $CPID; RC=$?
  [ "${V}" != "0" ] && wait ${KPID:-0} 2>/dev/null
  echo "  run $i exit=$RC frames.bin=$( [ -f "$OUT/frames.bin" ] && stat -c%s "$OUT/frames.bin" || echo MISSING)"
  grep -cE "\[keeper\] traffic started" "$OUT.log" >/dev/null 2>&1 && grep "keeper" "$OUT.log" | tail -1
done
# reset fixctl + restore
$W $A_IP 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled>/sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null; echo "0x208 0x0">$DRA' >/dev/null 2>&1
bash "$D/restore_known_good.sh" > "$D/r3cap/beatfix_accept_${STAMP}_restore.log" 2>&1
echo "BEATFIX_ACCEPT_DONE stamp=$STAMP"
