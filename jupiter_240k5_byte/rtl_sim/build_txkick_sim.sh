#!/bin/bash
# build_txkick_sim.sh -- build the TX kick/force harness against a netlist tree, the
# same --public-flat-rw recipe used for obj_kick/Vkick (two_jup/KICK_EXPERIMENT_BRIEF.md
# step 2). Host-only, no board.
#
# Env params (TXFIX T0a; defaults reproduce the pre-2026-09-03 behaviour exactly):
#   TREE     netlist tree           (default s1_rtl_txmark)
#   OBJ      Verilator -Mdir        (default obj_txkick)
#   HARNESS  harness source         (default sim_burst_force_tx.cpp)
# A txfix variant tree MUST be built with sim_txfix_force.cpp (the readback and
# latchforce controls the gate depends on live there), enforced below.
set -e
cd "$(dirname "$0")"

TREE="${TREE:-s1_rtl_txmark}"
OBJ="${OBJ:-obj_txkick}"
HARNESS="${HARNESS:-sim_burst_force_tx.cpp}"

[ -d "$TREE/hdlsrc/commhdlQPSKTxRxLoopback" ] || { echo "TXKICK_BUILD_FAIL: no tree $TREE"; exit 2; }
[ -f "$HARNESS" ] || { echo "TXKICK_BUILD_FAIL: no harness $HARNESS"; exit 2; }
case "$TREE" in
  s1_rtl_txfix_*)
    [ "$HARNESS" = "sim_txfix_force.cpp" ] || {
      echo "TXKICK_BUILD_FAIL: TREE=$TREE requires HARNESS=sim_txfix_force.cpp (got $HARNESS)"; exit 2; }
  ;;
esac

echo "TXKICK_BUILD TREE=$TREE OBJ=$OBJ HARNESS=$HARNESS"
rm -rf "$OBJ"
verilator -O2 -Wno-fatal --cc --exe --build --public-flat-rw --top-module wrap_byte_ddrcap \
  -y "$TREE/hdlsrc/commhdlQPSKTxRxLoopback" -y . \
  wrap_byte_ddrcap.v "$HARNESS" \
  -Mdir "$OBJ" -o Vtxkick
echo "TXKICK_BUILD_EXIT $?"
