#!/bin/bash
# =============================================================================
# bigiq_hunt.sh [attempts] -- collect STEADY-STATE errored frames WITH paired IQ.
#
# THE PROBLEM THIS SOLVES. Every historical paired capture grabbed its IQ at
# t=8.0-8.1 s, which sits inside a post-arm transient holding ~84% of all errors
# in the run. The acceptance PER window starts at t>=15 s, so the IQ we held was
# from the exact region the PER metric discards -- 3569 archived "errored frames
# with IQ", none of them steady-state. Verified by moving the grab: at
# CAP_SETTLE=20 the same window is 0/162 errored while the transient stays put at
# 5-15 s, so the readdev does not cause it.
#
# TWO CONSTRAINTS PULL AGAINST EACH OTHER:
#   - steady-state loss is ~1.1%, so a 130 ms / 162-frame grab expects <2 errors
#     and routinely draws zero
#   - /dev/shm has ~946 MB, so 80 M samples (320 MB, 1.3 s, ~1620 frames,
#     ~18 expected errors) is the largest safe grab
#
# AND RUNS FAIL. bigiq01 came back 88% bad overall -- the link went to 100% bad at
# t=5 s and never recovered, BEFORE the readdev, so it was a bad draw, not readdev
# damage. Analysing such a run tells you nothing about steady-state loss. Hence the
# health gate: keep a capture only if its steady-state window looks like the link we
# are trying to explain.
# =============================================================================
set -u
D=$(cd "$(dirname "$0")" && pwd)
N=${1:-4}
MAXBAD=${MAXBAD:-5.0}          # reject a run whose t>15 s bad-rate exceeds this
KEPT=0
for i in $(seq 1 "$N"); do
  OUT=$D/r3cap/bigiq_$(date +%H%M%S)_a$i
  echo "=== attempt $i/$N -> $(basename "$OUT") ==="
  LO_B_RX=1900020000 RXQ=1 GATE_TRIES=12 CAP_SETTLE=20 \
    "$D/capture_r3.sh" B -n 80000000 -o "$OUT" > "$OUT.log" 2>&1 || { echo "  capture failed"; continue; }
  [ -f "$OUT/frames.bin" ] || { echo "  no frames.bin"; continue; }
  V=$(python3 - "$OUT" <<'PY'
import sys, os, re, numpy as np
sys.path.insert(0,'/mnt/onetb/scratch/qpsk-jupiter-modem/two_jup')
from frame_taxonomy import read_frames
d=sys.argv[1]
fr=read_frames(os.path.join(d,'frames.bin'))
bad=(fr['crc_ok']==0)
t=fr['t_mono_ns'].astype(np.float64)/1e9; t-=t[0]
ss=(t>=15)
rate=100*bad[ss].mean() if ss.sum() else 100.0
# errored frames whose pkts lands inside the IQ window
try:
    m=re.search(r'CAP_START.*?pkts=(0x[0-9A-Fa-f]+)',open(os.path.join(d,'regs_cap.txt')).read())
    p0=int(m.group(1),16); p1=p0+80000000//49332
    pk=fr['reg_packets'].astype('int64')
    inw=(pk>=p0)&(pk<p1)&ss
    nerr=int((inw&bad).sum()); nin=int(inw.sum())
except Exception:
    nerr=nin=-1
print(f"{rate:.2f} {nerr} {nin}")
PY
)
  RATE=$(echo "$V" | awk '{print $1}'); NERR=$(echo "$V" | awk '{print $2}'); NIN=$(echo "$V" | awk '{print $3}')
  echo "  steady-state bad = ${RATE}%   errored-in-IQ = ${NERR}/${NIN}"
  if awk "BEGIN{exit !($RATE < $MAXBAD)}"; then
    echo "  KEEP (healthy run)"; KEPT=$((KEPT+1))
  else
    echo "  REJECT (steady-state ${RATE}% > ${MAXBAD}% -- broken run, not steady-state loss)"
    rm -f "$OUT/pair.iq"      # 320 MB; keep frames.bin for the record
  fi
done
echo "=== kept $KEPT healthy big-IQ captures ==="
