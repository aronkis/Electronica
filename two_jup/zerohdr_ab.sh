#!/bin/bash
# =============================================================================
# zerohdr_ab.sh [pairs] [M] -- interleaved A/B of the pre-submit zeroing strategy,
# plus the positive control for engine_gaps.
#
# THE HYPOTHESIS. Measurement (not theory) located the loss mechanism: good frames
# arrive in exact 0.803 ms lockstep and essentially never follow a multi-ms gap (0.00%
# at >4 ms), while 80-85% of loss EPISODES begin immediately after one. Stall rate and
# stall duration both scale with M (2/4/18% of batches and 4.0/7.2/10.4 ms median at
# M = 8/16/32), which is why loss RISES with M instead of falling as a per-boundary law
# would predict, and why episode size is bounded by exactly M.
#
# The suspect is `carve_zero` in rx_q_submit: M x pkt_bytes of UNCACHED Device-memory
# writes at every batch boundary -- 45 KB at M=32. It also explains why failed slices
# read back as zeros: that is the pattern the host was mid-way through writing.
#
# THE FIX UNDER TEST. carve_zero exists only to keep "valid CRC = fresh slice": a stale
# slice must fail to decode. qpsk_frame_decode rejects on the 0x51 0x4B magic before it
# looks at anything else, so clearing 8 bytes per slice preserves that invariant exactly
# -- ~175x fewer uncached writes. If the stall is carve_zero, this removes it at ANY M,
# which would be a real fix rather than the -M 16 mitigation.
#
# The build also reports zero_us_mean / zero_us_max directly, so the hypothesis is
# MEASURED at the source rather than inferred from the FER delta.
#
# ARQ stays off; M defaults to 32 because that is where the stall is largest and so the
# effect should be clearest.
# =============================================================================
set -u
D=$(cd "$(dirname "$0")" && pwd)
W=$D/anyssh.sh
B_IP=10.0.0.146
PAIRS=${1:-3}
M=${2:-32}
STAMP=$(date +%Y%m%d_%H%M%S)
RUN=$D/r3cap/zerohdr_$STAMP
mkdir -p "$RUN"
CSV=$RUN/results.csv
echo "cycle,tag,zerohdr,m,ok,cpu_pct,zero_n,zero_us_mean,zero_us_max,engine_gaps,backlog_sum,completions,outdir" > "$CSV"

one() {
  local cyc=$1 tag=$2 env=$3
  local OUT=$RUN/${tag}_c${cyc}
  echo "--- cycle $cyc  $tag  [$env] ---"
  local ok=1
  RXM=$M RXQ=1 RXCYC=0 HOST_CFLAGS_B=-DQPSK_RXQ_STAT DAEMON_ENV="$env" \
    LO_B_RX=1900020000 GATE_TRIES=12 \
    "$D/capture_r3.sh" B -k -n 4000000 -o "$OUT" > "$OUT.log" 2>&1 || ok=0
  [ -f "$OUT/frames.bin" ] || ok=0
  local INFO CPU X R
  INFO=$($W $B_IP 'p=$(pgrep -x qpsk_tun | head -1)
    if [ -n "$p" ]; then HZ=$(getconf CLK_TCK); set -- $(cat /proc/$p/stat)
      up=$(cut -d" " -f1 /proc/uptime)
      echo "CPU=$(awk -v u=${14} -v s=${15} -v b=${22} -v h=$HZ -v up=$up \
        "BEGIN{l=up-b/h; if(l<=0){print -1}else{printf \"%.1f\", 100*(u+s)/h/l}}")"
    else echo "CPU=-1"; fi
    grep "rxqexp:"  /dev/shm/qpsk_tun.log 2>/dev/null | tail -1
    grep "rxqstat:" /dev/shm/qpsk_tun.log 2>/dev/null | tail -1' 2>/dev/null)
  CPU=$(echo "$INFO" | sed -n 's/^CPU=//p' | head -1)
  X=$(echo "$INFO" | grep -o 'rxqexp:.*'); R=$(echo "$INFO" | grep -o 'rxqstat:.*')
  g(){ echo "$2" | grep -oE "$1=[0-9.]+" | cut -d= -f2; }
  echo "$cyc,$tag,$(g zerohdr "$X"),$M,$ok,${CPU:-NA},$(g zero_n "$X"),$(g zero_us_mean "$X"),$(g zero_us_max "$X"),$(g engine_gaps "$R"),$(g backlog_sum "$R"),$(g completions "$R"),$(basename "$OUT")" >> "$CSV"
  echo "    ok=$ok cpu=${CPU:-NA}%  ${X:-<no rxqexp>}"
}

echo "=== zerohdr A/B: $PAIRS pairs at -M $M -> $CSV ==="
for i in $(seq 1 "$PAIRS"); do
  one "$i" base "QPSK_RXQ_ZEROHDR=0"     # control = today's full-area zero
  one "$i" hdr  "QPSK_RXQ_ZEROHDR=1"     # candidate fix = 8 B/slice
done

# POSITIVE CONTROL for engine_gaps, which read 0.00000 in every config all night. If a
# drain slowed to the point where the resubmit CANNOT beat the next completion still
# reports zero gaps, the counter is broken and its zeros carry no information.
echo
echo "=== positive control: forced drain delay (engine_gaps MUST become non-zero) ==="
one 9 gapctl "QPSK_RXQ_ZEROHDR=0 QPSK_RXQ_DRAINDELAY_US=400"

echo; echo "=== $CSV ==="
column -s, -t < "$CSV"
echo
echo "=== delivered PER ==="
for t in base hdr gapctl; do
  ls -d $RUN/${t}_c* >/dev/null 2>&1 || continue
  echo "--- $t ---"; python3 "$D/accept_analyze.py" $RUN/${t}_c*/frames.bin 2>&1 | tail -4
done
echo
echo "=== fabric loss period ==="
for t in base hdr; do
  python3 "$D/loss_period.py" $RUN/${t}_c*/frames.bin --periods 8,16,32,64 2>/dev/null \
    | grep -E "^===|FUNDAMENTAL|NOT periodic"
done
