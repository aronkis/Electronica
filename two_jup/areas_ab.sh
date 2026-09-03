#!/bin/bash
# =============================================================================
# areas_ab.sh [pairs] -- interleaved A/B: 4 areas x M=16  vs  2 areas x M=32.
#
# HYPOTHESIS UNDER TEST. The loss is a re-arm/starvation problem, not ring-full
# overflow. Evidence: (a) structurally the DMA can never overwrite an undrained slot,
# because an area is resubmitted only AFTER its drain finishes; (b) failed slices read
# back as the carve_zero pattern rather than newer valid data, i.e. nothing was written,
# which is what an unarmed engine looks like -- an overwrite would have delivered a
# decodable frame with the wrong seq; (c) forcing the drain slower raised PER
# 1.324% -> 5.945%, so drain latency is causally on the critical path.
#
# With TWO areas, re-arm is structurally gated on the drain. With FOUR, a clean
# pre-drained area is always ready to submit at completion, so the drain leaves the
# critical path. Note this costs NO memory: 4 x M=16 is half the carve of 2 x M=32.
#
# ARM A is also the CONTROL for the code change itself: 2 areas at M=32 must reproduce
# the sweep's ~1.36%. If it does not, the N-area rework changed legacy behaviour and the
# comparison is void -- check that before reading the B numbers.
#
# ARQ off, interleaved, because this rig drifts more than the effect being measured.
# =============================================================================
set -u
D=$(cd "$(dirname "$0")" && pwd)
W=$D/anyssh.sh
B_IP=10.0.0.146
PAIRS=${1:-3}
STAMP=$(date +%Y%m%d_%H%M%S)
RUN=$D/r3cap/areas_$STAMP
mkdir -p "$RUN"
CSV=$RUN/results.csv
echo "cycle,tag,areas,m,ok,cmdline_m,cpu_pct,engine_gaps,completions,full_eager,backlog_sum,backlog_max,resets,outdir" > "$CSV"

one() {
  local cyc=$1 tag=$2 areas=$3 m=$4
  local OUT=$RUN/${tag}_c${cyc}
  echo "--- cycle $cyc  $tag ($areas areas x M=$m) ---"
  local ok=1
  RXM=$m RXQ=1 RXCYC=0 HOST_CFLAGS_B=-DQPSK_RXQ_STAT \
    DAEMON_ENV="QPSK_RX_AREAS=$areas" \
    LO_B_RX=1900020000 GATE_TRIES=12 \
    "$D/capture_r3.sh" B -k -n 400000 -o "$OUT" > "$OUT.log" 2>&1 || ok=0
  [ -f "$OUT/frames.bin" ] || ok=0
  # the daemon must have actually taken BOTH knobs; a silent default voids the row
  local INFO CPU R GOTM SAW
  INFO=$($W $B_IP 'p=$(pgrep -x qpsk_tun | head -1)
    if [ -n "$p" ]; then HZ=$(getconf CLK_TCK); set -- $(cat /proc/$p/stat)
      up=$(cut -d" " -f1 /proc/uptime)
      echo "CPU=$(awk -v u=${14} -v s=${15} -v b=${22} -v h=$HZ -v up=$up \
        "BEGIN{l=up-b/h; if(l<=0){print -1}else{printf \"%.1f\", 100*(u+s)/h/l}}")"
      echo "CMDM=$(tr "\0" " " < /proc/$p/cmdline | grep -oE "\-M [0-9]+" | head -1 | awk "{print \$2}")"
    else echo "CPU=-1"; echo "CMDM="; fi
    grep -oE "RX queued ring: [0-9]+ areas" /dev/shm/qpsk_tun.log | tail -1
    grep "rxqstat:" /dev/shm/qpsk_tun.log | tail -1' 2>/dev/null)
  CPU=$(echo "$INFO" | sed -n 's/^CPU=//p' | head -1)
  GOTM=$(echo "$INFO" | sed -n 's/^CMDM=//p' | head -1)
  SAW=$(echo "$INFO" | grep -oE "RX queued ring: [0-9]+ areas" | grep -oE "[0-9]+" | head -1)
  R=$(echo "$INFO" | grep -o 'rxqstat:.*')
  [ -z "${SAW:-}" ] && SAW=2      # no banner printed = default 2 areas
  if [ "${GOTM:-}" != "$m" ] || [ "$SAW" != "$areas" ]; then
    echo "    !! daemon took -M ${GOTM:-?} / ${SAW} areas, wanted -M $m / $areas -- row voided"
    ok=0
  fi
  g(){ echo "$R" | grep -oE "$1=[0-9]+" | cut -d= -f2; }
  echo "$cyc,$tag,$areas,$m,$ok,${GOTM:-NA},${CPU:-NA},$(g engine_gaps),$(g completions),$(g full_eager),$(g backlog_sum),$(g backlog_max),$(g resets),$(basename "$OUT")" >> "$CSV"
  echo "    ok=$ok areas=$SAW cpu=${CPU:-NA}%  ${R:-<no rxqstat>}"
}

echo "=== areas A/B: $PAIRS pairs -> $CSV ==="
for i in $(seq 1 "$PAIRS"); do
  one "$i" a2m32 2 32      # control: today's default AND the regression check
  one "$i" a4m16 4 16      # candidate: re-arm decoupled from drain
done

echo; echo "=== $CSV ==="; column -s, -t < "$CSV"
echo; echo "=== delivered PER ==="
for t in a2m32 a4m16; do
  echo "--- $t ---"; python3 "$D/accept_analyze.py" $RUN/${t}_c*/frames.bin 2>&1 | tail -5
done
echo; echo "=== fabric loss period ==="
for t in a2m32 a4m16; do
  python3 "$D/loss_period.py" $RUN/${t}_c*/frames.bin --periods 8,16,32,64 2>/dev/null \
    | grep -E "^===|FUNDAMENTAL|NOT periodic"
done
