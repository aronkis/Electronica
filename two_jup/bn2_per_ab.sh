#!/bin/bash
# =============================================================================
# bn2_per_ab.sh [pairs] -- INTERLEAVED delivered-PER A/B: timing-loop Bn x2 vs
# compiled default, on the mechanism established 2026-08-07.
#
# WHY THIS IS NOW A REAL EXPERIMENT (the earlier Bn x2 sweeps were not):
#   146 RX steps 1244 -> ~500 f/s within 5-20 s of every arm and then holds
#   (0 counter resets; 148 RX is full rate in 30/30 probes, so the defect is
#   confined to 148 TX -> 146 RX). 0x184 strobe_forensic, the Symbol
#   Synchronizer's max inter-strobe gap, latches 5 -> 6 exactly at the step, so
#   the TIMING loop is implicated -- which is what Bn x2 widens.
#   Measured with Bn x2 live: the rate never collapses. It holds 700-880 f/s for
#   90 s instead of 1237 for 10 s then 500. Lower peak, much higher sustained.
# The open question this answers: does that convert into DELIVERED PER?
#
# Bn x2 = stored integers 0x1F8=-327012, 0x1FC=-8720 (two's complement hex).
# Applied via capture_r3.sh's existing LOOP_POKE hook, which fires AFTER the
# wedge-check re-arms (0x000 reverts the regfile) and BEFORE the capture window.
#
# INTERLEAVED per run, not per block: channel conditions drift over an hour and
# the earlier control set was taken ~1 h before any Bn x2 data.
# NOTE the arm gate (>=1120 f/s) would REJECT a Bn x2 arm, since Bn x2 caps the
# peak at ~880 -- which is why the poke goes in after bring-up, not before.
# =============================================================================
set -u
D=$(cd "$(dirname "$0")" && pwd)
PAIRS=${1:-3}
STAMP=$(date +%Y%m%d_%H%M%S)
BN2="0x1F8=0xfffb029c 0x1FC=0xffffddf0"

for i in $(seq 1 "$PAIRS"); do
  for arm in control bn2; do
    OUT=$D/r3cap/bn2ab_${STAMP}_${arm}_r$i
    echo "=== pair $i/$PAIRS  arm=$arm -> $OUT ==="
    if [ "$arm" = bn2 ]; then export LOOP_POKE="$BN2"; else unset LOOP_POKE; fi
    LO_B_RX=1900020000 RXQ=1 GATE_TRIES=12 "$D/capture_r3.sh" B -n 8000000 -o "$OUT" \
      > "$OUT.log" 2>&1 || { echo "  CAPTURE FAILED (see $OUT.log)"; continue; }
    # sustained frame rate actually achieved during the window, from the capture's
    # own CAP_START/CAP_END register snapshots
    python3 - "$OUT/regs_cap.txt" <<'PY' || true
import sys,re
t=open(sys.argv[1]).read()
m=re.findall(r'CAP_(START|END)\s+t=([\d.]+) pkts=(0x[0-9A-Fa-f]+)',t)
if len(m)>=2:
    (_,t0,p0),(_,t1,p1)=m[0],m[1]
    dt=float(t1)-float(t0); dp=int(p1,16)-int(p0,16)
    if dt>0 and dp>=0: print(f"  window rate: {dp/dt:.0f} f/s over {dt:.2f} s")
PY
  done
done
unset LOOP_POKE

echo
echo "=== DELIVERED PER, interleaved ==="
for arm in control bn2; do
  echo "--- $arm ---"
  python3 "$D/accept_analyze.py" --arq $D/r3cap/bn2ab_${STAMP}_${arm}_r*/frames.bin 2>&1 | tail -12
done
