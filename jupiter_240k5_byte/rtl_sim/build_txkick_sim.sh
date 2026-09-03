#!/bin/bash
# build_txkick_sim.sh -- build sim_burst_force_tx.cpp against the TXMARK netlist
# (s1_rtl_txmark), the same --public-flat-rw recipe used for obj_kick/Vkick
# (two_jup/KICK_EXPERIMENT_BRIEF.md step 2). Host-only, no board.
set -e
cd "$(dirname "$0")"
rm -rf obj_txkick
verilator -O2 -Wno-fatal --cc --exe --build --public-flat-rw --top-module wrap_byte_ddrcap \
  -y s1_rtl_txmark/hdlsrc/commhdlQPSKTxRxLoopback -y . \
  wrap_byte_ddrcap.v sim_burst_force_tx.cpp \
  -Mdir obj_txkick -o Vtxkick
echo "TXKICK_BUILD_EXIT $?"
