#!/bin/bash
# sweep_serctr_offset.sh -- STRETCH (bit-exact) sweep for MODEL-1.
# The Serializer phase counter is 1 bit, so the ONLY degree of freedom in the
# corruption is the frame-relative bit position at which the swap begins. Sweep
# the --flip-serctr injection clock across one full frame period (~98664 clk),
# collect the set of post-injection settled cap_in values, and compare against
# the hardware species-A set {7871AA08,70DF4D74,F6A4BC60,63F21D7D}.
set -u
R=$(cd "$(dirname "$0")" && pwd)
BIN=$R/obj_byte_ce/Vwrap_byte_ce           # flat-rw (unpatched) build
OUT=$R/../../two_jup/model1_ce/sweep
mkdir -p "$OUT"
FRAME=98664
BASE=500000
NCLK=820000
N=${N:-12}
PAR=${PAR:-4}                              # concurrency cap (avoid CPU thrash)
for i in $(seq 0 $((N-1))); do
  OFF=$(( BASE + i*FRAME/N ))
  echo "$OFF"
done | xargs -P "$PAR" -I{} bash -c '"$0" '"$NCLK"' "'"$OUT"'/off_{}" --flip-serctr {} > "'"$OUT"'/off_{}.log" 2>&1' "$BIN"
echo "SWEEP_DONE"
# collect post-injection settled cap_in (frames with clk > injection offset)
echo "== per-offset post-injection cap_in set =="
for f in "$OUT"/off_*_frames.csv; do
  off=$(basename "$f" _frames.csv | sed 's/off_//')
  # frames after injection: clk column ($2) > off; report distinct cap_in ($4)
  awk -F, -v o="$off" 'NR>1 && $2>o {print $4}' "$f" | sort -u | tr '\n' ' ' | sed "s/^/off=$off cap_in: /"
  echo
done | tee "$OUT/summary.txt"
