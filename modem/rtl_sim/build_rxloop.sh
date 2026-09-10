#!/bin/bash
# build_rxloop.sh -- [sim] Task 8d: build the closed-loop RX-front-end harness
# (wrap_byte_rxloop.v + sim_rxloop.cpp) against the FLASHED 148 lineage netlist
# snapshot rtl_sim/s1_rtl_txfix_F3/hdlsrc/commhdlQPSKTxRxLoopback.
#
# qpsk_traffic_gen_v2.v lives in rtl_sim/, not in the netlist, so both -y dirs
# are needed.  Optimised harder than build_seqbist_gate.sh (-O3, fast x-assign,
# -march=native on the generated C++) because Task 8d is wall-clock bound.
#
# Runs under `systemd-run --user` (transient unit; never a harness background
# task -- MEMORY background-jobs-systemd-run).
#   ./build_rxloop.sh            # launch and return
#   ./build_rxloop.sh --wait     # launch and block
set -u -o pipefail
R=$(cd "$(dirname "$0")" && pwd)
VD=${RXLOOP_NETLIST:-$R/s1_rtl_txfix_F3/hdlsrc/commhdlQPSKTxRxLoopback}
TAG=${RXLOOP_TAG:-rxloop}
LOG=$R/beat_runs/rxloop_build.log
UNIT=rxloop-build-$(date +%s)-$$

if [ "${RXLOOP_IN_UNIT:-0}" != "1" ]; then
  [ -f "$VD/TxRxComposite.v" ] || { echo "FATAL: no netlist at $VD" >&2; exit 1; }
  mkdir -p "$R/beat_runs"; : > "$LOG"
  systemd-run --user --collect --unit="$UNIT" --working-directory="$R" \
    -p StandardOutput=append:"$LOG" -p StandardError=append:"$LOG" \
    -E RXLOOP_IN_UNIT=1 -E RXLOOP_NETLIST="$VD" -E RXLOOP_TAG="$TAG" \
    /bin/bash "$R/build_rxloop.sh" || exit 1
  echo "RXLOOP_BUILD_LAUNCHED unit=$UNIT log=$LOG"
  if [ "${1:-}" = "--wait" ]; then
    while systemctl --user is-active "$UNIT" >/dev/null 2>&1; do sleep 5; done
    tail -5 "$LOG"
  fi
  exit 0
fi

export PATH=/usr/local/bin:/usr/bin:/bin
cd "$R" || exit 1
echo "RXLOOP_BUILD_START $(date -Iseconds) netlist=$VD"
OBJ=obj_${TAG}
rm -rf "$OBJ"
T0=$(date +%s)
verilator -O3 -Wno-fatal --x-assign fast --x-initial fast --noassert \
  --cc wrap_byte_rxloop.v -y "$VD" -y "$R" \
  --exe sim_rxloop.cpp -CFLAGS "-O2 -march=native -fno-stack-protector" \
  -Mdir "$OBJ" --top-module wrap_byte_rxloop || { echo "RXLOOP_BUILD_EXIT=1"; exit 1; }
make -s -C "$OBJ" -f Vwrap_byte_rxloop.mk Vwrap_byte_rxloop \
  || { echo "RXLOOP_BUILD_EXIT=2"; exit 2; }
T1=$(date +%s)
echo "RXLOOP_BUILD_DONE $R/$OBJ/Vwrap_byte_rxloop secs=$((T1-T0))"
echo "RXLOOP_BUILD_EXIT=0"
