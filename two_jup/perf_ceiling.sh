#!/bin/bash
# =============================================================================
# perf_ceiling.sh <fwd|rev|both> [rungs_bps...] -- one-way qpsk_perf rate ladder
# to find the TRUE goodput ceiling at whatever rung the link is currently at.
#
# WHY (task-HOSTPERF / task-BERQUAL): the old r2meas/r3meas set offered a FIXED
# 2M+6M ladder with tags mislabelled "4M/12M" -- the R3 ceiling (~13.9 Mbit/s
# theoretical at 1245 f/s x 1400 B) was NEVER probed: 6M offered sat at 86% so
# the knee was above the top rung and went unseen. This script (a) offers a
# ladder that BRACKETS the ceiling, and (b) ECHOES the exact qpsk_perf command
# with its -b before running -- the r3meas rate bug failed SILENTLY once (label
# said 12M, -b said 6M); never trust an un-echoed offered rate again.
#
# Link must already be UP bidirectional (bringup_r2r3.sh r2|r3). Server runs on
# the RX board, client on the TX board; -l 1400 = 1 frame/datagram.
# Usage: perf_ceiling.sh both 6000000 10000000 12000000 15000000
#        perf_ceiling.sh fwd                 (default ladder)
# =============================================================================
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
A=10.0.0.148; B=10.0.0.146; TA=10.66.0.2; TB=10.66.0.1
DIR=${1:-both}; shift || true
RUNGS="${*:-6000000 10000000 12000000 15000000}"
mark(){ echo "@@ $* $(date -Is)"; }

# one rung: $1 rx_ip $2 tx_ip $3 rx_tun_addr $4 offered_bps $5 tag
rung(){
  local rxip=$1 txip=$2 rxtun=$3 bps=$4 tag=$5
  mark "PERF_${tag}_$(( bps/1000000 ))M"
  $W $rxip "setsid sh -c '/root/host_app_k5/qpsk_perf -s -p 5001 > /dev/shm/perf_srv.log 2>&1' </dev/null >/dev/null 2>&1 &" 2>/dev/null
  sleep 2
  local CMD="/root/host_app_k5/qpsk_perf -c $rxtun -b $bps -l 1400 -t 30 -p 5001"
  echo "  CLIENT CMD: $CMD"          # advisor guard: echo the ACTUAL -b every run
  $W $txip "$CMD 2>&1 | tail -2" 2>/dev/null
  $W $rxip 'pkill -f "[q]psk_perf -s"; tail -2 /dev/shm/perf_srv.log' 2>/dev/null
  sleep 1
}
echo "=== perf ceiling: dir=$DIR rungs=$RUNGS ==="
for bps in $RUNGS; do
  case "$DIR" in
    fwd|both) rung $A $B $TA $bps FWD ;;
  esac
  case "$DIR" in
    rev|both) rung $B $A $TB $bps REV ;;
  esac
done
mark DONE
