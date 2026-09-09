#!/bin/bash
# =============================================================================
# goodput_sweep.sh [rung_bps] -- sustained goodput + daemon CPU per RX config.
#
# WHY SEPARATE FROM rx_config_sweep.sh: that script measures FER under the capture
# traffic pattern. Goodput needs a SATURATING pattern, which is a different load, so
# the two must not be presented as one measurement. This script supplies the cost
# column; rx_config_sweep.sh supplies the FER column.
#
# DIRECTION MATTERS -- and the obvious choice is wrong. perf_ceiling.sh "fwd" is
#   rung $A $B $TA  = server on 148, so 148 is the RECEIVER.
# The -M knob under test is on 146's RX path, so fwd would exercise the wrong board
# entirely. "rev" (rung $B $A $TB, server on 146) is the direction that matches the
# FER captures, where traffic runs 148 -> 10.66.0.1 with 146 receiving. Use rev.
#
# Smaller batches mean more DMA transactions per frame and rx_want_spin() spins more at
# small M, so CPU is EXPECTED to rise as M falls -- that is the whole point of measuring
# it. CPU is the daemon's own utime+stime over its lifetime, not box load average.
# =============================================================================
set -u
D=$(cd "$(dirname "$0")" && pwd)
W=$D/anyssh.sh
B_IP=10.0.0.146
RUNG=${1:-15000000}
# tag:RXQ:M[:AREAS]  -- AREAS optional, default 2 (today's ring)
CONFIGS=${CONFIGS:-"q32:1:32 q16:1:16 q8:1:8 l32:0:32 l16:0:16"}

STAMP=$(date +%Y%m%d_%H%M%S)
OUT=$D/r3cap/goodput_$STAMP
mkdir -p "$OUT"
CSV=$OUT/goodput.csv
echo "tag,rxq,m,areas,offered_bps,goodput_mbits,delivered_pct,cpu_pct,defers,completions,backlog_sum,resets" > "$CSV"

echo "=== goodput sweep (rev: 148 -> 146, 146 is RX = the board under test) rung=$RUNG ==="

for cfg in $CONFIGS; do
  IFS=: read -r tag rxq m areas <<< "$cfg"
  areas=${areas:-2}
  L=$OUT/$tag.log
  echo "--- $tag (RXQ=$rxq -M $m, $areas areas) ---"
  # Bring the link up in THIS config VIA capture_r3.sh -k, not bringup_r2r3.sh directly.
  # bringup alone can come up wedged: the first version of this script did exactly that
  # and every rung reported PERF_SRV_DONE rx_pkts=0 -- offered 15 Mbit, received nothing.
  # capture_r3.sh wraps bringup in the crc-health gate and byte re-arm loop, and -k
  # leaves the gated link up for the perf run that follows.
  RXM=$m RXQ=$rxq RXCYC=0 HOST_CFLAGS_B=-DQPSK_RXQ_STAT \
    DAEMON_ENV="QPSK_RX_AREAS=$areas" \
    LO_B_RX=1900020000 GATE_TRIES=12 \
    "$D/capture_r3.sh" B -k -d 15 -n 400000 -o "$OUT/gate_$tag" > "$L" 2>&1 \
    || { echo "  GATED BRINGUP FAILED"; continue; }
  $W $B_IP 'pkill -x qpsk_perf 2>/dev/null' 2>/dev/null; sleep 1

  got=$($W $B_IP 'tr "\0" " " < /proc/$(pgrep -x qpsk_tun|head -1)/cmdline 2>/dev/null' \
        2>/dev/null | grep -oE '\-M [0-9]+' | head -1 | awk '{print $2}')
  if [ -n "${got:-}" ] && [ "$got" != "$m" ]; then
    echo "  !! daemon took -M $got, wanted $m -- skipping row"; continue
  fi

  "$D/perf_ceiling.sh" rev "$RUNG" >> "$L" 2>&1

  # qpsk_perf reports PERF_SRV_DONE rx_bytes=... and PERF_CLI_DONE dur=...; goodput is
  # what the RECEIVER actually got, not what the sender offered.
  rxb=$(grep -oE 'PERF_SRV_DONE .*rx_bytes=[0-9]+' "$L" | tail -1 | grep -oE 'rx_bytes=[0-9]+' | cut -d= -f2)
  rxp=$(grep -oE 'PERF_SRV_DONE .*rx_pkts=[0-9]+'  "$L" | tail -1 | grep -oE 'rx_pkts=[0-9]+'  | cut -d= -f2)
  txp=$(grep -oE 'PERF_CLI_DONE .*tx_pkts=[0-9]+'  "$L" | tail -1 | grep -oE 'tx_pkts=[0-9]+'  | cut -d= -f2)
  dur=$(grep -oE 'PERF_CLI_DONE .*dur=[0-9.]+'     "$L" | tail -1 | grep -oE 'dur=[0-9.]+'     | cut -d= -f2)
  gp=NA
  if [ -n "${rxb:-}" ] && [ -n "${dur:-}" ]; then
    gp=$(awk -v b="$rxb" -v d="$dur" 'BEGIN{if(d>0)printf "%.2f", b*8/1e6/d; else print "NA"}')
  fi
  dlv=NA
  if [ -n "${rxp:-}" ] && [ -n "${txp:-}" ] && [ "${txp:-0}" -gt 0 ] 2>/dev/null; then
    dlv=$(awk -v r="$rxp" -v t="$txp" 'BEGIN{printf "%.3f", 100*r/t}')
  fi
  echo "    rx_pkts=${rxp:-NA}/${txp:-NA} delivered=${dlv}%" 

  INFO=$($W $B_IP 'p=$(pgrep -x qpsk_tun | head -1); [ -n "$p" ] || exit 0
    HZ=$(getconf CLK_TCK); set -- $(cat /proc/$p/stat)
    ut=${14}; st=${15}; sb=${22}; up=$(cut -d" " -f1 /proc/uptime)
    echo "CPU=$(awk -v u=$ut -v s=$st -v b=$sb -v h=$HZ -v up=$up \
      "BEGIN{l=up-b/h; if(l<=0){print -1}else{printf \"%.1f\", 100*(u+s)/h/l}}")"
    grep "rxqstat:" /dev/shm/qpsk_tun.log 2>/dev/null | tail -1' 2>/dev/null)
  CPU=$(echo "$INFO" | sed -n 's/^CPU=//p' | head -1)
  R=$(echo "$INFO" | grep -o 'rxqstat:.*')
  f(){ echo "$R" | grep -oE "$1=[0-9]+" | cut -d= -f2; }

  echo "$tag,$rxq,$m,$areas,$RUNG,${gp:-NA},${dlv:-NA},${CPU:-NA},$(f defers),$(f completions),$(f backlog_sum),$(f resets)" >> "$CSV"
  echo "  goodput=${gp:-NA} Mbit/s  cpu=${CPU:-NA}%  ${R:-<no rxqstat>}"
done

echo; echo "=== $CSV ==="
column -s, -t < "$CSV"
