#!/bin/bash
# =============================================================================
# rx_config_sweep.sh [cycles] -- INTERLEAVED sweep over RX DMA configurations,
# measuring delivered FER, daemon CPU, and queued-path occupancy together.
#
# WHY THIS SHAPE. m_depth_ab.sh proved -M 16 halves delivered PER vs -M 32, but it
# hardcoded a two-config A/B. The open question is broader: what does the RX path cost
# at each depth, and is the loss a RACE (submit-slot contention at the batch boundary)
# or HEADROOM (host not draining fast enough)? Those need occupancy telemetry alongside
# FER, and they need MORE configs -- so the interleaving has to generalise to a rotation.
#
# INTERLEAVED, NOT BLOCKED. This rig's channel drifts by more than the effect being
# measured; every block-vs-block comparison in this campaign has been wrong at least
# once. One pass through the rotation = one cycle; all configs see the same drift.
#
# THE RING-DEPTH AXIS. In queued mode the "ring" is exactly 2 areas x M slots
# (rx_q_id[2], rx_area_phys) and the axi_dmac holds ONE request ahead -- so ring depth
# and M are the SAME knob and cannot be varied independently. The genuinely deeper ring
# is QPSK_RX_CYCLIC (one arm, 2*64 slots, no per-batch boundary), but the deployed
# bitstream is CONFIG.CYCLIC=0: cyclic arms and then delivers nothing at all
# (dma_rx_ok=0, crc_drop=0 -- probed 2026-08-09). So the axes available host-side are
# M, and the queued-vs-legacy architecture switch (RXQ=0 re-arms per transfer).
#
# OCCUPANCY. Board B builds with -DQPSK_RXQ_STAT (HOST_CFLAGS_B, board-B-only: with the
# flag off the source is byte-identical, so 148 rebuilds untouched). That emits
#   qpsk_tun rxqstat: defers=.. engine_gaps=.. completions=.. full_eager=.. backlog_sum=..
# defers      -> submit slot was busy = contention. Measured 0 everywhere, which is why
#                it is NOT the interesting number: in steady state the slot is free.
# engine_gaps -> a transfer ENDED with the next area not yet queued, so the engine had
#                nothing to start. This is the race that can actually drop frames here,
#                and defers cannot see it (the host is late, not blocked).
# backlog     -> slices undrained at completion = HEADROOM indicator
#
# CPU. Sampled as the daemon's cumulative (utime+stime) over its own lifetime. The
# daemon is started fresh by each bring-up and the traffic window dominates its life, so
# this is an average over the run and needs no before/after pairing across a restart.
# NOTE this is the PER-capture traffic pattern; goodput is measured separately by
# perf_ceiling.sh under a different pattern -- do not present them as one measurement.
#
# Results are appended to results.csv AFTER EVERY RUN, so a partial night is still data.
# =============================================================================
set -u
D=$(cd "$(dirname "$0")" && pwd)
W=$D/anyssh.sh
B_IP=10.0.0.146
CYCLES=${1:-6}
NSAMP=${NSAMP:-4000000}

# tag:RXQ:M -- rotation runs every cycle; ONCE runs in cycle 1 only.
# q64 is in ONCE deliberately: -M 64 is already known bad (~2.55%, aperiodic) and does
# not deserve a fifth of the night to reconfirm.
ROTATION=${ROTATION:-"q32:1:32 q16:1:16 q8:1:8 l32:0:32 l16:0:16"}
# ${ONCE-...} not ${ONCE:-...}: an explicitly EMPTY ONCE must mean "none", not "default"
ONCE=${ONCE-"q64:1:64"}

STAMP=$(date +%Y%m%d_%H%M%S)
RUN=$D/r3cap/sweep_$STAMP
mkdir -p "$RUN"
CSV=$RUN/results.csv
echo "cycle,tag,rxq,m,ok,cmdline_m,cpu_pct,defers,engine_gaps,completions,full_eager,backlog_sum,backlog_max,resets,outdir" > "$CSV"

echo "=== rx_config_sweep: $CYCLES cycles, rotation [$ROTATION], once [$ONCE] ==="
echo "=== results -> $CSV ==="

# daemon CPU% over its lifetime + the rxqstat line, in ONE ssh call (single-reader safe:
# reads /proc and a log file only, never touches a register)
# NOTE: captures run with -k (keep link up) so the daemon is still ALIVE here. Without
# it capture_r3.sh quiesces at step 9 and every /proc read below returns nothing --
# which is exactly how the first version of this silently produced cpu=-1 and no
# occupancy for every row. The log grep is deliberately NOT behind the liveness test,
# so rxqstat still lands even if the daemon did exit (the log outlives it).
collect() {
  $W $B_IP 'p=$(pgrep -x qpsk_tun | head -1)
    if [ -n "$p" ]; then
      HZ=$(getconf CLK_TCK); set -- $(cat /proc/$p/stat)
      ut=${14}; st=${15}; sb=${22}
      up=$(cut -d" " -f1 /proc/uptime)
      echo "CPU=$(awk -v u=$ut -v s=$st -v b=$sb -v h=$HZ -v up=$up \
        "BEGIN{l=up-b/h; if(l<=0){print -1}else{printf \"%.1f\", 100*(u+s)/h/l}}")"
      echo "CMDM=$(tr "\0" " " < /proc/$p/cmdline 2>/dev/null | grep -oE "\-M [0-9]+" | head -1 | awk "{print \$2}")"
    else
      echo "CPU=-1"; echo "CMDM="
    fi
    grep "rxqstat:" /dev/shm/qpsk_tun.log 2>/dev/null | tail -1' 2>/dev/null
}

run_cfg() {
  local cycle=$1 tag=$2 rxq=$3 m=$4 bud=${5:-}
  local OUT=$RUN/${tag}_c${cycle}
  echo "--- cycle $cycle  $tag (RXQ=$rxq -M $m budget=${bud:-off}) -> $(basename "$OUT") ---"
  local ok=1
  # 4th rotation field = RX drain budget (2026-08-12 wedge root cause): passed
  # verbatim to the daemons via bringup's DAEMON_ENV, with the TX submit log on
  # so feeder gaps are directly measurable per capture. Empty field = launch
  # line byte-identical to the original.
  local DENV=""
  [ -n "$bud" ] && DENV="QPSK_RX_DRAIN_BUDGET=$bud QPSK_TXLOG=/dev/shm/txlog.bin"
  RXM=$m RXQ=$rxq RXCYC=0 HOST_CFLAGS_B=-DQPSK_RXQ_STAT DAEMON_ENV="$DENV" \
    LO_B_RX=1900020000 GATE_TRIES=12 \
    "$D/capture_r3.sh" B -k -n "$NSAMP" -o "$OUT" > "$OUT.log" 2>&1 || ok=0
  [ -f "$OUT/frames.bin" ] || ok=0

  local INFO CPU RXQL GOTM
  INFO=$(collect)
  CPU=$(echo "$INFO"  | sed -n 's/^CPU=//p'  | head -1)
  GOTM=$(echo "$INFO" | sed -n 's/^CMDM=//p' | head -1)
  RXQL=$(echo "$INFO" | grep -o 'rxqstat:.*' | head -1)

  # the depth the daemon ACTUALLY took -- a silent default would invalidate the row
  if [ -n "${GOTM:-}" ] && [ "$GOTM" != "$m" ]; then
    echo "    !! cmdline -M $GOTM != requested $m -- row marked bad"; ok=0
  fi

  local f_def f_gap f_cmp f_fe f_bs f_bm f_rs
  f_def=$(echo "$RXQL" | grep -oE 'defers=[0-9]+'      | cut -d= -f2)
  f_gap=$(echo "$RXQL" | grep -oE 'engine_gaps=[0-9]+' | cut -d= -f2)
  f_cmp=$(echo "$RXQL" | grep -oE 'completions=[0-9]+' | cut -d= -f2)
  f_fe=$(echo  "$RXQL" | grep -oE 'full_eager=[0-9]+'  | cut -d= -f2)
  f_bs=$(echo  "$RXQL" | grep -oE 'backlog_sum=[0-9]+' | cut -d= -f2)
  f_bm=$(echo  "$RXQL" | grep -oE 'backlog_max=[0-9]+' | cut -d= -f2)
  f_rs=$(echo  "$RXQL" | grep -oE 'resets=[0-9]+'      | cut -d= -f2)

  echo "$cycle,$tag,$rxq,$m,$ok,${GOTM:-NA},${CPU:-NA},${f_def:-NA},${f_gap:-NA},${f_cmp:-NA},${f_fe:-NA},${f_bs:-NA},${f_bm:-NA},${f_rs:-NA},$(basename "$OUT")" >> "$CSV"
  echo "    ok=$ok cpu=${CPU:-NA}%  ${RXQL:-<no rxqstat: legacy path or flag missing>}"
}

for c in $(seq 1 "$CYCLES"); do
  echo; echo "########## CYCLE $c/$CYCLES  $(date +%H:%M:%S) ##########"
  for cfg in $ROTATION; do
    IFS=: read -r tag rxq m bud <<< "$cfg"
    run_cfg "$c" "$tag" "$rxq" "$m" "$bud"
  done
  if [ "$c" = 1 ]; then
    for cfg in $ONCE; do
      IFS=: read -r tag rxq m bud <<< "$cfg"
      run_cfg "$c" "$tag" "$rxq" "$m" "$bud"
    done
  fi
done

echo; echo "=== sweep complete: $CSV ==="
echo "=== analyse with: python3 $D/sweep_report.py $RUN ==="
