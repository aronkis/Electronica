#!/bin/bash
# build_txrate_sim.sh -- build txrate_probe.cpp against a netlist tree (same recipe as
# build_txkick_sim.sh).  Host-only, no board.
#
# Env params (TXFIX T0a; defaults reproduce the pre-2026-09-03 behaviour exactly):
#   TREE     netlist tree      (default s1_rtl_txmark)
#   OBJ      Verilator -Mdir   (default obj_txrate)
#   HARNESS  harness source    (default txrate_probe.cpp)
set -e
cd "$(dirname "$0")"

TREE="${TREE:-s1_rtl_txmark}"
OBJ="${OBJ:-obj_txrate}"
HARNESS="${HARNESS:-txrate_probe.cpp}"

[ -d "$TREE/hdlsrc/commhdlQPSKTxRxLoopback" ] || { echo "TXRATE_BUILD_FAIL: no tree $TREE"; exit 2; }
[ -f "$HARNESS" ] || { echo "TXRATE_BUILD_FAIL: no harness $HARNESS"; exit 2; }

echo "TXRATE_BUILD TREE=$TREE OBJ=$OBJ HARNESS=$HARNESS"
rm -rf "$OBJ"
verilator -O2 -Wno-fatal --cc --exe --build --public-flat-rw --top-module wrap_byte_ddrcap \
  -y "$TREE/hdlsrc/commhdlQPSKTxRxLoopback" -y . \
  wrap_byte_ddrcap.v "$HARNESS" \
  -Mdir "$OBJ" -o Vtxrate
echo "TXRATE_BUILD_EXIT $?"
